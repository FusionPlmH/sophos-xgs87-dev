# 05 · x86 系统（Debian）

> 🏷 **状态（2026-11-23 复核）**：✅ **实测**：分区、EFI、串口、MCP2210 均在现机上复核；`/dev/ttyS2` 的波特率坑见 08。

## 5.1 现状

| 项目 | 值 |
|---|---|
| 发行版 | Debian GNU/Linux 13 (trixie)，内核 6.12.94+deb13-amd64 |
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
├─mmcblk0p1   476M part vfat   /boot/efi
└─mmcblk0p2  14.2G part ext4   /
mmcblk0boot0    4M disk          (eMMC 硬件分区)
mmcblk0boot1    4M disk
```

`/etc/fstab` 用 UUID 挂载（`UUID=… / ext4` + `UUID=… /boot/efi vfat`），换盘/重装时注意。

## 5.2 为什么没有网口，以及现在怎么上网

x86 侧完全没有 MAC/PHY：

- `lspci` 里只有 AMD 的 FCH 设备 + `03:00.0` 的 NPU 端点，**没有任何 Ethernet controller**。
- 原厂靠 Sophos 专有驱动把 NPU 的面板口"搬"到 x86 上（`Port1…Port4` + `PortF1`），
  这些驱动只支持 4.14。

**现在的实际网络（实测 `ip -br a`）**：

```
lo               UNKNOWN  127.0.0.1/8
eth0             UP       (无地址)                 ← vNTB，PCIe 上的虚拟网线
eth0.100@eth0    UP       192.168.100.2/24         ← 管理段，对端 NPU .1
eth0.31@eth0     UP       192.168.0.50/24 (DHCP)  ← 家里内网，经 NPU 的 p4 透传
```

- 这条虚拟网线两侧**只有 x86 和 NPU**，所以想上真正的内网必须让 NPU 把某个面板口桥进来
  （现在是 `p4`）。详见 [20](20-lan-over-vntb.md)。
- 需要的模块都在 `/lib/modules/$(uname -r)/extra/`：`ntb_core` / `ntb_hw_epf` /
  `ntb_transport` / `ntb_netdev`（Debian 不自带 NTB 栈，见 [tools/build](../tools/build/)）。
- 装机脚本在 [systemd/x86/](../systemd/x86/)，安装步骤见 [systemd/README.md](../systemd/README.md)。

## 5.3 关键外设

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
`pci_epf_vntb` 提供（BAR0 控制 / BAR2 门铃 / BAR4 共享内存，各 1 MiB）。见 [17](17-x86-npu-shared-mgmt.md)。

> 原厂那个 BAR 布局和 `barmap` 结构现在用不上了。如果要做只读探测，
> `setpci -s 03:00.0 COMMAND=0x2` 打开 MEM decode 后 mmap `resource0` 即可 —— 但**别写**。

### MCP2210 USB-SPI

```
ID 04d8:00de Microchip Technology, Inc. MCP2210 USB to SPI Master   (hidraw0)
```

- 挂在内部 4 口 hub 上（`usb1-1.3`），12 Mbps HID。
- 原厂用途：从 x86 直接读写 NPU 的 SPI NOR（U-Boot / env），用于固件更新和救砖。
- 目前 Debian 只绑了 `hid-generic`，没有驱动；需要自己写（MCP2210 有公开的 HID 命令集：
  0x10 get GPIO settings、0x20 SPI transfer settings、0x40 SPI transfer 等）。
- 这是**没有开盖时的最后救命通道**，值得写成工具。

### 串口

| 设备 | 用途 |
|---|---|
| `/dev/ttyS0` | x86 自己的控制台（COM5） |
| `/dev/ttyS2` | **NPU 控制台**（0x3E8, irq 5）；host 侧 `stty` 要设 **57600**（线上 115200，见 08） |

`/dev/ttyS1` 和 `/dev/ttyS3` 是 AMD FCH 的 MMIO UART（`FEDC6000/FEDC8000`），
线路上没接东西，`rx:0`。

### I²C / GPIO

- `i2c-0 … i2c-4`（AMD SMBus），默认没加载 `i2c-dev`。
- `gpiochip512`（只有一个）。
- 温度：`k10temp` + `fam15h_power`。

## 5.4 噪声与已知问题

| 现象 | 说明 |
|---|---|
| `/proc/device-tree` 不存在 | x86 是 ACPI 平台，正常 |
| `dmidecode` 内存厂商 `<BAD INDEX>` | AMI BIOS 的 SMBIOS 字符串表问题，无影响 |
| 无 `thermal_zone` | ACPI 未导出，用 `hwmon` 即可 |
| 内置网卡缺失 | 正常，本机设计如此 |
| ~~系统时间不准且没有 NTP~~ | ✅ **已修（2026-11-23）**：装了 `systemd-timesyncd`，`timedatectl` 显示 `synchronized: yes`。之前比墙钟慢 1 小时，是 BIOS RTC 本来就不准 + 没有 NTP |

## 5.5 如果要重装/换系统

1. **UEFI + GPT**：用 `x86_64` 的 EFI 镜像，ESP 476 MB 足够。
2. 建议保留一个"救援"启动项：Debian 的 shim/grub 或 systemd-boot。
3. 参考仓库里的 `install/x86-mbr.py` 针对的是 XGS 107 的 SATA+MBR，**不能直接照抄**。
4. 系统盘只有 16 GB，规划好空间。
5. 重装后要补的东西：NTB 栈模块（[tools/build/build-x86-vntb.sh](../tools/build/build-x86-vntb.sh)）、
   [systemd/x86/](../systemd/x86/) 的 4 个 unit + `31-house-lan.network`、
   GRUB 的 `GRUB_TIMEOUT=2` / `GRUB_RECORDFAIL_TIMEOUT=2`（否则每次开机多等 30 s）。

## 5.6 还能做什么

这一块统一记在 [09-remaining-work.md](09-remaining-work.md)，不在本文重复。
其中最相关的两条：

- MCP2210 的 SPI NOR 读写工具（救砖用，目前没驱动）。
- `.ko` 之外的 x86 侧就没有别的欠账了 —— 剩下的都是 NPU 那边的。
