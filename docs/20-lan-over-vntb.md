# 20 — 一条 PCIe 链路同时跑 WAN 和 LAN

> 🏷 **状态（2026-11-25 复核）**：✅ 线路上实测过：VLAN 双网、NPU 串口 115200（老内核 57600）、
> hrtimer 提性能、模块替换、**netconsole 崩溃取证**；WAN/LAN 拆分（§20.2）已在现机配置并验证
> DHCP/NAT，未做严格吞吐复测。
> ⚠️ `ramoops` 已证伪（每次复位都 DDR scrub）；硬锁死 vs `PERST#` 仍待一次复现定案（§20.8）。
> ⚠️ `xgs-ntb-watch` 默认 `AUTO_RECOVER=1`：链路连续 5 分钟不通才跑一次 `--force-rescan`
> （不会去碰正在启动的 NPU），见 §20.11.6。

> 目标：x86 和 NPU 之间只有一条 PCIe 链路，却要同时装下**上游 WAN**（面板 `2/WAN`，自己
> DHCP 拿地址，管理也走这条路）和**下游 LAN**（面板 `1/LAN`，本机静态 `10.234.56.1/24`，
> 不给下游发 DHCP）。

## 20.1 为什么必须用 VLAN

x86 和 NPU 之间**只有** PCIe vNTB 这一个 netdev（`eth0` / `pci-vntb 0001:10:00.0`）。
一个 netdev 只能属于一个桥，所以「WAN」和「LAN」必须靠 802.1Q 分开：

```
        x86                                    NPU
  eth0.100 ─ DHCP ◄────────────┐    ┌─ br-wan ─ eth0.100 + p2 ──► 上游 / WAN / 管理
                               │    │
  eth0  ═══════════════════════╪════╪══════════════════════════ eth0   (无地址)
                               │    │
  eth0.200 ─ 10.234.56.2/24 ───┘    └─ br-lan ─ eth0.200 + p1 ──► 下游设备（10.234.56.1）
```

| 段 | VLAN | NPU 侧 | x86 侧 | 谁能访问 |
|---|---|---|---|---|
| WAN / 管理 | 100 | `br-wan` = `p2` + `eth0.100`，**DHCP**（自己拿上游地址） | `eth0.100`，systemd-networkd DHCP，默认路由也从这里来 | 插上面板 `2/WAN` 的上游 → NPU 和 x86 各拿一个租约 |
| LAN | 200 | `br-lan` = `p1` + `eth0.200`，**静态 `10.234.56.1/24`，不跑 DHCP 服务** | `eth0.200` 静态 `10.234.56.2/24` | 面板 `1/LAN` 插笔记本（自己配 `10.234.56.x`）→ `.1` / `.2` |

`p3` / `p4` / `p8` 现在**不并入任何桥**（原来 `p4` 走家里内网、`p8` 是独立管理口，都退掉了）。
想让前面板 `p8` 也能当调试口，把它加到 `net.conf` 的 `LAN_PORTS` 就行。

交换机上两段用**不同的硬件 VLAN**：`br-wan` 用 VLAN 100，`br-lan` 用 VLAN 200
（`vlan_filtering 1` + `vlan_default_pvid 0`，桥自己的端口也要 `self` 加进去）。
两个桥都用默认 VLAN 1 的话，交换芯片里的广播域其实是同一个 —— 面板上的 WAN 和 LAN 会互通。

## 20.2 哪个口是 LAN / 哪个是 WAN

面板丝印和 DSA 端口号的对应：`1/LAN` = `p1`，**`2/WAN` = `p2`**，3 = `p3`，4 = `p4`，SFP = `sfp`。

全部由 `/etc/xgs87/net.conf` 决定（NPU 侧读它，`xgs-net-up.sh` 用 `.` 加载，所以是 shell 语法）：

| 桥 | 默认端口 | VLAN | 默认模式 | 说明 |
|---|---|---|---|---|
| `br-wan` | `p2`（面板 `2/WAN`） | 100 | `dhcp` | 上游；自己拿租约，管理也走这条 |
| `br-lan` | `p1`（面板 `1/LAN`） | 200 | `static` | `10.234.56.1/24`，**不跑 DHCP 服务** |

```sh
# /etc/xgs87/net.conf  —— 取默认值就不用动这个文件
WAN_PORTS="p2"   WAN_MODE="dhcp"    WAN_VID="100"   # static 时配 WAN_ADDR="203.0.113.2/24"
LAN_PORTS="p1"   LAN_MODE="static"  LAN_VID="200"   # LAN_ADDR="10.234.56.1/24"
```

改完 `sudo systemctl restart xgs-net-up xgs-dhcp` 就生效，不用重启。

x86 那一端（`systemd/x86/`）跟着这两条 VLAN 走：`100-wan.network` 在 `eth0.100` 上 DHCP，
`200-lan.network` 在 `eth0.200` 上给静态 `10.234.56.2/24`。

## 20.2.1 LAN 出去要靠 NAT（`xgs-nat.service`）

LAN 段是独立的 `10.234.56.0/24`，上游只认识 `br-wan` 那个 DHCP 地址，所以 LAN 下面的设备
想上网必须做转发 + 源地址伪装：

```
net.ipv4.ip_forward = 1                       # /etc/sysctl.d/60-xgs87-nat.conf
nft add table inet xgs87                      # xgs-nat.sh 建，重复执行就是重建
  chain forward   : br-lan → br-wan accept；br-wan → br-lan 只放 established/related；其余 drop
  chain postrouting: oifname br-wan, ip saddr 10.234.56.0/24 masquerade
```

