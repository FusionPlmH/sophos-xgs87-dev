# 06 · x86 系统（Debian 13）

> 🏷 **状态（2026-11-23 复核）**：✅ **实测**：分区、EFI、串口、MCP2210 均在现机上复核；`/dev/ttyS2` 的波特率坑见 [10](10-console.md)。

## 6.1 现状

| 项目 | 值 |
|---|---|
| 发行版 | Debian GNU/Linux 13.8 (trixie)，内核 **6.12.117+deb13-amd64**，被 `apt-mark hold`（发布用的 `lean` 镜像不带 dkms；模块是构建时 `make` 编好放进 `/lib/modules/*/updates/` 的 `.ko.xz`） |
| 固件 | AMI UEFI BIOS 1906，**UEFI + GPT**（shim + grub） |
| CPU | AMD RX-216TD，2 核 |
| 内存 | 2×2 GB DDR4-1600（可见 3.8 GiB） |
| 系统盘 | 16 GB eMMC（`mmcblk0`） |
| 网络接口 | 硬件上**没有任何以太网设备**；现在唯一的 netdev 是 PCIe 上的 `eth0`（vNTB），上面套了两个 VLAN |
| 控制台 | `console=ttyS0,115200n8` |

### 分区（GPT）

```
NAME          SIZE TYPE FSTYPE MOUNTPOINT MODEL
mmcblk0      14.7G disk
├─mmcblk0p1   128M part vfat   /boot/efi   (镜像里的 ESP；装到 eMMC 后仍是 128 MiB)
└─mmcblk0p2  14.2G part ext4   /
mmcblk0boot0    4M disk          (eMMC 硬件分区)
mmcblk0boot1    4M disk
```

`/etc/fstab` 用 UUID 挂载（`UUID=… / ext4` + `UUID=… /boot/efi vfat`），换盘/重装时注意。

## 6.2 为什么没有网口，以及现在怎么上网

x86 侧完全没有 MAC/PHY：

- `lspci` 里只有 AMD 的 FCH 设备 + `03:00.0` 的 NPU 端点，**没有任何 Ethernet controller**。
- 原厂靠 Sophos 专有驱动把 NPU 的面板口"搬"到 x86 上（`Port1…Port4` + `PortF1`），
  这些驱动只支持 4.14。

**现在的实际网络（实测 `ip -br a`）**：

```
lo               UNKNOWN  127.0.0.1/8
eth0             UP       (无地址)                 ← vNTB，PCIe 上的虚拟网线
eth0.100@eth0    UP       DHCP                     ← WAN / 管理，经 NPU 的 p2 到上游
eth0.200@eth0    UP       10.234.56.2/24           ← LAN，经 NPU 的 p1 到下游（NPU 是 .1）
```

- 这条虚拟网线两侧**只有 x86 和 NPU**，所以想上真正的内网必须让 NPU 把面板口桥进来
  （现在是 `p2` 走 WAN、`p1` 走 LAN）。详见 [09](09-vntb.md)。
- 需要的模块都在 `/lib/modules/$(uname -r)/updates/`（`make modules_install` 放那儿，压成 `.ko.xz`）：`ntb_core` / `ntb_hw_epf` /
  `ntb_transport` / `ntb_netdev`（Debian 不自带 NTB 栈，见 [tools/build](../tools/build/)）。
- 装机脚本在 [systemd/x86/](../systemd/x86/)，安装步骤见 [docs/11-operations.md](../docs/11-operations.md)。

## 6.3 关键外设

### PCIe 上的 NPU 端点

**原厂状态（`11ab:7080`，SR-IOV 6 个 VF，历史档案）**：

```
03:00.0 Ethernet controller [0200]: Marvell Technology Group Ltd. Device [11ab:7080]
        Region 0: Memory at … [size=1M]
        Region 2: Memory at … [size=16M]
        Region 4: Memory … [size=16M]
        Capabilities: [178] SR-IOV, Initial VFs: 6, VF Device ID: 7081
        LnkSta: Speed 8GT/s, Width x2 (downgraded from x4)
```

**现在（我们自己写的 vNTB function，实测）**：

```
03:00.0 RAM memory [0500]: Freescale Semiconductor Inc Device [1957:0809]
```

x86 上跑 `ntb_hw_epf` + `ntb_transport` + `ntb_netdev`，端点由 NPU 的
`pci_epf_vntb` 提供（BAR0 控制 / BAR2 门铃 / BAR4 共享内存，各 1 MiB）。见 [档案](archive.md)。

