# 06 救砖

按"前提最容易满足"往下退，**能停在哪一级就停在哪一级**。

| 级 | 前提 | 做法 | 耗时 |
|---|---|---|---|
| 1 | NPU 用户态还活着（sshd 或串口 shell） | x86 上 `npu-sshdd.sh`（ssh + dd 写 p2） | 1–2 分钟 |
| 2 | **只剩 U-Boot**，手里有整盘镜像，能连面板口 | **串口推 3.1 MB → RAM 急救系统 → 面板口 1 Gb/s 喂整盘** | ~10 分钟 |
| 3 | U-Boot 也没了（SPI NOR 里的 BL31/U-Boot 坏了） | x86 上的 MCP2210 直接写 SPI NOR | 十几分钟 |

**U 盘对 NPU 到底能做什么**（2026-11-25 在真机上逐条核对过）：

| NPU 的状态 | 从 U 盘启动的 x86 能做的事 | 还需要什么 |
|---|---|---|
| 用户态活着（sshd 在） | `npu-sshdd.sh` 走 vNTB 整盘重写 p2 —— 实测 1.6 GiB / 45 秒 | 无 |
| 只剩 U-Boot（第 2 级） | 经 x86 的 `/dev/ttyS2` 直接敲 U-Boot、用 YMODEM 推急救内核，全程不需要另一个人敲串口 | **一台能接面板口的机器**：x86 自己**没有网口**（`lspci` 里一个 Ethernet 控制器都没有，`eth0` 是 vNTB 虚拟网卡），所以镜像得由另一台机器（或 x86 上插 USB 网卡）提供 |
| U-Boot 也没了（第 3 级） | x86 上的 MCP2210 直接写 SPI NOR | 无 |

NPU 自己的 USB：两个 xHCI 在 DT 里是 `disabled`，面板上也没有确认过的 USB 口，
所以"把 U 盘插到 NPU 上"这条路不存在。

## 第 1 级：ssh + dd

```sh
SRC=/mnt/usb/p2.img NPU=10.234.56.1 sh installer/payload/npu-sshdd.sh
```

脚本会先读 NPU 的 `findmnt -n -o SOURCE /`：**目标分区如果正是 NPU 当前的根，直接拒绝**
（活着的根上 `dd` 会写成碎片，2026-11-25 事故就是这么来的）。安全用法是让 NPU 从
p3 原厂或急救 initramfs 起来，那时根不是 p2，脚本自动放行。

## 第 2 级：最后手段（串口急救 + 面板口）

2026-11-25 深夜用这一套把一台 p2 被写坏的机器救回来：写进去 1.6 GB，回读 sha256 与源文件
**逐字节一致**，NPU 正常起 Debian，p1/p3 全程没动。

### 拓扑

```
PC  ──USB 串口 COM5──→  x86 控制台 /dev/ttyS0
PC  ──网口──────────→  NPU 面板口 p1（1 Gb/s，走 DSA）
x86 /dev/ttyS2 ─────→  NPU 的 UART（TF-A / U-Boot / Linux，115200）
```

x86 自己**没有任何物理网口**（`ip -br a` 只有 `lo`），它在这条路上只干一件事：
把 PC 的 COM5 变成 NPU 的 UART。

### 第 0 步：准备

```sh
# PC：把整盘镜像放出去（PC 要插在 NPU 面板口上，用 10.234.56.10/24）
python -m http.server 8080 --bind 10.234.56.10 --directory <放 p2.img 的目录>
sha256sum p2.img                       # 记下来，最后拿它对数

# x86：确认能无密码 sudo（relay 要 root 才能开 /dev/ttyS2）
sudo -n true && echo ok
```

### 第 1 步：把 NPU 弄回 U-Boot（不用进机房）

```sh
# x86 —— 先停掉会自己 rescan 的 watcher，免得跟这次复位打架
sudo -n systemctl stop xgs-ntb-watch.service xgs-ntb.service
sudo -n setpci -s 00:03.1 BRIDGE_CONTROL=40:40; sleep 1
sudo -n setpci -s 00:03.1 BRIDGE_CONTROL=00:40; sleep 3
sudo -n sh -c 'echo 1 > /sys/bus/pci/rescan'
# 几秒后 NPU 打 TF-A/U-Boot 出来，p2 空/坏时会自己落到：
#   Bad Linux ARM64 Image magic!
#   Marvell>>
sudo -n sh -c 'printf "\r" > /dev/ttyS2; timeout 25 cat /dev/ttyS2'
```