- 规则全在自己的 `inet xgs87` 表里：`systemctl disable --now xgs-nat && nft delete table inet xgs87`
  就完全回退，不留后遗症。
- 子网的 `10.234.56.0/24` 从 `net.conf` 的 `LAN_ADDR` 推出来，改地址不用改规则。
- **没开 IPv6 转发**：上游目前只发 IPv4 租约，开了也只是徒增暴露面。
- 也没装 DNS 服务：LAN 上的客户端 DNS 要么指上游，要么指公共解析器。

> ⚠️ 这条 NAT 只是"让 LAN 能出去"，没做任何限速/访问控制；要当正式路由用还缺 DHCP 服务
> 和防火墙策略（见 §20.13）。

> ⚠️ 下游设备要自己配 `10.234.56.x/24`，网关 `10.234.56.1`：这里的 LAN 没有 DHCP 服务，
> 插上去不会自动拿到地址。

> ⚠️ 同一个桥里的端口共用一个广播域 —— 以后往 `LAN_PORTS` 里加口，别把它们接到同一台交换机上。

## 20.3 踩到的坑：父设备必须 up

第一版脚本只 `ip link set eth0.100 up`，忘了 `ip link set eth0 up`。结果 VLAN 设备全部
停在 `LOWERLAYERDOWN`，桥和它上面的地址跟着 down：

```
eth0             DOWN
eth0.200@eth0    LOWERLAYERDOWN 10.234.56.2/24
```

VLAN 设备的 carrier 来自父设备，**父设备没有地址也必须 up**。三个脚本现在都显式做了：

| 文件 | 位置 |
|---|---|
| `systemd/npu/xgs-net-up.sh` | `ip link set "$NTB" up`（清地址之后） |
| `systemd/npu/xgs-net-up.sh` | `ip link set "$NTB" up` |
| `systemd/x86/xgs-ntb-up.sh` | `ip addr flush dev eth0` 之后 `ip link set eth0 up` |

## 20.4 NPU 的串口控制台（重要）

**NPU 不是没有控制台** —— 它就在 x86 的 `/dev/ttyS2` 上（`I/O 0x3e8, irq 5`，标准 COM2）。
这条线是主板内部走的，外面看不到，所以之前一直以为 NPU 是瞎的。

### 波特率：当前 Debian 是 115200；老 image 才是 57600

NPU 侧 `bootargs` 写的是 `console=ttyS0,115200n8`。当前 Debian 13 的 host 侧
**115200 就是线上 115200**：

```sh
stty -F /dev/ttyS2 115200 raw -echo -crtscts
```

早期那套 `image/` 内核把这颗 16550 报成 2x 分频，所以那套系统里 host 写 57600 才等于
线上 115200（写 115200 只会读到乱码）。这个 2x 现象**不适用于当前 Debian**。
详见 [08 §8.3](08-console-access.md)。

### 用法

```sh
# x86 上：登录（p3 原厂系统）
stty -F /dev/ttyS2 115200 raw -echo -crtscts
printf 'root\r' > /dev/ttyS2        # 等 Password:
printf 'openwrt123\r' > /dev/ttyS2

# 之后直接用（保持这一条 cat 在读，别开第二个读者，否则字节会被抢碎）
cat /dev/ttyS2
```

> 账号：p3 原厂 `root` / `openwrt123`；`image/` 产出的是 `admin` / `P@ssw0rd`。
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

改成 hrtimer 并做**自适应退避**（补丁在 [ntb/0001-pci-epf-vntb.patch](../ntb/0001-pci-epf-vntb.patch)）：

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

构建（PC/WSL 上，NPU 的 arm64 rootfs 挂在 `/srv/npu`，脚本会自己解补丁）：

```sh
./tools/build/build-npu-vntb.sh
```

## 20.7 自愈

| 机制 | 位置 | 作用 |
|---|---|---|
| `xgs-ntb-watch.service` | x86 | 每 15 s 查 `carrier` + ping `10.234.56.1`；异常时先只重建本地 VLAN/地址。镜像里默认 `AUTO_RECOVER=1`：连续 5 分钟异常后跑一次 `xgs-ntb-up.sh --force-rescan`，然后冷却 10 分钟（见 §20.11.6） |
| `/etc/sysctl.d/90-xgs-panic.conf` | 两边 | `kernel.panic=30`、`panic_on_oops=1`、`hardlockup_panic=1` |

2026-11-23 的旧版本会自动做完整重置，当时的记录是：

```
18:57:46 xgs-ntb-watch: link unhealthy, full reset
18:57:46 ntb_hw_epf: endpoint unreachable, dropping spad read   ×1
18:57:47 ntb_hw_epf: endpoint unreachable, dropping spad write  ×10
18:57:5x xgs-ntb: eth0 UP / eth0.100 UP (DHCP) / eth0.200 UP 10.234.56.2/24
```

x86 的 uptime 全程连续（没有 panic、没有重启），NPU 侧 `eth0` 也随之变 UP。
**但这个"自动"在 NPU 还在启动时是有害的**：remove/rescan 会拉 PERST#，把 NPU
按在启动里，正是 2026-11-25 的 3.2 s 复位循环。所以现在默认关闭，改由人确认 NPU
已经起来后再执行 `sudo /usr/local/sbin/xgs-ntb-up.sh --force-rescan`。

### 20.7.1 rescan 也不是万能的：链路得在 POST 时训练过

