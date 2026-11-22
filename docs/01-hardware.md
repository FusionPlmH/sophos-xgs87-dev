# 01 · 硬件清单

> 实测于一台 XGS 87（非无线）。凡是"实测"的条目都来自设备自身输出（见 `reference/`）。

## 1.1 整机身份

| 项目 | 值 | 来源 |
|---|---|---|
| 厂商 / 产品 | Sophos / XGS | DMI type 1 |
| 型号版本 | `87r1` | DMI type 1 |
| 主板版本 | `07` | DMI type 2 |
| 主板序列 | `SEAAMDA0200-…`（已脱敏） | DMI type 2 |
| BIOS | AMI 1906，2021-09-06，8 MB SPI ROM，UEFI | DMI type 0 |
| 机箱类型 | Desktop，单电源输入（实际两路 DC 冗余，见 02） | DMI type 3 |
| NPU VPD | partno `AMDA0200-0001`, revision `07`, vendor `SEA`, 7 个 MAC | `/persistent/xgsdt1-vpd.txt` |

VPD 原文（脱敏后）：

```
assembly.partno=AMDA0200-0001
assembly.revision=07
assembly.serial=<redacted-serial>
assembly.vendor=SEA
eth.mac=7C:5A:1C:XX:XX:XX
eth.macs=7
```

> `eth.macs=7` 表示这是 7 个连续 MAC 的基址（NPU eth0 / 4 个面板口 / SFP / 管理口）。

## 1.2 x86 模块

| 项目 | 值 |
|---|---|
| CPU | AMD Embedded R-Series **RX-216TD**（family 15h models 60h-6fh，2 核 2 线程） |
| 内存 | **2 × 2 GB DDR4-1600**（DMI type 17，两个 DIMM 槽） |
| 存储 | **16 GB eMMC**（SD 控制器 `00:14.7`），GPT |
| 显示 | 无（VGA 设备存在但无输出口） |
| 音频 | `00:09.2` Carrizo Audio Controller（无输出） |
| 安全处理器 | `00:08.0` AMD Carrizo PSP |
| SATA | `00:11.0` FCH AHCI —— **本机没有接 SATA 盘**（参考机型是 64 GB SATA） |
| SMBus | `00:14.0` FCH SMBus（i2c-0…i2c-4） |
| LPC | `00:14.3`（UART、GPIO 等走这里） |
| 固件 | AMI UEFI 1906，shim + grub，ESP 476 MB vfat |

### USB 树（实测 `lsusb -t`）

```
Bus 001  EHCI 2 ports
  └─ Port 1: 4-port hub
       └─ Port 3: Microchip MCP2210 USB-SPI Master (04d8:00de)  ← 12 Mbps HID
Bus 002  xHCI 4 ports (USB 2.0)
Bus 003  xHCI 4 ports (USB 3.0)
```

- 前面板 USB-A 是 x86 的（EHCI 高速）。
- **MCP2210** 是 USB→SPI 主控，原厂用来从 x86 更新 NPU 的 SPI NOR（U-Boot）。接在内部 hub 上，
  不需要开盖就能摸到。
- 设备节点：`/dev/hidraw0`（内核只绑了 `hid-generic`，没有专用驱动）。

### 串口 / 中断

| 设备 | 类型 | 地址 | IRQ | 用途 |
|---|---|---|---|---|
| ttyS0 | 16550A | I/O 0x3F8 | 4 | **x86 控制台**（RJ45/USB） |
| ttyS1 | 16550A | MMIO 0xFEDC6000 | 10 | AMD FCH UART（未接） |
| ttyS2 | 16550A | **I/O 0x3E8** | 5 | **NPU 控制台** |
| ttyS3 | 16550A | MMIO 0xFEDC8000 | 11 | AMD FCH UART（未接） |

> 注意 `base_baud` 只有 115200（1.8432 MHz 时钟），x86 侧这两个口**上不了更高速率**。
> NPU 侧（mvebu 8250）理论上可以更高，但受限于 x86，串口链路最高 115200。

### I²C

`/sys/bus/i2c/devices` 有 `i2c-0 … i2c-4`（AMD SMBus 控制器），**没有加载 `i2c-dev`**，
所以没有 `/dev/i2c-N`。若要访问需 `modprobe i2c-dev`。

