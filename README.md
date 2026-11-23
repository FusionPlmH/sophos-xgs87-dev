# Sophos XGS 87 — 硬件档案、架构设计与改造记录

> 现场实测记录。所有数据来自一台 **Sophos XGS 87**（非无线版）实机，目前**两边都已换成 Debian 13**：
> x86 跑通用计算，NPU 跑数据面。本仓库记录把它改造成可自由使用设备（OpenWrt / 自研固件 / 服务节点）的全过程。
>
> 与 Sophos 官方无关。仓库内不含任何原厂二进制，只包含实测数据、设备树、补丁和脚本。

## 现在是什么状态

```
x86  192.168.0.50   Debian 13.6 / 6.12.94   ──┐  家里内网（DHCP，走 vNTB VLAN 31）
NPU  192.168.0.66   Debian 13.6 / 6.12.117  ──┘
x86 ↔ NPU 管理段 192.168.100.2 ↔ .1            VLAN 100，RTT 0.7 ms
前面板 p8 → br-mgmt access 口                  插笔记本可同时访问 .1 / .2
```

| 能力 | 状态 |
|---|---|
| NPU 跑 Debian 13（eMMC 自启） | ✅ |
| 9 个网口（p1–p8 + SFP）在 Debian 下工作 | ✅ |
| SFP+ 10GBASE-R | ✅ |
| x86 ↔ NPU PCIe vNTB 链路（含 bridge/netdev） | ✅ 单流 1.2 Gbit/s、RTT 0.6 ms |
| x86 自己拿到家里内网地址（无需网线） | ✅ 一条 PCIe 链路同时跑管理段和 LAN |
| EIP197 硬件加密 | ✅ 可启用，但实测不划算，默认不开（见 docs/16） |
| `mvpp2` 聚合 TX 队列 512 | ✅ 自编译模块 |
| `mv88e6xxx` TCAM 越权修复 | ✅ 交叉编译打上（见 docs/20 §20.9） |
| 风扇软件控制 | ❌ 板载定速/硬件温控，不可控（docs/19） |
| 完整开机无牵连重启 | ❌ 主机断 PCIe 链路时 NPU 会被 PERST# 复位（硬件行为，docs/20 §20.8） |

## 一分钟看懂这台机器

它其实是**两台电脑塞在一个盒子里**，用一条 PCIe 链路 + 一条内部串口相连：

```
                       ┌──────────────────────────────────────────────┐
   Console ──────────► │  x86: AMD RX-216TD, 4 GB DDR4, 16 GB eMMC    │
   (RJ45 / microUSB)   │  Debian 13 / 6.12 — 通用计算，自己没有网口   │
                       │  ttyS2 ───────────────┐                     │
                       │  PCIe EP 03:00.0 ◄──┐ │                     │
                       └─────────────────────┼─┼─────────────────────┘
                                             │ │ 串口（NPU 控制台）
                       ┌─────────────────────┼─┼─────────────────────┐
                       │  NPU: Marvell CN9130 (4×A72, 2 GB)           │
                       │  Debian 13 / 6.12 — 网络数据面                │
                       │  mvpp2 end0 ══ 10GBase-KR ══ 88E6193X port0  │
                       └──────────────────────────┬───────────────────┘
                                                  │
                            ┌─────────────────────┴──────────────┐
                            │  88E6193X (SOHO Amethyst, 11 口)    │
                            │  port1-4 → 面板 1/LAN 2 3 4  (1G)   │
                            │  port9   → 面板 F1 SFP (10G)        │
                            │  port0   → CN9130 (10G XFI)         │
                            └────────────────────────────────────┘
```

- **面板上 4 个 RJ45 + 1 个 SFP 全部挂在 NPU 的交换机上**，x86 自己没有网口 ——
  它现在通过 vNTB 上的 VLAN 借道 NPU 上网。