`--force-rescan` 只是让主机重新读配置空间。如果 `03:00.0` 在 rescan 之后**始终
不出现**，说明主机侧从来没枚举到过这个端点 —— 常见于"x86 先开机、NPU 后来才部署
（或换镜像重装）"。这时 rescan 写多少次都没用，唯一可靠的办法是**让 x86 重启一次，
NPU 保持开机**，由 BIOS 在 POST 阶段重新训练 PCIe 链路。

2026-11-25 装完新镜像后就是这样：NPU 侧端点已 armed（`0x1957:0x0809`、`start=1`），
NPU 自己 `eth0` 有 MAC 但 `NO-CARRIER`，而 x86 上 `ip a` 只有 `lo`（x86 本身没有
物理网口，它的唯一网口就是 vNTB 的 `eth0`），rescan 也不产生设备 → 需要重启 x86。

### 20.7.2 「`lspci` 有设备、`eth0` 没有」的第三种可能：没人绑它

`/sys/bus/ntb/devices/0000:03:00.0` 只有在 `ntb_hw_epf` **绑定**了那个 PCI function
之后才存在。已经加载的驱动会在设备出现的瞬间自动绑上，所以正常情况是免费的；但如果
设备出现时模块还没加载（模块索引过期、服务被重启过、DKMS 模块是后来才装的），设备
就会一直挂在那里没人管 —— 而此时 `lspci -nn -s 03:00.0` 看起来完全正常，正是最容易
把人带偏的那种状态。

所以 `xgs-ntb-up.sh` 现在会在等待超时前多做一步：设备在、但没有 `driver` 链接，就
显式 `echo 0000:03:00.0 > /sys/bus/pci/drivers/ntb_hw_epf/bind`，失败时把
`dmesg | grep -i ntb` 的尾巴打出来。超时报错里也会写明设备到底是
`absent` 还是 `present, driver: ...`，下一次只凭这一行就能分清 20.7.1 和 20.7.2。

顺带补了 `MODULE_DEVICE_TABLE(pci, ntb_epf_pci_tbl)`：没有它模块不导出 modalias，
`modules.alias` 里查不到 `v00001957d00000809`，设备热插拔时 udev 也就无法自动加载。

### 20.7.3 端点不一定是 `03:00.0`

总线号是 **BIOS 分配的**，`0000:03:00.0` 只是本机以往的常见值。整机断电重启、换
PCIe 槽、BIOS 改设置都可能让它变成别的值；一旦变了，所有写死旧路径的东西（脚本、
watcher、安装器、文档里的 `tee .../bind`）全都指向空气，而现象和「NPU 死了」一模
一样 —— 2026-11-25 在 x86 上就撞到了这个：

```
$ echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/ntb_hw_epf/bind
tee: /sys/bus/pci/drivers/ntb_hw_epf/bind: No such device     ← 不是"没有这个文件"
$ ls /sys/bus/ntb/devices/
                                                              ← 空
```

`ENODEV` 只说明「没有这个设备」，不区分「链路没起来」和「编号变了」。所以三个地方
现在都改成按 **`1957:0809`** 查找，`03:00.0` 只作为初始猜测保留：

| 位置 | 行为 |
|---|---|
| `/usr/local/sbin/xgs-ntb-up.sh` | 每 5 s 扫一次 vendor/device，找到就切换 BDF 并打印 `endpoint enumerated at X (was Y)` |
| `/usr/local/sbin/xgs-ntb-watch.sh` | 健康检查用 ID 扫，不再只看死路径 |
| 维护盘 `install-npu.sh` | 报错信息里直接写端点到底在不在 |

排查时先用这个确认，比猜快得多：

```sh
sudo lspci -nn -d 1957: ; ls /sys/bus/ntb/devices/
```

### 20.7.4 `--retrain`：链路从没训练起来时唯一还有效的动作

如果端点连 sysfs 里都不存在（`lspci -d 1957:` 也是空），那不是驱动问题，是 LTSSM
根本没训练：端点比主机 POST 晚得多才 arm，主机的根端口早就放弃等它了。rescan 只会
重新读配置空间，读不到一个电气上不存在的设备。

`xgs-ntb-up.sh --retrain` 做的是：找到 secondary bus 是端点所在总线的那个根端口，
对它的 Link Control 写一次 **Link Disable，再清掉** —— LTSSM 重启，双方从 0 训练。
要点：

- **只写根端口**，不读也不写端点的配置空间（2026-11-25 在端点抖动时读它把主机读崩过）
- 链路断开会通常带着 NPU 一起复位，所以脚本给了 45 s 让它重新起来并 arm，中途每
  15 s 再 rescan 一次
- 这是「最后一次尝试」，不是常规路径；正常开机永远走不到这里

### 20.7.5 真正的原因（2026-11-25 实测）：`lspci` 看的是**缓存**的身份

这一条是查了很久才定下来的，值得记住：**`lspci`、`/sys/bus/pci/devices/.../vendor`
（`device`、`class` 同样）显示的是内核在枚举那一刻缓存的值，不是活的配置空间。**

于是出现了这样的画面：

```
$ sudo lspci -nn -s 03:
03:00.0 Ethernet controller [0200]: Marvell [11ab:7080]        ← 缓存
$ sudo setpci -s 03:00.0 0.w 2.w 8.l
1957                                                            ← 活的
0809
05000000
$ cat /sys/bus/pci/devices/0000:03:00.0/vendor
0x11ab                                                          ← 缓存，永远不变
```

