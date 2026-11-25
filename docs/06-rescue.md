# 06 救砖

按"前提最容易满足"往下退，**能停在哪一级就停在哪一级**。

| 级 | 前提 | 做法 | 耗时 |
|---|---|---|---|
| 1 | NPU 用户态还活着（sshd 或串口 shell） | x86 上 `npu-sshdd.sh`（ssh + dd 写 p2） | 1–2 分钟 |
| 2 | **只剩 U-Boot**，PC 手里有整盘镜像，x86 能敲字 | **串口推 15.9 MB → RAM 急救系统 → 面板口 1 Gb/s 喂整盘** | ~30 分钟 |
| 3 | U-Boot 也没了（SPI NOR 里的 BL31/U-Boot 坏了） | x86 上的 MCP2210 直接写 SPI NOR | 十几分钟 |

**U 盘只能救 x86。** NPU 的 xHCI 在 DT 里是关的、面板上也没有 USB 口，U-Boot 的
`usb start` 只枚举到 root hub —— 所以"拿 U 盘救 NPU"这条路不存在，U 盘走到头之后接着走第 2 级。

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

### 第 3 步：三样东西推进 RAM（约 27 分钟）

```sh
# PC 上；每个文件都会核对 U-Boot 打的 "## Total Size"
python installer/payload/ymodem-com.py COM5 send 0x06f00000 xgs87.dtb      #   21 KB, 几秒
python installer/payload/ymodem-com.py COM5 send 0x0A000000 initramfs.gz   #  2.2 MB, 约 4 分钟
python installer/payload/ymodem-com.py COM5 cmd  'unzip 0x0A000000 0x20000000'
python installer/payload/ymodem-com.py COM5 send 0x02000000 Image.gz       # 13.7 MB, 约 23 分钟
python installer/payload/ymodem-com.py COM5 cmd  'unzip 0x02000000 0x07000000'
```

地址**必须写死**（factory env 里没有 `loadaddr`；initramfs 也不能原地解压）：

| 用途 | 地址 | 大小 |
|---|---|---|
| DTB | `0x06F00000` | 21 KB |
| Image.gz（临时落脚） | `0x02000000` | 13.7 MB |
| Image 解压后 | `0x07000000` | 37.7 MB |
| initramfs.gz | `0x0A000000` | 2.2 MB |
| initramfs 解压后 | `0x20000000` | 3.4 MB |

### 第 4 步：起急救系统，让它自己写 p2

```sh
python installer/payload/ymodem-com.py COM5 cmd 'setenv rd_size 0x341a00'   # 上一步 filesize 的字面值
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
| x86 的 console 彻底哑掉 | 透传进程在写方向死等（NPU panic 后不再读串口）。`relay.py` 现在两个方向都封 5 s、超时丢字节，信号也恢复 tty；真卡死就 serial SysRq：`send_break()` 后写 `b` |
| NPU 的 console 一片安静、`cat /dev/ttyS2` 没反应 | 有没有别的读者；或者 NPU 停在 panic。上面第 1 步的 SBR 复位能把它弄回 U-Boot |

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