- x86 与 NPU 之间只有 **PCIe 端点** + **一路内部 UART**。
- 原厂设计里 x86 做控制面/应用（Wi-Fi、管理界面），NPU 做数据面（交换、转发）。
  两家参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
  [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）都是围绕这个分工做的。

## 怎么进去（三选一）

| 目标 | 方法 |
|---|---|
| x86 | `ssh root@192.168.0.50`（家里内网） |
| NPU | `ssh root@192.168.0.66`（家里内网，走 NPU 自己的 br-lan） |
| x86 控制台 | COM5（RJ45）或 micro-USB，**115200** |
| NPU 控制台 | **x86 的 `/dev/ttyS2`，host 侧要设 57600**（这颗 16550 的分频基准是标称值的两倍，软件 57600 = 线上 115200）。账号 `root` / `openwrt123` |

⚠️ `/dev/ttyS2` **同一时刻只能有一个读者**，两个 `cat` 会把字节流切成乱码。
现成工具：[tools/npu-console.sh](tools/npu-console.sh)、[tools/x86-console.py](tools/x86-console.py)。

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
| [docs/04-npu-system.md](docs/04-npu-system.md) | NPU **原厂** Buildroot 系统（改造前的档案）：init、驱动、CPSS、VPD |
| [docs/05-x86-system.md](docs/05-x86-system.md) | x86 Debian 侧：分区、EFI、串口、MCP2210 |
| [docs/06-switch-and-ports.md](docs/06-switch-and-ports.md) | 88E6193X、端口映射、PHY/LED、SFP、MDIO、`mvswitch` 全部实测 |
| [docs/07-storage.md](docs/07-storage.md) | eMMC 分区表、SPI NOR、镜像布局与备份策略 |
| [docs/08-console-access.md](docs/08-console-access.md) | 进机方式与坑（含 57600 这件事的来龙去脉） |
| [docs/09-adaptation-notes.md](docs/09-adaptation-notes.md) | 做 OpenWrt / 自研固件要改什么，已知缺口 |
| [docs/10-ideas.md](docs/10-ideas.md) | **这台机器独特设计的最佳用法**（持续更新） |
| [docs/11-roadmap.md](docs/11-roadmap.md) | 实验清单 |
| [docs/12-measurements.md](docs/12-measurements.md) | 实测记录：LED、SFP 10G、原厂交换机初始化序列、PCIe、GPIO、备份 |
| [docs/13-npu-os-plan.md](docs/13-npu-os-plan.md) | NPU 换系统方案：OpenWrt vs Debian、DTS 让 SFP 跑 10G、debootstrap |
| [docs/14-npu-debian-hardware.md](docs/14-npu-debian-hardware.md) | Debian 下硬件补齐：SFP+ 10G、SPI NOR/MTD、`fw_printenv`、EIP197 |
| [docs/15-performance.md](docs/15-performance.md) | 性能标定：CPU 1.6 GHz、转发、加密、可采纳项清单 |
| [docs/16-eip197-activated.md](docs/16-eip197-activated.md) | **EIP197 激活成功**、正确性验证、CPU 成本实测、为何最终不启用 |
| [docs/17-x86-npu-shared-mgmt.md](docs/17-x86-npu-shared-mgmt.md) | **x86 与 NPU 共享 p8 管理口**：阶段 1 桥接、阶段 2 NTB 的四个真实 bug |
| [docs/18-same-soc-platforms.md](docs/18-same-soc-platforms.md) | **同族平台调研**：上游 Sophos DTS、88E6193X 的 PTP/TCAM、mvpp2 旋钮、EP 的 `dbi2` 陷阱 |
| [docs/19-module-vs-kernel-rebuild.md](docs/19-module-vs-kernel-rebuild.md) | 模块 vs 重编内核、换模块的失联风险、风扇归属 |
| [docs/20-lan-over-vntb.md](docs/20-lan-over-vntb.md) | **一条 PCIe 链路跑两套网络**、NPU 串口的真相、hrtimer 把 RTT 从 4 ms 打到 0.6 ms、模块替换实录 |
| [systemd/](systemd/) | 设备上真正在跑的全部 unit 和脚本 |
| [ntb/](ntb/) | vNTB 驱动补丁（4 个 `.patch`），对照 pristine 源码生成 |
| [net/patches/](net/patches/) | mv88e6xxx 的两个上游 TCAM 修复 |
| [tools/](tools/) | 构建脚本（`build-npu-vntb.sh` / `build-x86-vntb.sh` / `build-npu-net.sh`）与控制台工具 |
| [modules/](modules/) | EIP197 / clkfix 等早期实验模块 |
| [reference/](reference/) | 设备树 DTS、内核 config、U-Boot/env 镜像、脱敏后的完整信息 dump |

## 关键事实速查

| | |
|---|---|
| 型号 | Sophos XGS 87，DMI `XGS 87r1`，板卡 rev 07，BIOS 1906 |
| NPU SoC | Marvell CN9130（AP807-B0 + CP115-A0），4×A72@1.6G，2 GB DDR |
| NPU 系统 | **Debian 13.6，内核 6.12.117+deb13-arm64**（原先的 Buildroot 4.14 已被替换，档案见 docs/04） |
| 交换机 | Marvell 88E6193X，MDIO addr 2，product 193，11 口 |
| x86 | AMD RX-216TD（2C），2×2 GB DDR4-1600，16 GB eMMC，Debian 13.6 / 6.12.94 |
| x86 PCIe | NPU 端点 `1957:0809`（vNTB function），Gen3 ×2 |
| NPU console | x86 `/dev/ttyS2`，host 侧 **57600**；`root` / `openwrt123` |
| x86 console | RJ45 / micro-USB 二选一，同一个 ttyS0，**115200** |
| 存储 | NPU：4 MB SPI NOR（U-Boot+env）+ 7.28 GiB eMMC；x86：16 GB eMMC |
| MAC | 面板口由 U-Boot env 里 1 个基址衍生 9 个连续地址（docs/06） |

## 免责声明

- 数据是实机采集，可能因批次/固件版本不同而变化；关键结论都标了"实测"。
- 不含 Sophos 专有二进制；`reference/npu-mtd0-uboot.bin.gz` 是 GPLv2 的 U-Boot 镜像，可自由分发。
- 拆机/改固件有风险，自行承担。