也就是说：**NPU 侧的 `pci_epf_vntb` 写得完全正确**（线上确实是 `1957:0809`、
class `0x050000`）。问题是主机在 NPU 还没 arm 端点的时候就把这个 function 枚举了，
缓存了启动固件的原厂身份 `11ab:7080`；`ntb_hw_epf` 是按**缓存值**做匹配的，所以
永远匹配不上。**plain rescan 对已经存在的设备不会重读 ID**，只有
`remove` + `rescan`（重新枚举）才行。

修法与验证（同一台机器，实测）：

```sh
sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
            sleep 2; echo 1 > /sys/bus/pci/rescan'
lspci -nn -s 03:      # → 03:00.0 RAM memory [0500]: Freescale [1957:0809]
ls /sys/bus/ntb/devices/   # → 0000:03:00.0   （ntb_hw_epf 绑上了）
sudo /usr/local/sbin/xgs-ntb-up.sh
```

结果：`eth0` / `eth0.100` / `eth0.200` 全部起来，`eth0.100` 从上游拿到 DHCP
地址和默认路由（实测，地址从略）—— **x86 现在能上网了**，vNTB 数据通路完全正常。

`xgs-ntb-up.sh` 已经按这个做了：等不到 NTB 设备、但 PCI function 在、且它的
**缓存** ID 不是 `1957:0809` 时，自动 `remove`+`rescan` 一次（设备上没有驱动，
移除是安全的；NPU 可能因此复位，所以之后还补了 rescan）。

> 排查手法：判断端点身份**必须用 `setpci` 读活值**（`setpci -s 03:00.0 0.w 2.w
> 8.l`），`lspci` / sysfs 只能用来判断"内核此刻认为它是什么"。

### 20.7.6 附带的恢复手段：拉一次 Link Disable 就能复位 NPU（**现在有风险，见 §20.11.5**）

> **2026-11-25 更新**：这招后来把 x86 自己带下去了两次（`sysrq` 之外没有任何反应，
> 只能靠串口 SysRq 才救回来）。现在优先用**串口 SysRq**（BREAK + `s`/`b`）复位，
> 见 §20.11.5；Link Disable 只在 SysRq 完全没反应时才用。

2026-11-25 有一次 NPU 卡死在启动里（串口一个字都不出、板子 ping 不通）。用
`tools/on-x86/x86-linkoff-test.sh` 里那套 Link Disable 写法，对**根端口**
`00:03.1` 的 `CAP_EXP+10.w` 置 bit4 再清掉，NPU 立刻整机复位并从 BL1 重新启动，
串口日志完整。这条比 MCP2210 hold/release 省事，而且不需要额外工具。

### 20.7.7 对照开源实现 openwrt-sophos-xgs107（同一颗 SoC，很有参考价值）

[nicologiuliani6/openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)
是把 XGS 87/107 的两颗 CPU 都刷成 OpenWrt 的项目，vNTB 那部分和我们做的是同一件事。
它的 `docs/npu-x86-link.md` 把坑列得很全，逐条对照我们现在的状态：

| 他们的结论 | 我们的状态 |
|---|---|
| EP 节点 `snps,dw-pcie-ep`，`reg-names = dbi/dbi2/addr_space` = `0xf2600000` / `0xf2604000` / `0x80_0000_0000`，删掉 `dma-coherent` | **完全一致**（`board/cn9130-sophos-xgs87w-sfp10g.dts`） |
| `.align = SZ_1M`（BAR 匹配 iATU 忽略目标地址低 20 位） | **已有**（`ntb/0002`） |
| 端点只实现偶数 BAR，主机按 ctrl=0/db=2/mw=4 找 | **已有**（`BAR_1/3/5 = BAR_RESERVED`）。注意这三个 BAR 号是 `pci_epf_vntb` 的**只读** configfs 属性，驱动自己算，`xgs-vntb.sh` 里写过三行 `echo 0 > ctrl_bar` 之类，每次启动只换来 `Permission denied`（2026-11-25 删掉，改成把驱动算出来的值读回来打日志） |
| 必须用 MSI，不能 MSI-X（DW 核宣称 MSI-X 但只发 MSI） | **已有**（`.msix_capable = false`，主机侧优先 MSI） |
| `transport_mtu=2048` 两侧都要 | **已有** |
| 1 MiB 窗口只有 15 个 slot，默认 64 KiB 帧导致每个小包都要等一次往返 | 同上，`transport_mtu=2048` 解决 |
| 端点侧轮询要低于一个 tick | 我们用的是 **hrtimer**（`ntb/0001` 里 `poll_ns`），比他们的 1 ms `delayed_work` 更细 |
| **U-Boot 留下的 iATU 窗口要 disable** | **暂未采用**：我们的 BAR 匹配目前是通的（vNTB 实测拿到 DHCP + 默认路由）。这一条只有在"主机访问落到错误 DDR"时才需要；盲加反而有把现在能用的窗口关掉的 Risk，所以先记在这里，出现症状再启用（写法就是他们 951 补丁里那 4 行 `dw_pcie_disable_atu()`） |
| 端点消失会让主机自己重启（链路耦合） | 已知，见 [docs/09](09-remaining-work.md) |

他们没提到的一点、但这次真正卡住我们的是 **§20.7.5 的缓存身份问题** —— 他们大概
每次装完都是整机冷启动，主机枚举时端点已经 armed，所以撞不上。

## 20.8 重启的真实代价（一次完整实测）

x86 侧已经做到干净关闭（`/dev/mmcblk0p2: clean`，不再有 journal recovery），启动 38 → 26 秒：

| 阶段 | 时间 | 说明 |
|---|---|---|
| firmware | 11.0 s | 主板 POST，改 BIOS 才能动 |
| loader | **2 s** | 原来是 18.2 s —— `recordfail=1` 时 GRUB 等 30 s，已加 `GRUB_RECORDFAIL_TIMEOUT=2` |
| kernel | 4.0 s | |
| userspace | 5.6 s | 我们的单元合计不到 1 s |