`00:03.1` 是那个端点的上游 root port（`lspci -tv` 里 `03.1-[03]----00.0`）。
只 `echo 1 > .../remove` + `rescan` **不够**，实测复位不了 NPU。

### 第 2 步：把 x86 变成 NPU 的串口线

```sh
# x86：前台跑，打印 RELAY-READY；PC 发 \x18\x18XGS87QUIT\r 退出（会恢复 tty）
sudo -n python3 installer/payload/relay.py /dev/ttyS2
```

跑起来后 PC 的 COM5 就等于直接插在 NPU 的 U-Boot 上。**不要**走"先传给 x86、再由 x86
推给 NPU"：同一条 115200 要走两遍（21.5 MB 的 base64 光第一遍就 31 分钟，这次事故里白扔过）。

### 第 3 步：三样东西推进 RAM（约 3.6 分钟）

```sh
# PC 上；每个文件都会核对 U-Boot 打的 "## Total Size"
python installer/payload/ymodem-com.py COM5 send 0x06f00000 xgs87.dtb      #    21 KB, 几秒
python installer/payload/ymodem-com.py COM5 send 0x0A000000 initramfs.xz   #   469 KB, 约 50 秒
python installer/payload/ymodem-com.py COM5 send 0x02000000 Image.lzma     #  1.63 MB, 约 2.8 分钟
python installer/payload/ymodem-com.py COM5 cmd  'lzmadec 0x02000000 0x07000000'
```

⚠ **`unzip` 只认 gzip**。这台固件（U-Boot 2019.10-10.22.03）的 `unzip` 里
`file_formats[]` 只有 gzip，喂 lzma 进去只会得到 `Error: Bad gzipped data`；
lzma 要用它自带的 `lzmadec <src> <dst>`（2026-11-26 真机验过）。
`initramfs.xz` **不用解**：内核有 `CONFIG_RD_XZ`，`booti` 直接给压缩后的大小。

（`Image.lzma`/`initramfs.xz` 是 `build-rescue.sh` 从自编精简内核打出来的那一版，整包
2.1 MB；换成 Debian 内核那一版大概是 10.9 MB，时间翻五倍。）

地址**必须写死**（factory env 里没有 `loadaddr`）：

| 用途 | 地址 | 大小 |
|---|---|---|
| DTB | `0x06F00000` | 21 KB |
| Image.lzma（临时落脚） | `0x02000000` | 1.63 MB |
| Image 解压后 | `0x07000000` | 5.4 MB |
| initramfs.xz（**压缩态**直接用） | `0x0A000000` | 469 KB |

### 第 4 步：起急救系统，让它自己写 p2

```sh
python installer/payload/ymodem-com.py COM5 cmd 'setenv rd_size 0x729e8'    # initramfs.xz 的 filesize 字面值
python installer/payload/ymodem-com.py COM5 cmd "setenv bootargs 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 rescue.url=http://10.234.56.10:8080/p2.img rescue.part=/dev/mmcblk0p2 rescue.ip=10.234.56.11/24 rescue.sha256=<p2.img 的 sha256>'"
python installer/payload/ymodem-com.py COM5 cmd 'booti 0x07000000 0x20000000:0x341a00 0x06f00000'
```

串口上应该依次看到（`installer/payload/rescue-init` 打的）：

```
rescue: 载入 eMMC 驱动（Xenon）
rescue: 块设备: /dev/mmcblk0 /dev/mmcblk0p1 p2 p3 p4
rescue: 网络设备: eth0 lo p1 p2 … sfp
rescue: wget rc=0 dd rc=0
rescue: p2 sha256 <…> / 期望 <…>
rescue: 写完了，重启
```

任何一步不对，init 会**落到一个 shell 里**（不是死机），可以在里面手动重来：
`ifconfig p1 …`、`wget -O - … | dd of=/dev/mmcblk0p2`、`dmesg` 都在。

### 急救系统的开关（都是内核 cmdline 参数）

