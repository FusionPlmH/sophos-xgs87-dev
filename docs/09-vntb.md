# 09 · vNTB：链路、性能、排障与自愈

> 🏷 **状态（2026-11-25 复核）**：✅ 链路在现机上通（`10.234.56.2` ↔ `10.234.56.1`，RTT 0.6 ms，
> 单流 1.2 Gbit/s）。§9.3.5 记的是**真正的原因**，之前几轮都判错了。
> ⚠️ `ramoops` 已证伪（每次复位都 DDR scrub）；硬锁死 vs `PERST#` 仍待一次复现定案。
> ⚠️ NPU 一重启，x86 那条链路**不会自己回来**，所以 `xgs-ntb-watch` 默认 `AUTO_RECOVER=1`
> （见 [11](11-operations.md) §11.2.6）。

**这份文档只讲 vNTB 这一条链路**：它跑得多快、坏了怎么查、怎么自己恢复。
网络怎么分段（VLAN/WAN/LAN/NAT）在 [08](08-network.md)；整机的开关机顺序和换盘在
[11](11-operations.md)；端点那一端的内核模块在 [15](15-modules-and-kernel.md)。

链路两端的脚本：

| 端 | 脚本 | 干什么 |
|---|---|---|
| NPU（PCIe endpoint） | `systemd/npu/xgs-vntb.sh` | configfs 建 `pci_epf_vntb`（`1957:0809`）→ `start` EPC → `ntb_transport` + `ntb_netdev` |
| x86（host） | `systemd/x86/xgs-ntb-up.sh` | 找端点（按 `1957:0809`，BDF 由 BIOS 分配）→ 必要时重枚举一次 → 等 netdev → 建 `eth0.100/.200` 并钉 MAC |
| x86 | `systemd/x86/xgs-ntb-watch.sh` | 每 15 s 查 carrier + ping 对端；5 分钟不通自动恢复一次 |

## 9.1 吞吐与延迟实测（iperf3 + ping，走 vNTB）

| 场景 | 原始（1 jiffy 轮询） | 改 hrtimer 之后 |
|---|---|---|
| 单流 TCP | 969 Mbits/s | **1.20 Gbits/s** |
| 4 流 TCP | 1.18 Gbits/s | 1.18 Gbits/s |
| ping RTT（x86→NPU） | 1.2 – 13.8 ms，avg 4 – 7 ms | **0.23 – 1.2 ms，avg 0.6 ms** |
| 空闲 CPU | — | 0.0%（自动退避到 1 ms） |
| PCIe 链路 | 8.0 GT/s ×2 = 15.75 Gb/s 可用（x86 根端口只给 x2） | 同 |

单流就能吃满 1.2 Gb/s、4 流不再涨 → 瓶颈是**单个 QP / 单发送队列**，不是 CPU。
家里 LAN 是 1G，这个数已经够；要吃更多得上多 QP。

## 9.2 延迟的真正来源：门铃是被"轮询"的

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

## 9.3 自愈

| 机制 | 位置 | 作用 |
|---|---|---|
| `xgs-ntb-watch.service` | x86 | 每 15 s 查 `carrier` + ping `10.234.56.1`；异常时先只重建本地 VLAN/地址。镜像里默认 `AUTO_RECOVER=1`：连续 5 分钟异常后跑一次 `xgs-ntb-up.sh --force-rescan`，然后冷却 10 分钟（见 §11.2.6） |
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
按在启动里，正是 2026-11-25 的 3.2 s 复位循环。所以现在是"**每次运行最多一次、且只
在端点身份还是固件出厂值时才做**"，`xgs-ntb-watch` 自动兜底也要等 5 分钟（NPU 的
Linux 只要 11 s），不会撞上启动窗口。需要手动触发时用
`sudo /usr/local/sbin/xgs-ntb-up.sh --force-rescan`。

### 9.3.1 rescan 也不是万能的：链路得在 POST 时训练过

`--force-rescan` 只是让主机重新读配置空间。如果 `03:00.0` 在 rescan 之后**始终
不出现**，说明主机侧从来没枚举到过这个端点 —— 常见于"x86 先开机、NPU 后来才部署
（或换镜像重装）"。这时 rescan 写多少次都没用，唯一可靠的办法是**让 x86 重启一次，
NPU 保持开机**，由 BIOS 在 POST 阶段重新训练 PCIe 链路。

