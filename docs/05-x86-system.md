# 05 · x86 系统（Debian）

## 5.1 现状

| 项目 | 值 |
|---|---|
| 发行版 | Debian GNU/Linux 13 (trixie)，内核 6.12.94+deb13-amd64 |
| 固件 | AMI UEFI BIOS 1906，**UEFI + GPT**（shim + grub） |
| CPU | AMD RX-216TD，2 核 |
| 内存 | 2×2 GB DDR4-1600（可见 3.8 GiB） |
| 系统盘 | 16 GB eMMC（`mmcblk0`） |
| 网络接口 | **只有 lo**（没有任何以太网设备） |
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

## 5.2 为什么没有网口

x86 侧完全没有 MAC/PHY：

- `lspci` 里只有 AMD 的 FCH 设备 + `03:00.0` 的 NPU 端点，**没有任何 Ethernet controller**。
- `ip -br link` 只有 `lo`。
- 原厂靠 Sophos 专有驱动把 NPU 的 4 个面板口"搬"到 x86 上（`Port1…Port4` + `PortF1`），
  这些驱动只支持 4.14。

所以：**x86 想联网，必须通过 NPU**（NTB / PCIe 隧道 / 把 NPU 当网关）。

## 5.3 关键外设

### PCIe 上的 NPU 端点

```
03:00.0 Ethernet controller [0200]: Marvell Technology Group Ltd. Device [11ab:7080]
        Region 0: Memory at … [size=1M]
        Region 2: Memory at … [size=16M]
        Region 4: Memory at … [size=16M]
        Capabilities: [178] SR-IOV, Initial VFs: 6, VF Device ID: 7081
        LnkSta: Speed 8GT/s, Width x2 (downgraded from x4)
```

- 现在是 **BusMaster- Mem-**（BAR 未使能），因为没有驱动。
- 想直接访问：`setpci -s 03:00.0 COMMAND=0x2` 打开 MEM decode，然后 mmap
  `/sys/bus/pci/devices/0000:03:00.0/resource0`（1 MiB 控制区）。
  **只读探测安全，写之前一定要搞清楚映射**（原厂有 barmap 结构）。

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

## 5.5 如果要重装/换系统

1. **UEFI + GPT**：用 `x86_64` 的 EFI 镜像，ESP 486 MB 足够。
2. 建议保留一个"救援"启动项：Debian 的 shim/grub 或 systemd-boot。
3. 装 OpenWrt x86 时注意它默认要 MBR/BIOS 或 EFI；本项目是 EFI，参考仓库里的
   `install/x86-mbr.py` 针对的是 XGS 107 的 SATA+MBR，**不能直接照抄**。
4. 系统盘只有 16 GB，OpenWrt + 容器要规划好空间。

## 5.6 后续可以做的

- [ ] 写一个 `x86` 侧的 NPU 监管服务：串口抓 boot log、U-Boot 里跑 `sw_init`、重启 NPU。
- [ ] 用 MCP2210 做一个 SPI NOR 读写工具（备份/恢复 U-Boot）。
- [ ] 通过 NTB 给 x86 一条 1Gbps 级别的虚拟网口。
