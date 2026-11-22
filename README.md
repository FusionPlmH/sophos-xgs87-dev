# Sophos XGS 87 — 硬件档案与架构设计

> 现场实测记录。所有数据来自一台 **Sophos XGS 87**（非无线版）实机：x86 侧跑 Debian 13，
> NPU 侧保留原厂 Buildroot。本仓库用于后续把它改造成可自由使用的设备（OpenWrt / 自研固件 / 服务节点）。
>
> 与 Sophos 官方无关。仓库内不含任何原厂二进制，只包含实测数据、设备树和脚本。

## 一分钟看懂这台机器

它其实是**两台电脑塞在一个盒子里**，用一个 PCIe 链路相连：

```
                       ┌──────────────────────────────────────────────┐
   Console (RJ45) ────► │  x86: AMD RX-216TD, 4 GB DDR4, 16 GB eMMC    │
                        │  Debian 13 / 6.12 — 通用计算，没有网口        │
                        │  ttyS2 ────────────────┐                     │
                        │  PCIe EP 03:00.0 ◄──┐  │                     │
                        └─────────────────────┼──┼─────────────────────┘
                                              │  │ 115200 串口（NPU 控制台）
                        ┌─────────────────────┼──┼─────────────────────┐
                        │  NPU: Marvell CN9130 (4×A72, 2 GB)           │
                        │  Buildroot / Linux 4.14 — 网络数据面          │
                        │  mvpp2 eth0 ══ 10GBase-KR ══ 88E6193X port0  │
                        └──────────────────────────┬───────────────────┘
                                                   │
                             ┌─────────────────────┴──────────────┐
                             │  88E6193X (SOHO Amethyst, 11 口)    │
                             │  port1-4 → 面板 1/LAN 2 3 4  (1G)   │
                             │  port9   → 面板 F1 SFP              │
                             │  port0   → CN9130 (10G XFI)         │
                             └────────────────────────────────────┘
```

- **面板上 4 个 RJ45 + 1 个 SFP 全部挂在 NPU 的交换机上**，x86 完全没有自己的网口。
- x86 与 NPU 之间只有 **PCIe 端点** + **一路 UART**（x86 `/dev/ttyS2` ↔ NPU `ttyS0`）。
- 原厂设计里 x86 做控制面/应用（Wi-Fi、管理界面），NPU 做数据面（交换、转发）。
  两家参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
  [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）都是围绕这个分工做的。

## 本机与参考机型的差异（很重要）

| 项目 | 参考仓库（XGS 107/136） | **本机 XGS 87** |
|---|---|---|
| 面板口 | 8×RJ45 + SFP | **4×RJ45 + SFP**（switch port 1-4、9） |
| partno | AMDA0200-0004 | **AMDA0200-0001** |
| 板卡版本 | 1.40 | **07**（BIOS 1906 / 2021-09） |
| x86 系统盘 | 64 GB SATA | **16 GB eMMC**（SD 控制器，GPT+EFI） |
| Wi-Fi | QCA988x | **无** |

## 仓库结构

| 路径 | 内容 |
|---|---|
| [docs/01-hardware.md](docs/01-hardware.md) | 完整硬件清单（x86 / NPU / 外设），含 DMI、PCI、USB、I²C、温度 |
| [docs/02-architecture.md](docs/02-architecture.md) | 整体架构、数据通路、PCIe 端点与 NTB 方案、电源/复位 |
| [docs/03-boot-chain.md](docs/03-boot-chain.md) | BootROM → TF-A → U-Boot → Linux，全过程实录与环境变量 |
| [docs/04-npu-system.md](docs/04-npu-system.md) | NPU Buildroot 系统：init 脚本、驱动、CPSS、platform 文件、VPD |
| [docs/05-x86-system.md](docs/05-x86-system.md) | x86 Debian 侧：分区、EFI、串口、MCP2210、现状 |
| [docs/06-switch-and-ports.md](docs/06-switch-and-ports.md) | 88E6193X、端口映射、PHY/LED、SFP、MDIO、`mvswitch` 全部实测 |
| [docs/07-storage.md](docs/07-storage.md) | eMMC 分区表、SPI NOR、镜像布局与备份策略 |
| [docs/08-console-access.md](docs/08-console-access.md) | 三种进机方式、坑（含 pyserial 清缓冲的坑） |
| [docs/09-adaptation-notes.md](docs/09-adaptation-notes.md) | 做 OpenWrt / 自研固件要改什么，已知缺口 |
| [docs/10-ideas.md](docs/10-ideas.md) | **这台机器独特设计的最佳用法**（重点，持续更新） |
| [docs/11-roadmap.md](docs/11-roadmap.md) | 下一步实验清单 |
| [docs/12-measurements.md](docs/12-measurements.md) | **实测记录**：LED、`dev_write`、**SFP 10G**、**原厂交换机初始化序列**、PCIe、GPIO、完整备份 |
| [reference/](reference/) | 设备树 DTS、内核 config、U-Boot/env 镜像、脱敏后的完整信息 dump |
| [tools/](tools/) | 采集/转换脚本（设备树转 DTS、脱敏） |

## 关键事实速查

| | |
|---|---|
| 型号 | Sophos XGS 87，DMI `XGS 87r1`，板卡 rev 07，BIOS 1906 |
| NPU SoC | Marvell CN9130（AP807-B0 + CP115-A0），4×A72@1.6G，2 GB DDR |
| NPU 系统 | Buildroot 2018.11 + Linux 4.14.207-10.22.03（Marvell SDK 10.22.03） |
| 交换机 | Marvell 88E6193X，MDIO addr 2，product 193，11 口 |
| x86 | AMD RX-216TD（2C），2×2 GB DDR4-1600，16 GB eMMC |
| x86 PCIe | NPU 端点 `11ab:7080`，Gen3 ×2，6 个 SR-IOV VF（`7081`） |
| NPU console | x86 `/dev/ttyS2` @115200，NPU root **默认无密码** |
| x86 console | RJ45 / micro-USB，115200（USB 口 38400） |
| 存储 | NPU：4 MB SPI NOR（U-Boot+env）+ 7.28 GiB eMMC（4 分区） |
| MAC | VPD 里 1 个基址 + 7 个连续地址（详细见 06） |

## 免责声明

- 数据是实机采集，可能因批次/固件版本不同而变化；关键结论都标了"实测"。
- 不含 Sophos 专有二进制；`reference/npu-mtd0-uboot.bin.gz` 是 GPLv2 的 U-Boot 镜像，可自由分发。
- 拆机/改固件有风险，自行承担。
