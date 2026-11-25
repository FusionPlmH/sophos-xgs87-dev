# 01 硬件

## 两块 SoC

| | x86 半边 | NPU 半边 |
|---|---|---|
| SoC | AMD 嵌入式（Family 15h，PCI 里报 `Family 15h (Models 60h-6fh)`） | Marvell **CN9130** = AP807（4×A72 @1600 MHz）+ CP115 |
| 内存 | 3.9 GiB 可见 | **2 GiB**（DDR 1200 MHz） |
| 自己的启动盘 | eMMC 14.7 GB（GPT：p1 128 MiB ESP + p2 根） | eMMC **7.28 GiB**（H8G4a2，4 个分区，见 [02](02-system.md)） |
| 固件 | AMI BIOS（`XG8701906`，2021-09-06） | SPI NOR **mx25l3205d 4 MiB**：TF-A BL31（`v2.2 Marvell-10.22.06`）+ U-Boot（`2019.10-10.22.03`） |
| 控制台 | `/dev/ttyS0`，**115200**，面板的 RJ45（PC 侧是 COM5）或 micro-USB | UART 接在 x86 的 **`/dev/ttyS2`**，115200 |

**115200 是硬上限**：x86 两颗 16550 的 `base_baud` 就是 115200，再往上没有除数可用。
所以"往 NPU 推几十 MB"永远只能是 115200 的速度（实测 9.8 KiB/s）。

## 面板口和交换芯片

- **88E6193X**（`Product # : 193`，SOHO/Amethyst 系列），9 个口 + 一个 SFP 10G。
- CPU 口接 CN9130 的 **10G `mvpp2`**（`f2000000.ethernet`，`10gbase-r`，DSA master），MDIO 在
  `f212a200.mdio-mii`，驱动 `mv88e6xxx`（DSA），用户口就是 `p1..p8` + `sfp`。
- 面板丝印：`1` = LAN，`2` = WAN，`3`/`4` 也是面板口。**`p5`–`p8` 面板上没引出**，只有寄存器里在。
- **NPU 没有自己的物理网口**，面板口全部经过这颗交换机。原厂 4.14 内核里连 `mv88e6xxx` 都没有，
  所以"面板口能通"是换了 6.12 之后才成立的事。

MAC 是谁：U-Boot env 的 `ethaddr` 是基址，`p1..p4` = 基址 +0..3，`sfp` = +4，`end0/eth0` = +5
（`systemd/npu/xgs-ports-init.sh` 开机推一遍）。

## 板内连线

| 走什么 | 从 | 到 | 备注 |
|---|---|---|---|
| PCIe | x86 root port `00:03.1`（`03.1-[03]----00.0`） | NPU EP `f2600000.pcie` | 8 GT/s ×2，实测 **15.75 Gb/s**；vNTB 设备 ID `1957:0809` |
| UART | x86 `ttyS2` | NPU `ttyS0`（TF-A / U-Boot / Linux 控制台） | 115200 8N1，无流控 |
| 面板 1/2/3/4 | 88E6193X | 前面板 | 1 = LAN，2 = WAN |
| SFP | 88E6193X port 9 | 前面板 SFP 笼 | 10G |

PCIe 是 **EP 模式**：NPU 当 endpoint（`pci_epf_vntb` + `ntb_transport`），x86 当 host
（`ntb_hw_epf` + `ntb_transport`）。BIOS 只在 POST 枚举 endpoint —— **NPU 先上电，或者事后
重启一次 x86**，否则 x86 上的 `eth0` 永远不出现。

## 其他

- 原厂 SPI NOR 里存着 U-Boot env，NPU 上 `fw_printenv` / `fw_setenv` 改的就是它。
- 面板 LED 走交换机的 LED 引擎，极性没逐个验过，别当结论用。
