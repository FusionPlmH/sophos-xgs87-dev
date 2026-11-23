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

## 20.5 吞吐与延迟实测（iperf3 + ping，走 vNTB）

| 场景 | 原始（1 jiffy 轮询） | 改 hrtimer 之后 |
|---|---|---|
| 单流 TCP | 969 Mbits/s | **1.20 Gbits/s** |
| 4 流 TCP | 1.18 Gbits/s | 1.18 Gbits/s |
| ping RTT（x86→NPU） | 1.2 – 13.8 ms，avg 4 – 7 ms | **0.23 – 1.2 ms，avg 0.6 ms** |
| 空闲 CPU | — | 0.0%（自动退避到 1 ms） |
| PCIe 链路 | 8.0 GT/s ×2 = 15.75 Gb/s 可用（x86 根端口只给 x2） | 同 |

单流就能吃满 1.2 Gb/s、4 流不再涨 → 瓶颈是**单个 QP / 单发送队列**，不是 CPU。
家里 LAN 是 1G，这个数已经够；要吃更多得上多 QP。

## 20.6 延迟的真正来源：门铃是被"轮询"的

`pci_epf_vntb` 里 host 写门铃 BAR 不会在本侧产生中断，所以 EP 必须自己轮询：

```c
reset_handler:
	queue_delayed_work(kpcintb_workqueue, &ntb->cmd_handler,
			   msecs_to_jiffies(1));     /* HZ=250 → 4 ms */
```

`msecs_to_jiffies(1)` 在 HZ=250 的 Debian 内核上就是 **4 ms**，而 ping 的往返里至少要吃一次它
—— 实测 RTT 4–7 ms 完全对得上。

改成 hrtimer 并做**自适应退避**（`ntb/patch-hrtimer-poll.py`）：

| 状态 | 周期 | 效果 |
|---|---|---|
| 有流量 | 250 µs | RTT 0.6 ms，单流 1.2 Gb/s |
| 连续 8 次空闲 | 1 ms | 空闲 CPU 0.0% |

```c
static enum hrtimer_restart epf_ntb_poll_timer(struct hrtimer *timer)
{
	struct epf_ntb *ntb = container_of(timer, struct epf_ntb, poll_timer);

	queue_work(kpcintb_workqueue, &ntb->cmd_handler.work);
	hrtimer_forward_now(timer, ns_to_ktime(ntb->poll_ns));
	return HRTIMER_RESTART;
}
```

构建（NPU 的 rootfs 挂在 WSL 里编）：

```sh
python3 ntb/patch-hrtimer-poll.py /srv/npu/build/ntb
chroot /srv/npu make -C /usr/src/linux-headers-6.12.117+deb13-arm64 M=/build/ntb modules
```

## 20.7 自愈

| 机制 | 位置 | 作用 |
|---|---|---|
| `xgs-ntb-watch.service` | x86 | 每 15 s 查 `carrier`；掉线超过 60 s 就重新 `remove`+`rescan` 枚举端点、重建 VLAN、补地址。**NPU 重启后 x86 会自动重新接上** |
| `/etc/sysctl.d/90-xgs-panic.conf` | 两边 | `kernel.panic=30`、`panic_on_oops=1`、`hardlockup_panic=1` |

实测一次完整的 NPU 重启：x86 端 `ntb_hw_epf` 在端点消失时 oops → `panic_on_oops` 触发 panic →
30 s 后自己重启 → 启动时 `xgs-ntb-watch` 重新枚举 → 链路和 DHCP 全部自动恢复，
**全程不需要人碰机器**（两次重启冒烟验证通过）。

## 20.8 仍然开着的问题

1. **NPU 端点消失时 x86 会 oops**（`ntb_hw_epf` 仍在访问已经不存在的 BAR）。现在靠
   `panic_on_oops` + `panic=30` 兜成"自愈重启"，但根因没修 —— 正解是给 `ntb_hw_epf`
   加 link-down 处理，或让宿主端口支持热插拔（`pciehp`）走正常的设备移除路径。
2. **两台机器会连锁重启**：x86 重启期间 NPU 侧 `ntb_netdev_close()` 会踩到已经掉线的 spad
   （`vntb_epf_spad_read` oops），`panic_on_oops` 又把它重启一次。两边都自愈，但会多花一轮时间。
3. `p8` 前线现在没人插，`br-mgmt` 靠 `eth0.100` 撑着；插上笔记本即可同时访问 `.1` / `.2`。