> 原厂那个 BAR 布局和 `barmap` 结构现在用不上了。如果要做只读探测，
> `setpci -s 03:00.0 COMMAND=0x2` 打开 MEM decode 后 mmap `resource0` 即可 —— 但**别写**。

### MCP2210 USB-SPI

```
ID 04d8:00de Microchip Technology, Inc. MCP2210 USB to SPI Master   (hidraw0)
```

- 挂在内部 4 口 hub 上（`usb1-1.3`），12 Mbps HID。
- 原厂用途：从 x86 直接读写 NPU 的 SPI NOR（U-Boot / env），用于固件更新和救砖。
- 正确的命令集（**DS22288A**，实测）：`0x10` 状态、`0x11` 取消、`0x20/0x21` GPIO 设置、
  `0x30/0x31` GPIO 值、`0x32/0x33` 方向、`0x40/0x41` SPI 设置、`0x42` SPI 传输、`0x80` 释放。
  （早先这里写的 “0x10 GPIO / 0x20 SPI / 0x30 cancel / 0x40 transfer” 少了一组，已更正。）
- **救砖工具**：[tools/on-x86/mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py)，
  详见 [14-rescue.md](14-rescue.md)。实测：GP0 = flash CS；
  GP0/GP3/GP5 = NPU hold/release（AMDA0200：hold `0xFFD7`、release `0xFFFF`）。
- 这是**没有开盖时的最后救命通道**；日常只写 64 KiB env，mtd0 只有
  `mtd0-restore --unsafe-mtd0 --commit` 才会碰（只重写有差异的 64 KiB 块）。

### 串口

| 设备 | 用途 |
|---|---|
| `/dev/ttyS0` | x86 自己的控制台（COM5） |
| `/dev/ttyS2` | **NPU 控制台**（0x3E8, irq 5）；当前 Debian 上 host 侧设 **115200** 即线上 115200（只有老 `image/` 内核才要 57600，见 08 §10.3） |

`/dev/ttyS1` 和 `/dev/ttyS3` 是 AMD FCH 的 MMIO UART（`FEDC6000/FEDC8000`），
线路上没接东西，`rx:0`。

### I²C / GPIO

- `i2c-0 … i2c-4`（AMD SMBus），默认没加载 `i2c-dev`。
- `gpiochip512`（只有一个）。
- 温度：`k10temp` + `fam15h_power`。

## 6.4 噪声与已知问题

| 现象 | 说明 |
|---|---|
| `/proc/device-tree` 不存在 | x86 是 ACPI 平台，正常 |
| `dmidecode` 内存厂商 `<BAD INDEX>` | AMI BIOS 的 SMBIOS 字符串表问题，无影响 |
| 无 `thermal_zone` | ACPI 未导出，用 `hwmon` 即可 |
| 内置网卡缺失 | 正常，本机设计如此 |
| ~~系统时间不准且没有 NTP~~ | ✅ **已修（2026-11-23）**：装了 `systemd-timesyncd`，`timedatectl` 显示 `synchronized: yes`。之前比墙钟慢 1 小时，是 BIOS RTC 本来就不准 + 没有 NTP |

## 6.5 如果要重装/换系统

1. **UEFI + GPT**：用 `x86_64` 的 EFI 镜像；ESP 128 MiB（shim + grub 实测只用 4.4 MiB，约 29 倍余量）。
2. 建议保留一个"救援"启动项：Debian 的 shim/grub 或 systemd-boot。
3. 参考仓库里的 `install/x86-mbr.py` 针对的是 XGS 107 的 SATA+MBR，**不能直接照抄**。
4. 系统盘只有 16 GB，规划好空间。
5. 重装后要补的东西：NTB 栈模块（[tools/build/build-x86-vntb.sh](../tools/build/build-x86-vntb.sh)）、
   [systemd/x86/](../systemd/x86/) 的 4 个 unit + `100-wan.network` / `200-lan.network`、
   GRUB 的 `GRUB_TIMEOUT=2` / `GRUB_RECORDFAIL_TIMEOUT=2`（否则每次开机多等 30 s）。

## 6.6 还能做什么

这一块统一记在 [16-remaining-work.md](16-remaining-work.md)，不在本文重复。
其中最相关的一条：

- MCP2210 的 SPI NOR 读写工具（救砖用）**已完成**：
  [tools/on-x86/mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py)，见
  [14-rescue.md](14-rescue.md)。
- `.ko` 之外的 x86 侧就没有别的欠账了 —— 剩下的都是 NPU 那边的。
