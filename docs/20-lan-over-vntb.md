# 20 — 一条 PCIe 链路同时跑两套网络

> 目标：保留 x86 ↔ NPU 的 `192.168.100.0/24` 管理通道，同时让 x86 直接拿到家里路由器
> `192.168.0.0/24` 的 DHCP 地址，不再需要单独给 x86 插网线。

## 20.1 为什么必须用 VLAN

x86 和 NPU 之间**只有** PCIe vNTB 这一个 netdev（`eth0` / `pci-vntb 0001:10:00.0`）。
一个 netdev 只能属于一个桥，所以「管理段」和「家里 LAN」必须靠 802.1Q 分开：

```
        x86                                    NPU
  eth0.100 ─ 192.168.100.2/24 ─┐    ┌─ 192.168.100.1/24 ─ eth0.100
                               │    │
  eth0  ═══════════════════════╪════╪══════════════════════════ eth0   (无地址)
                               │    │
  eth0.31  ─ DHCP ◄────────────┘    └─ br-lan ─ eth0.31 + p4 ──► 家里路由器
                                   br-mgmt ─ eth0.100 + p8  ◄── 前面板 p8（access 口）
```

| 段 | VLAN | NPU 侧 | x86 侧 | 谁能访问 |
|---|---|---|---|---|
| 管理 | 100 | `br-mgmt` = `p8` + `eth0.100`，`192.168.100.1/24` | `eth0.100` = `192.168.100.2/24` | 前面板 p8 插笔记本，`.1`/`.2` 都在 |
| 家里 LAN | 31 | `br-lan` = `p4` + `eth0.31`，**无地址**，纯 L2 透传 | `eth0.31`，systemd-networkd DHCP | 家里任意设备 → x86 的真实 LAN 地址 |

p8 依然是 **access 口**：直接插网线只看得到未打标签的 `192.168.100.0/24`，管理帧不会溢到面板上。

实测：

```
x86:  eth0.100  192.168.100.2/24      ping 192.168.100.1  0% loss
      eth0.31   192.168.0.63/24      default via 192.168.0.1 （家里路由器发的租约）
```

## 20.2 哪个口是家里 LAN

`p4` 和 `sfp` **都**插在同一个家里 LAN 上（两边发 DHCP 都能拿到 `192.168.0.x`）。
本方案选了 `p4`（1G）；`sfp`（10G）留着不动。

> ⚠️ 不要把 `p4` 和 `sfp` 同时并进 `br-lan` —— 那是同一个 L2 域，会成环。

## 20.3 踩到的坑：父设备必须 up

第一版脚本只 `ip link set eth0.100 up`，忘了 `ip link set eth0 up`。结果 VLAN 设备全部
停在 `LOWERLAYERDOWN`，`br-mgmt` 跟着 down：

```
eth0             DOWN
eth0.100@eth0    LOWERLAYERDOWN 192.168.100.2/24
```

VLAN 设备的 carrier 来自父设备，**父设备没有地址也必须 up**。三个脚本现在都显式做了：

| 文件 | 位置 |
|---|---|
| `systemd/xgs-mgmt-bridge.sh` | `ip link set "$NTB" up`（清地址之后） |
| `systemd/xgs-lan-uplink.sh` | `ip link set "$NTB" up` |
| `systemd/xgs-ntb-up.sh` | `ip addr flush dev eth0` 之后 `ip link set eth0 up` |

## 20.4 NPU 的串口控制台（重要）

**NPU 不是没有控制台** —— 它就在 x86 的 `/dev/ttyS2` 上（`I/O 0x3e8, irq 5`，标准 COM2）。
这条线是主板内部走的，外面看不到，所以之前一直以为 NPU 是瞎的。

### 波特率是 57600，不是 115200

NPU 侧 `bootargs` 写的是 `console=ttyS0,115200n8`，但**从 x86 这头必须设 57600**：

```
$ stty -F /dev/ttyS2 115200 ...   → 0~2 字节乱码
$ stty -F /dev/ttyS2 57600  ...   → 干净的 "xgs87-npu login:"
```

原因：x86 的 16550 时钟分频基准被报成 `base_baud = 115200`，而这块板子实际晶振是它的
两倍，所以内核下发的 divisor 让线路速率翻倍。软件写 57600 = 线上 115200。

### 用法

```sh
# x86 上：登录
stty -F /dev/ttyS2 57600 raw -echo -crtscts
printf 'root\r' > /dev/ttyS2        # 等 Password:
printf 'openwrt123\r' > /dev/ttyS2

# 之后直接用（保持这一条 cat 在读，别开第二个读者，否则字节会被抢碎）
cat /dev/ttyS2
```

> 账号 `root` / `openwrt123`（见 [docs/04](04-npu-system.md)）。
> **同一时刻只能有一个进程读 `/dev/ttyS2`**，两个 `cat` 会把数据流切成乱码 —— 这一个坑
> 让排查多花了半小时。

## 20.5 吞吐实测（iperf3，走 vNTB）

| 场景 | 结果 |
|---|---|
| 单流 TCP | **969 Mbits/s** |
| 4 流 TCP | **1.18 Gbits/s** |
| PCIe 链路 | 8.0 GT/s ×2 = 15.75 Gb/s 可用带宽（受 x86 根端口 x2 限制） |

4 流几乎不涨 → 瓶颈不在 CPU，而在 **单个 QP / 单发送队列**：`ntb_transport` 目前只建了
1 个 QP，`ntb_netdev` 也只有一个 TX 队列，全部收敛到同一个 kthread。
家里 LAN 是 1G，这个数够用；要榨干得加 QP（`num_qps`）并配多队列网卡。

## 20.6 自愈

| 机制 | 位置 | 作用 |
|---|---|---|
| `xgs-ntb-watch.service` | x86 | 每 15 s 查 `carrier`；掉线超过 60 s 就重新 `remove`+`rescan` 枚举端点、重建 VLAN、补地址。**NPU 重启后 x86 会自动重新接上** |
| `/etc/sysctl.d/90-xgs-panic.conf` | 两边 | `kernel.panic=30`、`panic_on_oops=1`、`hardlockup_panic=1`。没有 console 的机器卡住等于要人跑一趟，宁可 panic 后自己重启 |

## 20.7 仍然开着的问题

1. **NPU 消失时 x86 会整机锁死**（`ntb_hw_epf` 还在读已经不存在的 BAR，UART 都不再出字符，
   magic SysRq 也无效）。`panic_on_oops` 只在 oops 路径上有效，若真锁在 spinlock 里不会触发。
   下次复现时用 netconsole（`6666@192.168.200.1/eth0`）抓 trace。
2. **关机**：`systemctl reboot` 之后机器能自己回来，但会消耗 ~2 分钟，且文件系统不会被标记为
   干净卸载（需要进一步确认是 panic 后重启还是正常重启）。
3. `p8` 前线现在没人插，`br-mgmt` 靠 `eth0.100` 撑着；插上笔记本即可同时访问 `.1` / `.2`。