| 参数 | 默认 | 干什么 |
|---|---|---|
| `rescue.url` / `rescue.url2` | `http://10.234.56.10:8080/p2.img` | 从哪拉整盘镜像；第一个失败换第二个 |
| `rescue.part` | `/dev/mmcblk0p2` | 写到哪个块设备 |
| `rescue.ip` | `10.234.56.11/24` | 给面板口配的地址 |
| `rescue.dev` | `p1` | 用哪个面板口。`p2` 是 WAN 口，线通常直接通家里交换机，所以"镜像放在局域网某台机器上"时用 `rescue.dev=p2` |
| `rescue.sha256` | 空 | 写完回读校验，不符就不重启 |
| `rescue.mode` | `write` | `probe` = 只验网络通不通，一个字节都不写盘 |
| `rescue.ping` | 空 | probe 模式下顺带 ping 一个地址 |
| `rescue.auto` | 空 | `reboot` = 无人值守，结束时（含失败）自己重启 |
| `rescue.log` | 空 | `<dev>:<4K块>`，把整份日志写到那块空闲区 |
| `rescue.oneshot` | 空 | `<dev>:<4K块>`，进 /init 就先清掉那个扇区（见下） |

### 没有控制台时怎么拿日志、怎么重启

这台机器的 UART 只接到 x86 的 `ttyS2` 上，x86 自己又是"没有网口、得靠 NPU 才有网"的
—— 一旦 NPU 起不来，**串口和网络会同时消失**，等于瞎了。2026-11-25 就是在这种条件下
把精简内核调通的，靠的就是下面两条：

| 需求 | 做法 |
|---|---|
| 看日志 | `rescue.log=/dev/mmcblk0p1:127000` —— 日志写到 p1 尾部 4 MB（p1 是原厂分区，有备份，本系统不用）。重启后从正常系统 `dd if=/dev/mmcblk0p1 bs=4096 skip=127000 count=8` |
| 确认"用户态到底跑没跑" | `rescue.oneshot=/dev/mmcblk0p2:<DTB 的起始块>`（`filefrag -v /boot/xtest/xgs87.dtb` 第 4 行的第 2 个字段）。/init 一执行就清掉 DTB 头 → U-Boot 的 `booti` 必然失败 → 回落到正常系统，**永远不会卡在试验内核里**；而那一块是不是 0，在正常系统里 `dd | od` 一看就知道。**别指向 `Image.lzma`**：那等于让 `lzmadec` 去解一段坏流（2026-11-26 踩过） |
| 重启 | `hard_reboot()`：优先 `echo b > /proc/sysrq-trigger`（`emergency_restart()`，不碰驱动），退回 `reboot -f` |

### 第 5 步：收尾

1. NPU 自己从 p2 起 Debian（`xgs-debian-npu login:`）；
2. x86 上 `sudo -n systemctl enable --now xgs-ntb xgs-ntb-watch`；
3. **vNTB 不会自己回来** → 重启一次 x86（[05](05-operations.md)）。

### 会把人坑死的八个现象（全部实测）

