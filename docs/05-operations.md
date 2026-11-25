# 05 运维

## 账号 / 地址

| | 值 |
|---|---|
| 两个系统 | `admin` / `P@ssw0rd`（`sudo` 要密码，root 默认锁着） |
| p3 原厂 | `root` / `openwrt123` |
| NPU LAN | `10.234.56.1/24`（`br-lan`，VLAN 200） |
| x86 LAN | `10.234.56.2/24`（`eth0.200`） |
| NPU 控制台 | x86 的 `/dev/ttyS2`，**115200** |
| x86 控制台 | PC 的 COM5 → x86 `/dev/ttyS0`，115200 |

## 服务清单

装的是这些，`systemctl --failed` 必须是空的。

**两边都装**（`systemd/common/`）：`xgs87-growroot`（首次开机扩根，成功后留
`/var/lib/xgs87/grown`）。

**x86**（`systemd/x86/`）

| unit | 干什么 |
|---|---|
| `xgs-ntb` | 装 `ntb_hw_epf` + `ntb_transport`，等 `eth0` 出现交给 networkd |
| `xgs-ntb-watch` | 只**看**链路状态；`AUTO_RECOVER=1` 时每 10 分钟最多动一次手：先 `--force-rescan`（ID 被缓存的情形），仍无端点再 `--retrain`（toggle 根端口的 Link Disable，让 LTSSM 重新训练）。循环 rescan 会把 NPU 复位，所以次数是封顶的 |

**NPU**（`systemd/npu/`，脚本都在 `/usr/local/sbin/`）

| unit | 干什么 |
|---|---|
| `xgs-vntb` | configfs 建 `pci_epf_vntb`（`1957:0809`）→ 启 EPC → 装 `ntb_transport`+`ntb_netdev` |
| `xgs-ports-up` | 等 DSA 建出面板口 → 推 MAC（`ethaddr` +0..+5）→ `up` 让 PHY 协商 |
| `xgs-net-up` | 按 `/etc/xgs87/net.conf` 把口分进 `br-wan`(`p2`)/`br-lan`(`p1`)，两条 VLAN |
| `xgs-dhcp` | 只在 `net.conf` 里标了 `dhcp` 的桥上跑 `dhcpcd`（默认只有 `br-wan`） |
| `xgs-nat` | LAN → WAN 转发 + masquerade |
| `xgs-netconsole` | 把内核 console 推给 x86 和 PC（崩了取证用） |

## 控制台

```sh
# x86 上开 NPU 串口（同一时刻只能有一个读者！）
. installer/payload/serial.sh                # serial_open 会登录，也负责清 RTS
timeout 5 cat /dev/ttyS2                     # 只看（读不需要任何准备）

# 不带交互地敲 U-Boot / shell 命令
. installer/payload/serial.sh                # serial_run / serial_uboot / serial_read_until
```

⚠️ **要往 NPU 写，必须先把这个串口的 RTS 拉低**（2026-11-25 实测）。这块板子的
UART 收发器拿 RTS 当方向控制：RTS 高的时候 x86 的 TX 是关着的 —— **读得到、一个
字节都写不进去**，而且不会报错，看起来就像线只接了单向。把 RTS 清掉立刻就通
（NPU 上一个 `echo X > /dev/ttyS0`、x86 上 `cat /dev/ttyS2`，25 行一字不差；
反过来清 RTS 之后 getty 也马上回 `login:`）。

`stty` 表达不了 RTS 引脚，所以：

- `serial.sh` 的 `serial_open` 打开端口后会 ioctl 清一次 RTS（`TIOCMBIC`,
  `TIOCM_RTS`=0x004），之后所有读写都走同一个常开的 fd 3；
- `ymodem.py`（串口推文件）和 `relay.py`（把 COM5 变成 NPU 的串口）打开端口后
  也各清一次；
- **别用 `printf ... > /dev/ttyS2`**：每次重定向都是一次新的 `open`，内核在 open 时
  会把 DTR+RTS 重新拉高，于是这一条命令又写不动了。`npu-uboot.sh` 里所有写操作
  因此改成写同一个常开 fd（`>&4`）；
- `picocom` 之类的交互终端同理：进去了先确认 RTS 状态，否则只有收、发不出去。

## ssh（装完就能用，不需要先交换钥匙）

镜像里不带任何私钥，只有 `admin` / `P@ssw0rd` 和 `PasswordAuthentication yes`，再加一份
客户端配置 `image/overlay/common/etc/ssh/ssh_config.d/10-xgs87.conf`：

- `StrictHostKeyChecking accept-new` —— 第一次连不问 yes/no；
- `ControlMaster` + `ControlPersist 12h` —— **密码只输一次**，之后的 `ssh`/`scp`/脚本里的
  `BatchMode` 全部复用那条连接，12 小时内不再问。

```sh
ssh admin@10.234.56.1            # 第一次输一次密码
ssh admin@10.234.56.1 'uptime'   # 复用同一条连接，不再问
```