NPU 的 Linux 只要 **10.8 s**（kernel 3.8 + userspace 7.0），
`xgs-ports-up` → `xgs-vntb` → `xgs-net-up` → `xgs-dhcp` 串起来约 2.7 s。

### NPU 仍会被牵连，但这是硬件的错

实测结论：**x86 一抽掉 PCIe 链路，NPU 就复位**，与我们做了什么无关：

| 试过的手段 | 结果 |
|---|---|
| 关机钩子先发 `COMMAND_LINK_DOWN` | x86 日志确认发出（`qp 0: Send Link Down`），NPU 仍复位 |
| NPU 侧 spad 读写加 `linkup` 守卫 | 守卫生效（不再 oops），仍复位 |
| 先把 EP 函数停掉（`start=0`）再重启主机 | EP 已停、主机安然无恙，NPU 仍复位 |
| 关掉 `panic_on_oops` / `hardlockup_panic` | 日志里连 panic 都没有，说明不是软件 panic |
| 看门狗状态 | `/sys/class/watchdog/watchdog0/state=inactive`，不是它 |

#### 用 ramoops + console 后端取证：这条路走不通（已实测；自编内核已退役）

> 这一小节记录的是 2026-11-23 那版自编内核（带 `CONFIG_PSTORE_CONSOLE`）。
> 结论是 ramoops 在这块板子上没用，所以后来 NPU 又切回了发行版内核；下面的过程
> 只作为"为什么不用 ramoops"的证据。

给 NPU 的 DTB 加了 `ramoops`（DRAM 最后 1 MiB，`ramoops@7ff00000`），
并在 [board/](../board/) 的 DTS 里补了 `console-size = 0x80000` / `pmsg-size = 0x20000`，
同时**重编了 NPU 内核**把 `CONFIG_PSTORE_CONSOLE` / `CONFIG_PSTORE_PMSG` 从 `n` 改成 `y`
（`Image` 从 37.7 MB 变成 44.3 MB，`vermagic` 仍是 `6.12.117+deb13-arm64`，
`Module.symvers` 与 Debian 头包**逐字节相同**，所以所有自编模块不用重编）。

新内核上线后确认 console 后端真的挂上了：

```
[    6.524286] printk: legacy console [ramoops-1] enabled
[    6.536984] pstore: Registered ramoops as persistent store backend
[    6.543247] ramoops: using 0x100000@0x7ff00000, ecc: 0
```

然后照原样复现（从 x86 侧 `systemctl reboot`）：

```
npu uptime: 0 min        ← 又被牵连复位了
pstore: 0 records         ← console 后端明明在跑，却一条都没留下
```

**为什么**：这颗 SoC **每次复位都会重跑 BootROM → `mv_ddr` 训练 + 全内存 scrub**
（见 [03 §3.1](03-boot-chain.md) 的启动日志 `mv_ddr: scrubbing memory...`）。
保留区在 Linux 还没起来之前就被清干净了，所以 **ramoops 在这块板子上永远读不到上一次的内容**，
不管它是 panic、硬锁死还是 PERST# 复位。

#### 改用 netconsole（现在用的方案）

既然"事后读内存"不行，就改成"**事发前就把每一行 printk 送出去**"：

| 端 | unit | 做法 |
|---|---|---|
| NPU | `xgs-netconsole.service` | `modprobe netconsole`，双目标都走 `br-lan`：①`10.234.56.2`（x86）②`10.234.56.50`（操作者的 PC，示例地址/MAC，按你自己的监听机改） |
| x86 | `xgs-netconsole.service` | `nc -u -l -k 6666` → `/var/log/npu-netconsole.log` |
| PC | [tools/on-pc/netconsole-listen.py](../tools/on-pc/netconsole-listen.py) | 收 UDP 6666 存文件 |

- 打两个目标的原因：**走管理 VLAN 的那个能在 NPU 硬锁死时把日志送出来**（那一刻 PCIe 链路还活着）；
  **走 `br-lan` 的那个能在 NPU 整个复位、PCIe 全掉之后继续工作**（只要交换机和线还在）。
- 实测：`echo test > /dev/kmsg` 后 x86 立刻在 `/var/log/npu-netconsole.log` 里看到。
- 加载时内核会把 **printk 环形缓冲区的历史整段重放**给新控制台（约 30 KB），属正常现象。

#### A/B 判别（硬锁死 vs PERST#）仍然待定

| 可能 | 特征 |
|---|---|
| A. 内核在 `ntb_transport` 掉链路径里**硬锁死**，随后 SoC 被复位 | 控制台最后两行是 `qp 0: Link Cleanup`，之后静默 |
| B. PERST# **直接**复位 SoC，内核来不及做任何事 | 同样静默 |

现有证据仍偏向 A：`Link Cleanup` 是 **NPU 内核自己打印的**。
现在 netconsole 已经把"死前最后几行"永久留在 x86 / PC 的磁盘上，
下一次复现就能直接看 `tail -50 /var/log/npu-netconsole.log` 定案。

复位发生在**主机断链的那一瞬间**（不是 30 秒后），属于板级设计（这颗 EP 本来就不预期主机会
单独重启）。要靠 ATF/板级配置解决，超出内核能改的范围 —— 这条路到此为止。

**实际影响**：x86 重启 → NPU 跟着重启 → 40 秒后两者都自己回来，链路、VLAN、DHCP 全部自动重建。
不需要人碰机器，但 NPU 的 uptime 会归零。

