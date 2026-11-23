# 01 · 硬件清单

> 🏷 **状态（2026-11-23 复核）**：✅ **实测**（DMI/PCI/USB/I²C/GPIO/thermal 均在现机复核）。已修正：单路电源、GPIO 是 3 个 chip 不是 4 个、PCIe 端点分"原厂 11ab:7080"与"现在的 vNTB 1957:0809"两种状态。⚠️ 风扇：**有**，但软件不可控。

> 实测于一台 XGS 87（非无线）。凡是"实测"的条目都来自设备自身输出（见 `reference/`）。

## 1.1 整机身份

| 项目 | 值 | 来源 |
|---|---|---|
| 厂商 / 产品 | Sophos / XGS | DMI type 1 |
| 型号版本 | `87r1` | DMI type 1 |
| 主板版本 | `07` | DMI type 2 |
| 主板序列 | `SEAAMDA0200-…`（已脱敏） | DMI type 2 |
| BIOS | AMI 1906，2021-09-06，8 MB SPI ROM，UEFI | DMI type 0 |
| 机箱类型 | Desktop，**单路电源输入**（一条电源线同时喂 x86 和 NPU，断电两台一起下） | DMI type 3 + 实测 |
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

> 注意 `base_baud` 被内核报成 115200（1.8432 MHz 时钟），但这块板的实际晶振是它的**两倍**：
> 软件里设 57600，线上才是 115200。所以从 x86 用 `/dev/ttyS2` 打开 NPU 控制台时必须写
> `stty -F /dev/ttyS2 57600`，写 115200 只会读到 0~2 字节乱码。详见 [08](08-console-access.md)。

### I²C

`/sys/bus/i2c/devices` 有 `i2c-0 … i2c-4`（AMD SMBus 控制器），**没有加载 `i2c-dev`**，
所以没有 `/dev/i2c-N`。若要访问需 `modprobe i2c-dev`。

### 传感器

- `k10temp`（CPU 温度）、`fam15h_power`（功耗）。
- 没有 `thermal_zone`（ACPI 没导出），也没有风扇转速传感器 —— **本机有风扇**，但转速既不在 SuperIO 里也不在 ACPI 里导出，软件看不到也控不了（见 19 §19.6）。

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
| GPIO | **3 个** `gpiochip0`(base 0, AP `f06f4000`)、`gpiochip1`(base 32, CP0 `f2440000` @0x100)、`gpiochip2`(base 64, CP0 @0x140) |
| RTC | `armada38x-rtc` @ `f2284000`（电池掉电会回到 2105 年） |
| 看门狗 | `sbsa-gwdt` @ `f0610000`，10 s 超时 |
| 温度 | **6 个 thermal zone**（`ap-ic`、`ap-cpu0..3`、`cp0-ic`），实测空闲 **49–51 ℃**；另有 9 个 hwmon（`sfp` + 8 个 `mv88e6xxx` PHY 温度） |

### PCIe 端点（关键）

NPU 侧 `pcie@f2600000`（DesignWare + Marvell wrapper）工作在 **endpoint 模式**。

> ⚠️ **分两种状态看**：下面这张表是**原厂** endpoint function 的档案（`11ab:7080`，SR-IOV 6 个 VF）。
> 现在跑的是自己写的 **vNTB** function，在 x86 上枚举成 `03:00.0 [1957:0809]`，BAR 只有
> ctrl / db / mw 各 1 MiB（见 [17](17-x86-npu-shared-mgmt.md)）。原厂那张表：

| BAR | 大小 | 说明 |
|---|---|---|
| BAR0 | 1 MiB | 控制区（doorbell / scratchpad / 状态） |
| BAR2 | 16 MiB | 数据窗口（`armada-ep` 用） |
| BAR4 | 16 MiB | 第二个数据窗口 |

- 链路：Gen3 ×2（能力 ×4，实际降宽）。
- SR-IOV：6 个 VF，Device ID `7081`。
- NPU 内核日志：`Remapped host memory @ … size 0x1000000000`（64 GB 入站窗口）。
- 原厂 x86 驱动（`mv_pcinet_drv` / `mv_nwa_host`）用它做包转发；**现在改用 vNTB**（见 17、20）。

## 1.4 面板与指示灯

| 面板 | 交换机口 | 类型 | 速率 LED（原厂 DTB 里的 `gpio` 号，未验证） |
|---|---|---|---|
| 1 / LAN | 1 | RJ45 内置 PHY | green `gpio:3:0` / amber `gpio:3:1` |
| 2 / WAN | 2 | RJ45 | `gpio:3:2` / `gpio:3:3` |
| 3 / DMZ | 3 | RJ45 | `gpio:3:4` / `gpio:3:5` |
| 4 | 4 | RJ45 | `gpio:3:6` / `gpio:3:7` |
| F1 | 9 | SFP（SFF-8431） | PHY 直驱，LEDctl 0xe1 |
| CPU | 0 | 10G XFI 到 CN9130 | — |

- RJ45 的 PHY LED 控制寄存器值：`0xe3`；SFP：`0xe1`（原厂设置）。
- 上表 `gpio:3:x` 是**原厂 DTB** 的写法（那时它还多一个 chip）；现机只有 3 个 `gpiochip`，
  面板灯实测走的是 **PHY 自带的 LED 控制寄存器**，`PCA9555` 驱动面板灯已被证伪（见 [06](06-switch-and-ports.md)）。
- LED 极性：原厂当低有效用，**未逐一验证**。

## 1.5 电源与复位

| 项目 | 说明 |
|---|---|
| 输入 | **单路** DC（机箱背面），一条线同时喂 x86 和 NPU，断电两台一起下 |
| 交换机复位 | CP GPIO2 pin 17（U-Boot 里 `gpio clear C17` / `set C17`） |
| NPU 复位 | x86 断 PCIe 链路（PERST#）时 NPU 会**整机复位**，实测与软件无关（ramoops 里零记录），见 20 §20.8 |
| 风扇 | **有**（整机一颗，随电源常转）—— 但**软件不可控**：x86 侧无 SuperIO 风扇控制器、ACPI 无风扇设备；NPU 侧原厂 DTB 里没有任何 `fan`/`pwm` 节点。要么定速，要么板载硬件温控 |