想彻底免密（给 cron/脚本用，或者不留 master 连接），上来做一次就行：

```sh
ssh-copy-id admin@10.234.56.1   # 从 x86 到 NPU
ssh-copy-id admin@10.234.56.2   # 从 NPU 到 x86
```

脚本要跨机器时别依赖钥匙：`installer/payload/lib.sh` 的 `npu_ssh`（`SSH_ASKPASS` 拿密码，
`npu-sshdd.sh` 同一套）在新装的系统上就成立。

## 控制台的坑

- **两个读者会把串口字节流切成乱码**。看到乱码先 `pgrep -af ttyS2`。
- **写不动先看 RTS**（见上）：RTS 高 = TX 关着，读得到写不进去。`printf > /dev/ttyS2`
  这种"每次 open"的写法一定会踩到，用 `serial.sh` 或常开 fd。
- 登录要状态机，不能靠固定 `sleep`：等 `login:` 发用户名、等 `Password:` 发密码。
  getty 只在收到输入时才重打 `login:`，所以探测前要先敲一个回车。
- 115200 是硬上限，别想提速（见 [01](01-hardware.md)）。
- PC 想直接接到 NPU 的 UART 上：x86 上跑 `installer/payload/relay.py`（见 [06](06-rescue.md)）。

## 开机自检

```sh
systemctl --failed --no-legend                     # 必须空
ip -br a                                           # x86: eth0 + eth0.100 + eth0.200
df -h /                                            # x86 ~15 GB；NPU 1524 MiB
sudo dmesg | grep -iE 'EXT4-fs error|I/O error'    # 必须空
ssh admin@10.234.56.1 'uptime'                     # x86 → NPU 那一跳
```

`xgs-ntb` 正常时是 `active (exited)`（`RemainAfterExit=yes`），不是 `running`。

## 已知故障 → 怎么办

| 现象 | 原因 / 处理 |
|---|---|
| x86 上 `eth0` 不存在，dmesg 刷 `endpoint unreachable, dropping doorbell` | BIOS 没在 POST 枚举到 endpoint。**重启一次 x86**（NPU 保持开机）。刷屏会冲掉串口控制台，先 `dmesg -n 1` |
| 上电后 x86 完全没网 | 看 `lspci -nn \| grep 1957` —— **分三种，处理完全不同**：<br>① 有 `1957:0809`、`/sys/bus/ntb/devices/*` 也在、就是没有 `eth0` → 端点已枚举且 bind，只是 `ntb_transport`/`ntb_netdev` 没起来（开机时 `xgs-ntb` 等不到设备先失败退出了）。重跑 `xgs-ntb-up.sh`（**不碰 PCIe**，可以反复试；watcher 现在自动做这件事）<br>② 什么都没有，NPU 侧 `cat /sys/class/net/eth0/carrier` 是 0 → **链路没 train**（BIOS 扫总线时 NPU 端点还没武装，NPU 从上电到 vNTB 就绪要 ~12 秒），`rescan` 找不到"电上不存在的功能"：在 **host** 上 `xgs-ntb-up.sh --retrain`（toggle 根端口 Link Disable）<br>③ 有设备但 ID 是 `11ab:7080` → 枚举时读到的还是固件出厂身份，被内核缓存了：`xgs-ntb-up.sh --force-rescan` |
| 现在这套是怎么自愈的 | 见下面「vNTB 自愈」一节。`xgs-ntb-watch`（x86）和 `xgs-vntb-watch`（NPU）各自盯着自己这一端，按代价从低到高的梯子自动恢复，不需要人工介入 |
| NPU 重启/重装后 vNTB 回不来 | 以前要重启 x86，现在 `xgs-ntb-watch` 会自己重枚举端点（见下节）。手动救急仍是 `xgs-ntb-up.sh --force-rescan` |
| `bootcmd_emmc3` 起 p3 → `No working init found` | p3 是只读的原厂系统，没有可用 init。别用这个 bootcmd |
| U-Boot 里 `ping`/`tftpboot` 不动 | 已知：U-Boot 的网络完全不通（ARP 都收不到）。只能走串口/急救 |
| `/dev/mmcblk0` 不存在（急救系统里） | eMMC 归 `sdhci-xenon-driver`（`xenon-sdhci`），不是 `sdhci-of-dwcmshc`。见 [06](06-rescue.md) |
| NPU 上没有 `p1..p8`，只有 `eth0` | DSA 模块没起来：MDIO 那层必须先于 `mvmdio`；`bridge` 要 `llc`+`stp`；`dsa_core` 要 `selftests`+`hsr` |
| 串口一片安静，`cat /dev/ttyS2` 什么都不给 | 有没有别的读者占着；NPU 是不是真的在跑（看 `xgs-ntb` 的 journal） |
| `ssh` 报 `Host key verification failed` | 换过系统，`known_hosts` 里的旧指纹还在：删掉那一行 |

## vNTB 自愈

两端各有一个常驻监视器，各自只修自己那一端（对端的状态只能观察，不能替它改）：