## 20.9 模块替换（历史；现在镜像用发行版原版）

| 模块 | 改动 | 结果 |
|---|---|---|
| `mvpp2` | `MVPP2_AGGR_TXQ_SIZE` 256 → **512** | ✅ 曾交叉编译并上线；现在镜像用发行版原版，512 版是可选优化 |
| `mv88e6xxx` | 两个 TCAM 越权补丁（`e3624f5eeac4` + `242ebf4c5114`） | ✅ 曾交叉编译并上线，9 个 netdev 正常；现在镜像用发行版原版，补丁留在 [net/patches/](../net/patches/) 备用 |

> 为什么又改回发行版：两个改动都只是加固/调优，不是功能必需；用发行版原版可以让
> `apt upgrade` + DKMS 的维护面最小。见 [19](19-module-vs-kernel-rebuild.md) §19.2。

### 交叉编译（不要再走 qemu 模拟）

Debian 的 `linux-headers` 包里 `scripts/` 是 **arm64 二进制**（`fixdep`、`modpost`），
在 x86 上跑不了，所以之前只能把整个 rootfs 塞进 qemu-user 里编 —— 一个 216 KB 的
`mvpp2_main.c` 要十几分钟。正解是用**完整源码树 + 交叉编译器**，host 工具用宿主 gcc 编，
只有模块代码走交叉 gcc：

```sh
apt-get install gcc-14-aarch64-linux-gnu flex bison bc libelf-dev libssl-dev

# 1) 准备独立输出目录，喂进 NPU 自己的 config
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 modules_prepare

# 2) modules_prepare 不生成 Module.symvers，从 headers 包里借
cp /srv/npu/usr/src/linux-headers-6.12.117+deb13-arm64/Module.symvers /srv/kbuild/

# 3) vermagic 必须带 Debian 的后缀，否则 modprobe 直接拒载
#    （LOCALVERSION= 会被 olddefconfig 吃掉，源码根目录 localversion 文件会和
#     CONFIG_LOCALVERSION 重复；正确做法是直接改 .config 里的 CONFIG_LOCALVERSION）
grep CONFIG_LOCALVERSION /srv/kbuild/.config     # CONFIG_LOCALVERSION="+deb13-arm64"
grep UTS_RELEASE /srv/kbuild/include/generated/utsrelease.h   # "6.12.117+deb13-arm64"

# 4) 按内核自己的 Kbuild 编（不要在外部目录手拼 Makefile）
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     M=$SRC/drivers/net/dsa/mv88e6xxx modules
```

一套下来 **十几秒**，比 qemu 快两个数量级。脚本见 [tools/build/build-npu-net.sh](../tools/build/build-npu-net.sh)。

### 踩过的两个坑

| 现象 | 真因 |
|---|---|
| 模块能加载，但 `p1..p8/sfp` 全部消失，dmesg 一行错都没有 | 我在外部目录**手拼 Makefile**，漏了内核 Kbuild 里的条件对象，`dsa_register_switch()` 之后没下文。必须用 in-tree Kbuild。 |
| dmesg 出现 `decompression failed with status 6`，模块根本没被加载 | 手工用 `xz -9` 压的模块：64 MiB 字典**超出内核 xz 解码器允许范围**。小字典（`--lzma2=dict=1MiB`）或干脆放未压缩的 `.ko` 都行。反过来说，`make modules_install` 自己产出的 `.ko.xz` 是能加载的 —— 镜像里 `/lib/modules/*/updates/` 那四个就是 `.ko.xz`（`CONFIG_MODULE_COMPRESS_XZ=y`），一直在用。 |

第二个坑特别有欺骗性：`lsmod` 里看不到模块，但启动过程不报错，看起来就像"驱动不 probe"。

### 回滚

```sh
D=/lib/modules/6.12.117+deb13-arm64/kernel/drivers/net/dsa/mv88e6xxx
# 放未压缩的 .ko（手工 xz -9 的 64 MiB 字典会被内核解码器拒绝）
cp -a $D/mv88e6xxx.ko.orig $D/mv88e6xxx.ko
depmod -a && reboot
```

交换机一死，NPU 就只能从 console 进（面板口全没了），所以动 `mv88e6xxx` 之前必须确认
`/dev/ttyS2` 这条路是通的。

## 20.10 自愈与手动恢复（历史漏洞 + 现在的安全策略）

### 漏洞一：watcher 只看 `carrier`

主机侧读到的 `carrier` 仍然是 1，而 NPU 那侧已经把链路丢了 —— 两边状态不一致，
`carrier` 恒为 1，watcher 永远不动手。

→ 现在同时检查 `carrier` 和**实际可达性**（ping `10.234.56.1`）。

### 漏洞二：`ntb_epf_spad_write()` 会在端点上写野指针（**这才是主因**）

修好判据之后发现，watcher 一动手整机就 panic。抓住的现场：

```
BUG: unable to handle page fault for address: ffffd14d00afffff
Oops: 0002 [#1] PREEMPT SMP NOPTI
RIP: ntb_epf_spad_write+0x34/0x40 [ntb_hw_epf]
Call Trace:
 ntb_transport_link_cleanup+0xae/0xd0 [ntb_transport]
 ntb_transport_free
 ntb_remove
 bus_remove_driver / ntb_transport_exit / __do_sys_delete_module
Kernel panic - not syncing: Fatal exception
```