2026-11-25 装完新镜像后就是这样：NPU 侧端点已 armed（`0x1957:0x0809`、`start=1`），
NPU 自己 `eth0` 有 MAC 但 `NO-CARRIER`，而 x86 上 `ip a` 只有 `lo`（x86 本身没有
物理网口，它的唯一网口就是 vNTB 的 `eth0`），rescan 也不产生设备 → 需要重启 x86。

### 9.3.2 「`lspci` 有设备、`eth0` 没有」的第三种可能：没人绑它

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

### 9.3.3 端点不一定是 `03:00.0`

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

### 9.3.4 `--retrain`：链路从没训练起来时唯一还有效的动作

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

### 9.3.5 真正的原因（2026-11-25 实测）：`lspci` 看的是**缓存**的身份

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

### 9.3.6 附带的恢复手段：拉一次 Link Disable 就能复位 NPU（**现在有风险，见 §11.2.5**）

> **2026-11-25 更新**：这招后来把 x86 自己带下去了两次（`sysrq` 之外没有任何反应，
> 只能靠串口 SysRq 才救回来）。现在优先用**串口 SysRq**（BREAK + `s`/`b`）复位，
> 见 §11.2.5；Link Disable 只在 SysRq 完全没反应时才用。

2026-11-25 有一次 NPU 卡死在启动里（串口一个字都不出、板子 ping 不通）。用
`tools/on-x86/x86-linkoff-test.sh` 里那套 Link Disable 写法，对**根端口**
`00:03.1` 的 `CAP_EXP+10.w` 置 bit4 再清掉，NPU 立刻整机复位并从 BL1 重新启动，
串口日志完整。这条比 MCP2210 hold/release 省事，而且不需要额外工具。

### 9.3.7 对照开源实现 openwrt-sophos-xgs107（同一颗 SoC，很有参考价值）

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
| 端点消失会让主机自己重启（链路耦合） | 已知，见 [docs/16](16-remaining-work.md) |

他们没提到的一点、但这次真正卡住我们的是 **§9.3.5 的缓存身份问题** —— 他们大概
每次装完都是整机冷启动，主机枚举时端点已经 armed，所以撞不上。

## 9.4 自愈与手动恢复（历史漏洞 + 现在的安全策略）

### 9.4.1 漏洞一：watcher 只看 `carrier`

主机侧读到的 `carrier` 仍然是 1，而 NPU 那侧已经把链路丢了 —— 两边状态不一致，
`carrier` 恒为 1，watcher 永远不动手。

→ 现在同时检查 `carrier` 和**实际可达性**（ping `10.234.56.1`）。

### 9.4.2 漏洞二：`ntb_epf_spad_write()` 会在端点上写野指针（**这才是主因**）

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

### 9.4.3 漏洞三（顺带）：只 `remove`+`rescan` 不够

NPU 重启后它自己重新编程了 BAR 尺寸寄存器和 inbound iATU，旧的 BAR 地址全指向空气。
所以"完整恢复"要按下面这个顺序，**而且只能在确认 NPU 已经起来、不在启动窗口时做**：

```
down eth0.200 / eth0.100 / eth0
rmmod ntb_netdev → ntb_transport → ntb_hw_epf     （顺序反了就等于把设备从活着的驱动脚下抽走）
echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove
echo 1 > /sys/bus/pci/rescan                       （让主机重新读 BAR 尺寸并重新分配）
xgs-ntb-up.sh                                      （握手、重建 VLAN、补地址）
```

现在**不会自动跑这段**（rmmod 那一步在端点失联时会把 x86 带崩）。可用的入口只有两个：

- `xgs-ntb-up.sh --force-rescan`：只做一次 remove/rescan，不 rmmod；NPU 已经起来时够用，
  也是 `xgs-ntb-watch` 在 `AUTO_RECOVER=1`（镜像默认）下等满 5 分钟后自动调的那一条；
- 上面的完整重置：手动做，失败就断电重启 x86/NPU，不要把 rmmod 写成循环或自动服务。

> 教训：**别在 x86 上手工 `rmmod ntb_hw_epf`** —— 在端点已经失联时，那一步会把整机带崩。
> 关机钩子（`xgs-ntb-stop.service`）里的顺序是安全的。