| 在哪 | 单元 | 脚本 | 干什么 |
|---|---|---|---|
| x86 | `xgs-ntb-watch.service` | `/usr/local/sbin/xgs-ntb-watch.sh` | 认状态，按梯子恢复本机的 PCIe / 协议栈 / 地址 |
| NPU | `xgs-vntb-watch.service` | `/usr/local/sbin/xgs-vntb-watch.sh` | 端点没武装或没 carrier 时软重新武装（系统内无法复位控制器，见下） |

x86 侧每 `INTERVAL` 秒一拍，状态和动作：

| 状态 | 判据 | 动作 |
|---|---|---|
| `up` | `ntb_netdev` 在、`carrier=1`、ping 得通对端 | 什么都不做 |
| `peer-down` | `carrier=1` 但对端 `PING_CD` 秒不答 | **remove + rescan 重枚举** |
| `unbound` | 端点在总线上、没有驱动 | 后台重试 `.../ntb_hw_epf/bind`；挂了 `REENUM_AFTER` 秒就重枚举 |
| `no-netdev` | 端点已 bind、没有 ntb netdev | 重跑 `xgs-ntb-up.sh`；`STACK_AFTER` 秒没好就重装协议栈 |
| `no-carrier` | 接口在、`carrier` 不是 1 | 同上 |
| `no-device` | 总线上没有端点 | plain rescan；连续 `RETRAIN_AFTER` 次都没有就 toggle Link Disable 重训链路 |

调参在 `/etc/default/xgs-ntb-watch`（全部留空就用脚本默认值）。

### 为什么"重枚举"是必不可少的一档

2026-11-25 实测。对端重启之后，端点那边的 BAR 分配被硬件清掉了，而 x86 这边的
`pci_dev` 还记着老地址（`fc000000` / `fc100000` / `fc200000`）。`ntb_hw_epf` 的 probe
去配门铃，写到已经不存在的地址上，超时退出：

```
ntb_hw_epf 0000:03:00.0: Failed to configure doorbell
ntb_hw_epf 0000:03:00.0: Failed to init ISR
ntb_hw_epf 0000:03:00.0: probe with driver ntb_hw_epf failed with error -110
ntb_hw_epf 0000:03:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x000b ...]
```

关键在于 **probe 失败之后内核不会重试**：函数就那样挂在总线上 —— `lspci` 正常、
三个 BAR 都分配好了、`LnkSta` 还是 8GT/s ×2，看着完全没事，但永远不会有 `eth0`。
重装协议栈也救不回来（连试两次都是 -110）。只有 `remove` + `rescan`，让内核重新读
一遍 config space、把 BAR 重新写下去，端点才会重新认这些地址；之后 dmesg 立刻出现

```
ntb_hw_epf 0000:03:00.0: NTB Transport QP 0 created
ntb_hw_epf 0000:03:00.0: qp 0: Link Up
```

实测 remove+rescan **不会**复位 NPU（操作前后 NPU 的 uptime 连续）。

probe 在端点不响应时会在内核里卡几十秒，所以 `bind` 和 `remove` 都放后台跑，
监视线程不会跟着卡住。

### NPU 侧：能做什么、不能做什么

`xgs-vntb-watch` 发现端点没武装或没 carrier 时会重新武装：卸掉 `ntb_netdev`/
`ntb_transport`，重跑 `xgs-vntb.sh`（重建 configfs function + `start=1`），再补
接口和地址。连续 `WARN_AFTER` 次（默认 3）都救不回来，它就停止折腾，只把结论写进
journal。

**系统内没有"复位端点控制器"这条路**，2026-11-25 实测两次：

- `dw-pcie` 这个 platform 驱动设了 `suppress_bind_attrs`，
  `/sys/bus/platform/drivers/dw-pcie/` 下面根本没有 `bind`/`unbind`；
- `modprobe -r pcie_dw_plat` 直接失败；失败之后整台 NPU 卡住（sshd 能建 TCP 但
  不发 banner、串口没输出），只有断电/复位才能恢复。

所以下面两种状态只能重启 NPU —— 或者重启 x86，它的 PERST# 会把 NPU 一起复位：

1. 对端拉过 PERST#，硬件把端点清回出厂状态，而 configfs 里 `start` 还是 1；
2. 上一次 `pci_epf_vntb` probe 失败，控制器仍记着 BAR 被占用，之后每次 probe 都是
   `Doorbell BAR set failed` → `Failed to initialize EPC`。

推论：**不要**在没有把握复位的情况下把 EPC 停掉（`echo 0 > start` 或者摘掉
`func1`）—— 端点会停在半武装状态，链路直接死，而且软路径再也救不回来。

## 还没做的

- 面板 LED 极性、`p5`–`p8` 的用途没验过。
- `br-wan` 的上游 DHCP 只在插了面板 2/WAN 时成立，没插时是 IPv4LL，两台都没有默认路由。
- x86 侧没有温度/风扇监控单元。