原因和之前修过的门铃是同一类：`spad_offset` 是从**端点 BAR 里读出来的寄存器**，
端点没了以后读回 `0xffffffff`，直接当偏移用 → 写到不相干的页 → `panic_on_oops=1` 立刻重启。
之前的补丁只给 `ntb_epf_peer_db_set()` 加了守卫，**漏了 spad 的读和写**。

→ [ntb/0101-ntb_hw_epf.patch](../ntb/0101-ntb_hw_epf.patch) 现在给
`ntb_epf_spad_read()` / `ntb_epf_spad_write()` 也加了同样的判据（`~0U` 或超出 1 MiB 的 ctrl BAR 就丢弃），
日志是 `endpoint unreachable, dropping spad read/write`。

### 漏洞三（顺带）：只 `remove`+`rescan` 不够

NPU 重启后它自己重新编程了 BAR 尺寸寄存器和 inbound iATU，旧的 BAR 地址全指向空气。
所以"完整恢复"要按下面这个顺序，**而且只能在确认 NPU 已经起来、不在启动窗口时做**：

```
down eth0.200 / eth0.100 / eth0
rmmod ntb_netdev → ntb_transport → ntb_hw_epf     （顺序反了就等于把设备从活着的驱动脚下抽走）
echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
echo 1 > /sys/bus/pci/rescan                       （让主机重新读 BAR 尺寸并重新分配）
xgs-ntb-up.sh                                      （握手、重建 VLAN、补地址）
```

现在**不再自动执行这段**。可用的入口只有两个：

- `xgs-ntb-up.sh --force-rescan`：只做一次 remove/rescan，不 rmmod；NPU 已经起来时够用；
- 上面的完整重置：手动做，失败就断电重启 x86/NPU，不要把 rmmod 写成循环或自动服务。

> 教训：**别在 x86 上手工 `rmmod ntb_hw_epf`** —— 在端点已经失联时，那一步会把整机带崩。
> 关机钩子（`xgs-ntb-stop.service`）里的顺序是安全的。

## 20.11 换掉 NPU 的根分区：唯一安全的做法，以及写坏之后怎么救

2026-11-25 用错了方法，把 NPU 的 p2 写坏了，代价是两台机器各宕一次。这一节把这
条路踩实，以后不要再试别的方式。

### 20.11.1 为什么"dd 到正在使用的根分区"一定会坏

那天的顺序是：

```
sync; dd of=/dev/mmcblk0p2 bs=1M conv=fsync     # 边跑边用旧根，45 秒写完 1.5 GB
sync; reboot
```

`conv=fsync` 只保证**设备**的写回落盘，管不了**旧文件系统还挂在内存里的脏数据**。
dd 一结束，旧 ext4（大小还是 597 MiB 时代的）继续按它自己的位图和 inode 表往下写：
journald 每几秒写一次日志，落点就是新镜像的元数据区。`reboot` 也写到那里。

结果（`e2fsck -fn /dev/mmcblk0p2` 实测）：

```
Inode 9635 passes checks, but checksum does not match inode.
Inode 9643 passes checks, but checksum does not match inode.
Multiply-claimed block(s) in inode 7: 26624--28669
```

现场症状很有辨识度：**随机某个二进制执行时报 `Input/output error`**（`grep`、
`lsinitramfs`、`depmod` 都中过），sshd 在 `kex_exchange_identification` 就
`Connection reset by peer`，串口 getty 能回显但 `login` 卡死。原因是这些进程要读的
块正好被写坏了，而它们各自的运气不同。

同一个机制也解释了 20.7.5 那个"缓存身份"坑：**只要旧文件系统还活着，它就会继续
写**。

### 20.11.2 正确的换根流程

三选一，按可靠性排：

1. **在 initramfs 里换**（p2 没有挂载，最干净）：`break=premount` 或急救 initramfs，
   在那里 `dd` / 解包。缺点是镜像得能进到 RAM 或另一个分区。
2. **先把根变成只读再 dd**：`mount -o remount,ro /` 成功之后 dd 才安全。注意它经常
   直接 EBUSY（有进程正开着文件写），`echo u > /proc/sysrq-trigger`（紧急只读重挂）
   也不保证成功；两条都失败就**不要** dd。
3. **只修不换**：文件系统只是元数据坏了就用 `e2fsck`（见 20.11.3）。2026-11-25 就是
   这么修的，修完 `md5sum -c` 对着 dpkg 的 `.md5sums` 全量校验，**3435 个"失败"全是
   镜像构建时故意排除的 `/usr/share/doc`、`/usr/share/man`，真正的校验错 0 个** ——
   所以元数据修复之后不需要重刷。

### 20.11.3 写坏之后的自救：让 initramfs 在挂载前修一次

前面说过镜像里的 initramfs **根本没有 fsck**（20.11.4），所以第一件事是把它补进去：

```sh
# 1) 让 fsck hook 别再"探测设备"，直接认 ext4
printf 'FSTYPE=ext4\n' > /etc/initramfs-tools/conf.d/10-xgs87-fstype.conf
# 2) 兜底 hook 把 fsck 本体也拷进去（见 image/overlay/common/etc/initramfs-tools/hooks/xgs87-e2fsck）
update-initramfs -u -k "$(uname -r)"
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'sbin/fsck'   # 必须能看到 usr/sbin/fsck
```

然后借 U-Boot 的环境变量强制一次（**不要 saveenv**，只在内存里改）：

```sh
fw_setenv bootargs_deb 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 \
  root=/dev/mmcblk0p2 rootwait rw fsck.mode=force fsck.repair=yes'
reboot
# 起来后确认干净，再把 bootargs_deb 改回去：
#   console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw
```