### 传感器

- `k10temp`（CPU 温度）、`fam15h_power`（功耗）。
- 没有 `thermal_zone`（ACPI 没导出），无风扇转速（本机无风扇）。

## 1.3 NPU 模块

| 项目 | 值 |
|---|---|
| SoC | **Marvell CN9130**（AP807-B0 quad A72 + CP115-A0），CPU 1.6 GHz |
| 内存 | 2 GiB DDR（DDR 1200 MHz），可用 1.53 GiB（256 MiB CMA 保留） |
| Boot Flash | SPI NOR **mx25l3205d** 4 MiB（U-Boot 4032 KiB + env 64 KiB） |
| 主存储 | eMMC **H8G4a2** 7.28 GiB（4 分区，见 07） |
| 以太网 | `mvpp2` eth0，10GBase-KR，Comphy lane 4 = SFI0 10.3125 Gbps |
| 交换机 | **88E6193X**，MDIO addr 2（`mdio@12a200`） |
| USB | 2× xHCI（`f2500000`, `f2510000`）+ UTMI PHY0/1，VBUS 由 CP GPIO1.9 / GPIO2.21 控制 |
| 串口 | `ttyS0` @ `0xf0512000`，115200 8N1（earlycon 同址） |
| I²C | i2c-0：0x20 PCA9555（LED）、0x57 EEPROM、0x64；i2c-1：SFP EEPROM 0x50/0x51 |
| GPIO | gpiochip0 / 32 / 64 / 496（CP0/AP/CP1 + 扩展） |
| RTC | `armada38x-rtc` @ `f2284000`（电池掉电会回到 2105 年） |
| 看门狗 | `sbsa-gwdt` @ `f0610000`，10 s 超时 |
| 温度 | 6 个 thermal zone，空闲 52-55 ℃ |

### PCIe 端点（关键）

NPU 侧 `pcie@f2600000`（DesignWare + Marvell wrapper）工作在 **endpoint 模式**，
在 x86 上表现为 `03:00.0 [11ab:7080]`：

| BAR | 大小 | 说明 |
|---|---|---|
| BAR0 | 1 MiB | 控制区（doorbell / scratchpad / 状态） |
| BAR2 | 16 MiB | 数据窗口（`armada-ep` 用） |
| BAR4 | 16 MiB | 第二个数据窗口 |

- 链路：Gen3 ×2（能力 ×4，实际降宽）。
- SR-IOV：6 个 VF，Device ID `7081`。
- NPU 内核日志：`Remapped host memory @ … size 0x1000000000`（64 GB 入站窗口）。
- 原厂 x86 驱动（`mv_pcinet_drv` / `mv_nwa_host`）用它做包转发；开源方案改用 **NTB**（见 02、09）。

## 1.4 面板与指示灯

| 面板 | 交换机口 | 类型 | 速率 LED（PCA9555 引脚） |
|---|---|---|---|
| 1 / LAN | 1 | RJ45 内置 PHY | green `gpio:3:0` / amber `gpio:3:1` |
| 2 / WAN | 2 | RJ45 | `gpio:3:2` / `gpio:3:3` |
| 3 / DMZ | 3 | RJ45 | `gpio:3:4` / `gpio:3:5` |
| 4 | 4 | RJ45 | `gpio:3:6` / `gpio:3:7` |
| F1 | 9 | SFP（SFF-8431） | PHY 直驱，LEDctl 0xe1 |
| CPU | 0 | 10G XFI 到 CN9130 | — |

- RJ45 的 PHY LED 控制寄存器值：`0xe3`；SFP：`0xe1`（原厂设置）。
- LED 扩展芯片 PCA9555 在 i2c-0 地址 0x20（Linux 里是 `gpiochip` 第 4 个，编号 3）。
- 极性：原厂当低有效用（未逐一验证）。

## 1.5 电源与复位

| 项目 | 说明 |
|---|---|
| 输入 | 两路 DC（冗余），机箱背面 |
| 交换机复位 | CP GPIO2 pin 17（U-Boot 里 `gpio clear C17` / `set C17`） |
| NPU 复位 | 由 x86 侧控制（原厂通过 CPLD/GPIO；本机未完全确认路径，见 09） |
| 风扇 | 无（被动散热，机身有散热片） |
