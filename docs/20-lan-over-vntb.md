# 20 — 一条 PCIe 链路同时跑 WAN 和 LAN

> 🏷 **状态（2026-11-24 复核）**：✅ 线路上实测过：VLAN 双网、NPU 串口 57600、hrtimer 提性能、模块替换、**netconsole 崩溃取证**；
> ⚠️ WAN/LAN 拆分（§20.2）只做过 netns + QEMU 验证，还没上真机。
> ⚠️ `ramoops` 已证伪（每次复位都 DDR scrub），硬锁死 vs `PERST#` 仍待一次复现定案（§20.8）。

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
| `xgs-ntb-watch.service` | x86 | 每 15 s 查 `carrier` + ping `10.234.56.1`；任一异常持续约 60 s 就做**完整重置**（见 §20.10），然后重建 VLAN 和地址 |
| `/etc/sysctl.d/90-xgs-panic.conf` | 两边 | `kernel.panic=30`、`panic_on_oops=1`、`hardlockup_panic=1` |

实测（2026-11-23）：**只重启 NPU，x86 不重启**，约 90 秒后链路自己回来：

```
18:57:46 xgs-ntb-watch: link unhealthy, full reset
18:57:46 ntb_hw_epf: endpoint unreachable, dropping spad read   ×1
18:57:47 ntb_hw_epf: endpoint unreachable, dropping spad write  ×10
18:57:5x xgs-ntb: eth0 UP / eth0.100 UP (DHCP) / eth0.200 UP 10.234.56.2/24
```

x86 的 uptime 全程连续（没有 panic、没有重启），NPU 侧 `eth0` 也随之变 UP。

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

#### 用 ramoops + console 后端取证：这条路走不通（已实测）

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

## 20.9 模块替换：两个都上了

| 模块 | 改动 | 结果 |
|---|---|---|
| `mvpp2` | `MVPP2_AGGR_TXQ_SIZE` 256 → **512** | ✅ 交叉编译，已上线 |
| `mv88e6xxx` | 两个 TCAM 越权补丁（`e3624f5eeac4` + `242ebf4c5114`） | ✅ 交叉编译，已上线，9 个口正常 |

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
| dmesg 出现 `decompression failed with status 6`，模块根本没被加载 | `xz -9` 的 64 MiB 字典**超出内核 xz 解码器允许范围**。要么用小字典（`--lzma2=dict=1MiB`），要么干脆不压缩直接放 `.ko` —— 现在就是直接放 `.ko`。 |

第二个坑特别有欺骗性：`lsmod` 里看不到模块，但启动过程不报错，看起来就像"驱动不 probe"。

### 回滚

```sh
D=/lib/modules/6.12.117+deb13-arm64/kernel/drivers/net/dsa/mv88e6xxx
cp -a $D/mv88e6xxx.ko.xz.orig $D/mv88e6xxx.ko.xz
depmod -a && reboot
```

交换机一死，NPU 就只能从 console 进（面板口全没了），所以动 `mv88e6xxx` 之前必须确认
`/dev/ttyS2` 这条路是通的。

## 20.10 自愈：两个叠在一起的漏洞（都已修，实测通过）

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
所以恢复必须是**完整重置**，顺序不能改：

```
down eth0.200 / eth0.100 / eth0
rmmod ntb_netdev → ntb_transport → ntb_hw_epf     （顺序反了就等于把设备从活着的驱动脚下抽走）
echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
echo 1 > /sys/bus/pci/rescan                       （让主机重新读 BAR 尺寸并重新分配）
xgs-ntb-up.sh                                      （握手、重建 VLAN、补地址）
```

这段现在内联在 `xgs-ntb-watch.sh` 的 `recover()` 里，失败后还有 30 s 冷却。

> 教训：**别在 x86 上手工 `rmmod ntb_hw_epf`** —— 在端点已经失联时，那一步会把整机带崩。
> 交给 watcher 做（它按正确顺序来），或者关机钩子做。

## 20.11 当前网络

| 位置 | 地址 | 说明 |
|---|---|---|
| NPU | `br-wan` 上的 DHCP 租约 | 面板 `2/WAN` 插上游才拿到；管理走这条地址 |
| x86 | `eth0.100` 的 DHCP 租约（MAC `02:58:47:53:00:11`） | 同一段上游，默认路由从这里来 |
| x86 ↔ NPU（LAN） | `10.234.56.2` ↔ `10.234.56.1` | VLAN 200 走 vNTB |
| 面板 1/LAN | `br-lan` 静态 `10.234.56.1/24` | 插笔记本（自己配 `10.234.56.x`）可同时访问 `.1` / `.2` |

## 20.12 还是开着的问题

1. `ntb_transport` 的 link-cleanup 在掉链时会把 NPU 卡住（两条 `qp 0: Link Cleanup` 之后静默），
   随后被复位。要根治得能在掉链瞬间抓到栈 —— 这颗芯片没有 pstore/ramoops，netconsole 又挂在
   `br-lan` 上（掉链时桥端口全 down，发不出包；直接挂 `p1` 也不行，DSA 端口不支持 netpoll）。
   下一步：给 DTB 加 `ramoops` 节点，让 panic/lockup 落盘。
2. x86 上手工 `rmmod ntb_hw_epf` 仍会把它自己搞崩（`panic_on_oops` 之后 30 秒自重启）。
   关机流程（`xgs-ntb-stop.service`）是安全的，手工拆要小心。
3. PC 那块 USB 网卡（Windows 里的 `Ethernet 2`）已从系统里消失，`192.168.1.1` 这条路暂时不通。