`fsck.mode=force` / `fsck.repair=yes` 是 initramfs-tools 自己认的（
`/usr/share/initramfs-tools/init:188-192` → `forcefsck=y`、`fsckfix=y`），不是 systemd
的专利。修完的开机日志里会看到正常的一次：

```
[/sbin/fsck.ext4 (1) -- /dev/mmcblk0p2] fsck.ext4 -a -C0 /dev/mmcblk0p2
root: clean, 16457/97536 files, 168940/390144 blocks
```

### 20.11.4 镜像的 initramfs 里为什么没有 fsck（已修）

开机一直打 `Warning: fsck not present, so skipping root file system`。原因不是没装
e2fsprogs，而是 initramfs-tools 的 stock `fsck` hook 有个反直觉的分支：**对 `/` 它不信
`/etc/fstab` 写的类型，要去探测设备**（`/usr/share/initramfs-tools/hooks/fsck` 里那段
`if [ "${MNT_DIR}" = "/" ]`），而 chroot 里没有 `/dev/mmcblk0p2` 可探 → `fsck_types`
为空 → 整个 hook 直接 `exit 0`，一个二进制都不拷。

修法（`image/overlay/common/` 下，两侧共用）：

- `etc/initramfs-tools/conf.d/10-xgs87-fstype.conf` → `FSTYPE=ext4`，hook 走不探测的
  分支；顺带 arm64 交叉构建下 `copy_exec` 解析库失败时也有兜底。
- `etc/initramfs-tools/hooks/xgs87-e2fsck` → 无条件拷 `e2fsck`、`fsck.ext4`、
  **`fsck` 本体**、`logsave`。只拷 `fsck.ext4` 不够：`scripts/functions` 里是
  `command -v fsck` 判断，缺了它照样跳过。
- `image/setup.sh` 现在**两侧都重建 initramfs 并校验** `(usr/)?sbin/fsck` 在不在，
  不在就打警告。以前只有 NPU 侧重建，x86 侧用的还是内核包在 mmdebstrap 阶段生成
  的那份（那时 overlay 还没拷进去）。

### 20.11.5 复位两台机器：串口 SysRq（不碰 PCIe）

那天的教训：**从 x86 去拉根端口 `00:03.1` 的 Link Disable 会把 x86 自己带下去**
（20.7.6 那招现在不再可靠）。可靠的替代是串口 SysRq：

```sh
# 在 x86 上对 NPU 的 /dev/ttyS2，或用 COM5 对 x86 自己的 ttyS0
# 1) 发一个 BREAK（.NET: SerialPort.BreakState，Linux: termios.tcsendbreak）
# 2) 250 ms 内发一个字符：s=sync  u=只读重挂  b=立刻复位
```

实测 NPU 回了 `sysrq: HELP : ...`，`b` 干净复位并回到 U-Boot；x86 在用户态已经卡死
（回车只回 CRLF、没有 shell）的情况下，`s`+`b` 照样把机器拉了回来。**用户态挂了也要
能救**，这是它比脚本更值钱的地方。

### 20.11.6 NPU 一重启，x86 那条 vNTB 就不会自己回来

实测两次：NPU 重启后 x86 侧 `eth0` 的 operstate 停在 DOWN / 端点
`endpoint unreachable, dropping doorbell`，`xgs-ntb-watch` 因为 `AUTO_RECOVER=0`
只记日志不动手，于是**从 PC 到 x86 的路整段消失**（PC → NPU br-lan → eth0.200 → x86）。
现在镜像里默认 `AUTO_RECOVER=1`（`image/overlay/x86/etc/default/xgs-ntb-watch`）：链路
连续 5 分钟不通就主动跑一次 `xgs-ntb-up.sh --force-rescan`，之后冷却 10 分钟。5 分钟
的延迟是为了不打断正在启动的 NPU（它的 Linux 只要 11 秒）。

## 20.12 当前网络


| 位置 | 地址 | 说明 |
|---|---|---|
| NPU | `br-wan` 上的 DHCP 租约 | 面板 `2/WAN` 插上游才拿到；管理走这条地址 |
| x86 | `eth0.100` 的 DHCP 租约（MAC `02:58:47:53:00:11`） | 同一段上游，默认路由从这里来 |
| x86 ↔ NPU（LAN） | `10.234.56.2` ↔ `10.234.56.1` | VLAN 200 走 vNTB |
| 面板 1/LAN | `br-lan` 静态 `10.234.56.1/24` | 插笔记本（自己配 `10.234.56.x`）可同时访问 `.1` / `.2` |

## 20.13 还是开着的问题

1. `ntb_transport` 的 link-cleanup 在掉链时会把 NPU 卡住（两条 `qp 0: Link Cleanup` 之后静默），
   随后被复位。要根治得能在掉链瞬间抓到栈 —— `ramoops` 已加到 DTB 并被证伪（DDR scrub），
   netconsole 又挂在 `br-lan`（掉链时桥端口全 down，发不出包；直接挂 `p1` 也不行，
   DSA 端口不支持 netpoll）。现在只能靠 netconsole 在复位前把最后几行送出去。
2. x86 上手工 `rmmod ntb_hw_epf` 仍会把它自己搞崩（`panic_on_oops` 之后 30 秒自重启）。
   关机流程（`xgs-ntb-stop.service`）是安全的，手工拆要小心。
3. 2026-11-23 那台 PC 的 USB 网卡（Windows 的 `Ethernet 2`）曾经消失，`192.168.1.1` 那条
   旁路暂时不通；维护 U 盘的 U-Boot 路径需要一块可用的 USB 网卡。
