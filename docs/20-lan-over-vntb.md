# 20 — 一条 PCIe 链路同时跑两套网络

> 🏷 **状态（2026-11-23 复核）**：✅ **全部实测**：VLAN 双网、NPU 串口 57600、hrtimer 提性能、模块替换、ramoops 取证（证明没有 panic，锁死 vs PERST 仍待区分）。

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

## 20.8 重启的真实代价（一次完整实测）

x86 侧已经做到干净关闭（`/dev/mmcblk0p2: clean`，不再有 journal recovery），启动 38 → 26 秒：

| 阶段 | 时间 | 说明 |
|---|---|---|
| firmware | 11.0 s | 主板 POST，改 BIOS 才能动 |
| loader | **2 s** | 原来是 18.2 s —— `recordfail=1` 时 GRUB 等 30 s，已加 `GRUB_RECORDFAIL_TIMEOUT=2` |
| kernel | 4.0 s | |
| userspace | 5.6 s | 我们的单元合计不到 1 s |

NPU 的 Linux 只要 **10.8 s**（kernel 3.8 + userspace 7.0），
`xgs-ports-up` → `xgs-vntb` → `xgs-mgmt-bridge` → `xgs-lan-uplink` → `xgs-lan-dhcp` 串起来约 2.7 s。

### NPU 仍会被牵连，但这是硬件的错

实测结论：**x86 一抽掉 PCIe 链路，NPU 就复位**，与我们做了什么无关：

| 试过的手段 | 结果 |
|---|---|
| 关机钩子先发 `COMMAND_LINK_DOWN` | x86 日志确认发出（`qp 0: Send Link Down`），NPU 仍复位 |
| NPU 侧 spad 读写加 `linkup` 守卫 | 守卫生效（不再 oops），仍复位 |
| 先把 EP 函数停掉（`start=0`）再重启主机 | EP 已停、主机安然无恙，NPU 仍复位 |
| 关掉 `panic_on_oops` / `hardlockup_panic` | 日志里连 panic 都没有，说明不是软件 panic |
| 看门狗状态 | `/sys/class/watchdog/watchdog0/state=inactive`，不是它 |

#### 用 ramoops 把这件事钉死

给 NPU 的 DTB 加了 `ramoops`（DRAM 最后 1 MiB，`ramoops@7ff00000`，`/sys/fs/pstore` 可用；
DTB 在 [board/](../board/)，旧版备份为 `/boot/*.dtb.pre-ramoops`），然后把
`panic_on_oops` / `hardlockup_panic` 打开再复现：

```
npu uptime: 53s          ← 又复位了
pstore: 0 records        ← 但一个字都没留下
```

**没有任何 panic 记录**。这条能证明的是：掉链路径**没有触发内核 panic**（若有，pstore 必有
`dmesg-ramoops-0`）。它**不能**区分下面两种情况 —— 两者都不会留下 panic 记录：

| 可能 | 特征 |
|---|---|
| A. 内核在 `ntb_transport` 掉链路径里**硬锁死**，随后 SoC 被复位 | 控制台最后两行是 `qp 0: Link Cleanup`，之后静默 |
| B. PERST# **直接**复位 SoC，内核来不及做任何事 | 同样静默 |

现有证据更偏向 A：`Link Cleanup` 是 **NPU 内核自己打印的**，说明链路断开后它还活了一下才死。
但要真正分清，得让 lockup 检测器在复位前抓到栈 —— 这颗内核 `CONFIG_PSTORE_CONSOLE=n`，
pstore 只能记 panic，记不了锁死；串口又只有一条、且那一刻主机正在重启，抓不到。

**结论（诚实版）**：软件侧能试的都试过了（见上表），没有任何一项改变结果；复位的确切机制
在 A/B 之间仍待定，而两者都需要 ramoops 的 console 后端或第二条串口才能继续区分。

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

一套下来 **十几秒**，比 qemu 快两个数量级。脚本见 [tools/build-npu-net.sh](../tools/build-npu-net.sh)。

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

交换机一死，NPU 就只能从 console 进（p4 也没了），所以动 `mv88e6xxx` 之前必须确认
`/dev/ttyS2` 这条路是通的。

## 20.10 自愈的一个漏洞（已修）

原来 `xgs-ntb-watch` 只看 `carrier`。今天踩到的是另一种坏法：**主机侧读到的 carrier 仍然是 1，
而 NPU 那侧已经把链路丢了** —— 两边状态不一致，`carrier` 恒为 1，watcher 永远不会动手，
链路就一直是死的。

现在 watcher 同时检查 `carrier` 和**实际可达性**（ping `192.168.100.1`），任一异常持续约 60 秒
就重新枚举。

## 20.11 当前网络

| 位置 | 地址 | 说明 |
|---|---|---|
| x86 | `192.168.0.50`（DHCP，MAC `02:58:47:53:00:31`） | 家里内网，可直连 SSH |
| NPU | `192.168.0.66`（DHCP on `br-lan`） | 家里内网，可直连 SSH |
| x86 ↔ NPU 管理 | `192.168.100.2` ↔ `.1` | VLAN 100 走 vNTB，RTT **0.46 ms** |
| 前面板 p8 | `br-mgmt` access 口 | 插笔记本同时访问 `.1` / `.2` |

## 20.12 还是开着的问题

1. `ntb_transport` 的 link-cleanup 在掉链时会把 NPU 卡住（两条 `qp 0: Link Cleanup` 之后静默），
   随后被复位。要根治得能在掉链瞬间抓到栈 —— 这颗芯片没有 pstore/ramoops，netconsole 又挂在
   `br-lan` 上（掉链时桥端口全 down，发不出包；挂 `p4` 也不行，DSA 端口不支持 netpoll）。
   下一步：给 DTB 加 `ramoops` 节点，让 panic/lockup 落盘。
2. x86 上手工 `rmmod ntb_hw_epf` 仍会把它自己搞崩（`panic_on_oops` 之后 30 秒自重启）。
   关机流程（`xgs-ntb-stop.service`）是安全的，手工拆要小心。
3. PC 那块 USB 网卡（Windows 里的 `Ethernet 2`）已从系统里消失，`192.168.1.1` 这条路暂时不通。