| 现象 | 原因 / 解法 |
|---|---|
| `unzip` 报 `Bad gzipped data`、`md.b` 读到全 0 | 上一次 `loady` 超时退出后串口里还留着 `'C'`，发送端一看到旧 `'C'` 就发文件头 → 数据落到**上一次的地址**。发送端必须等 `download to 0x…` 并核对地址（`ymodem-com.py` / `ymodem.py` 现在都这么做） |
| 内核一个字符都不打就死 | `booti …:${rd_size}` 的 `${…}` 被别处展开成空值 → initrd 落到 `0x80000000`（DRAM 之外）。**写死大小** |
| `Kernel panic - No working init found`，日志里没有 `Run /init` | initramfs 少了 `/bin/sh` 符号链接（`/init` 第一行是 `#!/bin/sh`） |
| `/dev/mmcblk*` 不存在 | eMMC 归 **`sdhci-xenon-driver`**（驱动名 `xenon-sdhci`）。`sdhci-of-dwcmshc` 只认 `snps,dwcmshc-sdhci`，加载"成功"但永不 bind（`Error: No device match data found`）；还不出就手动 `echo f06e0000.mmc > /sys/bus/platform/drivers/xenon-sdhci/bind` |
| 只有 `eth0`（CPU 口），没有 `p1` | 模块顺序：MDIO 那层（`mdio/acpi_mdio/fwnode_mdio/of_mdio/phylink`）必须**先于** `mvmdio`；`bridge` 要 `llc`+`stp`；`dsa_core` 要 `selftests`+`hsr` |
| `ip addr add` 被拒 | 急救 shell 的 busybox 不认，用 `ifconfig p1 10.234.56.11/24 up`。**不需要建桥**：DSA 的用户口 p1 是独立网口 |
| **地址配上了、`ping` 却报 `Network is unreachable`** | `ip addr add` 成功返回时接口还是 **DOWN** —— 那个 `ifconfig … up` 的兜底根本不会执行，`/sys/class/net/p2/carrier` 也读不出来（空值）。必须再 `ip link set $DEV up`，然后等 carrier=1（2026-11-25 实测踩过） |
| **写完了却永远不重启，ICMP 还通** | `reboot -f` 会走 `device_shutdown()`，面板口 link 起来之后 mvpp2/DSA 的 shutdown 会卡住。用 `echo b > /proc/sysrq-trigger`（`CONFIG_MAGIC_SYSRQ`）|
| x86 的 console 彻底哑掉 | 透传进程在写方向死等（NPU panic 后不再读串口）。`relay.py` 现在两个方向都封 5 s、超时丢字节，信号也恢复 tty；真卡死就 serial SysRq：`send_break()` 后写 `b` |
| NPU 的 console 一片安静、`cat /dev/ttyS2` 没反应 | 有没有别的读者；或者 NPU 停在 panic。上面第 1 步的 SBR 复位能把它弄回 U-Boot |

## 出厂数据备份（做一次，之后一直有用）

机器上真正**不可再生**的只有四样：`p1`（原厂 Marvell rootfs）、`p3`（原厂 Sophos 系统）、
`p4`（VPD：序列号 + MAC）、SPI NOR 整片（TF-A + U-Boot + env）。其余都能从仓库重建。

```sh
# 在 PC 上直接拉（NPU 的 br-wan 在家里 LAN 上，1 Gb/s）：
#   sudo dd if=/dev/mmcblk0pN bs=1M | ssh 传回来，或在本机 dd 到文件后 zstd
# 四个分区的字节数和 sha256 记在 MANIFEST.txt 里，两边对过才算数
```

- 现成的归档：`xgs87-factory-2026-11-26.tar.zst`（2.23 GB → **390 MB**，sha256
  `39f7036b…ef869`），放在**本机/私有位置**。
- 公开的 GitHub release `factory-backup` 里只有 `MANIFEST.txt` 和
  `uboot-env.redacted.txt`（env 的 MAC 和 partno 已打码）。**原厂镜像和 VPD 不上去**：
  p1/p3 是厂商代码，p4 和 NOR 里有这台设备的身份 —— 要放云端就开**私有**仓库。
- 恢复：把镜像 `dd` 回对应分区即可（写的时候那个分区不能挂载；p1/p3/p4 平时就不挂载，
  所以从急救系统里写最稳）。



## 第 3 级：MCP2210 写 SPI NOR

只有当**串口连 TF-A 的 `NOTICE:` 都没有**（SPI NOR 里的 BL31/U-Boot 坏了）才用这一级。

- 硬件：MCP2210（USB→SPI）夹子接在那颗 **mx25l3205d（4 MiB）** 上，x86 上跑
  `tools/on-x86/mcp2210-nor.py`。不用拆芯片。
- **先 hold 住 SoC 再碰 SPI**：两个 master 同时驱动会读到垃圾、甚至写坏。
  工具里的 `hold` 子命令就是干这个的（GPIO 拉低复位，器件进 reset 后 SPI 才归我们）。
- 安全模型是**代码强制**的：只允许白名单里的偏移/长度（BL31、U-Boot、env），写完回读校验。
  整片备份：`mcp2210-nor.py backup out/nor-backup.bin`。
- 组件表（哪个偏移是什么）以工具里的表为准，不要凭记忆写。
- 写完至少要能看到 TF-A 的 `NOTICE:` 才算活过来；然后回到第 1/2 级继续装系统。
