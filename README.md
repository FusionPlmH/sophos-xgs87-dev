# Sophos XGS 87 — 硬件档案、架构设计与改造记录

> 现场实测记录。所有数据来自一台 **Sophos XGS 87**（非无线版）实机，目前**两边都已换成 Debian 13**：
> x86 跑通用计算，NPU 跑数据面。本仓库记录把它改造成可自由使用设备（服务节点 / 路由器 / 自研固件）的全过程。
>
> 与 Sophos 官方无关。仓库内不含任何原厂二进制，只包含实测数据、设备树、补丁和脚本。

## 现在是什么状态

```
x86  192.168.0.50   Debian 13.6 / 6.12.94   ──┐  家里内网（DHCP，走 vNTB VLAN 31）
NPU  192.168.0.66   Debian 13.6 / 6.12.117  ──┘
x86 ↔ NPU 管理段 192.168.100.2 ↔ .1            VLAN 100，RTT 0.6 ms
前面板 p8 → br-mgmt access 口                  插笔记本可同时访问 .1 / .2
```

**2026-11-23 在现机上逐项复核过**，标记含义：✅ 实测通过 ｜ 📦 原厂档案 ｜ ❌ 不可用 ｜ ⚠️ 未验证。

| 驱动 / 功能 | 状态 | 证据 |
|---|---|---|
| NPU Debian 13 自启（eMMC） | ✅ | `/` 在 `mmcblk0p2`，4 分区，见 docs/07 |
| `mvpp2`（10G MAC，`end0`） | ✅ | 自编译模块，`AGGR_TXQ_SIZE=512` |
| `mv88e6xxx` + DSA（9 个口） | ✅ | `p1–p8` + `sfp` 全部为 netdev；TCAM 补丁已打（docs/20 §20.9） |
| 面板 1G / SFP+ 10G | ✅ | `ethtool`：`p1/p4` 1000 Mb/s、`sfp` **10000 Mb/s** |
| `spi_orion` + MTD | ✅ | `mtd0` u-boot 4032 KiB、`mtd1` env 64 KiB、`fw_printenv` 可读 |
| `crypto_safexcel`（EIP197） | ✅ | `/proc/crypto` 1318 行，safexcel 注册 rfc4106/4309/4543 —— **能跑但比 CPU 慢，默认不用**（docs/16） |
| thermal（6 zone）+ 9 hwmon | ✅ | `ap-ic`/`ap-cpu0..3`/`cp0-ic` 49–51 ℃；`sfp` + 8 个 PHY 温度 |
| PWM / GPIO | ✅ | `pwmchip0-2`、3 个 `gpiochip`（base 0/32/64） |
| **cpufreq** | ❌ | 没有 `/sys/devices/system/cpu/cpu0/cpufreq`；`ap-cpu-clk` 段错误未修，降频/调频不可用 |
| 风扇 | ✅有 / ❌不可控 | 整机一颗，上电即转；无 SuperIO、无 ACPI 风扇、DT 无 `fan` 节点（docs/19 §19.6） |
| x86 ↔ NPU vNTB | ✅ | 单流 1.2 Gbit/s、RTT 0.6 ms（docs/20 §20.5） |
| x86 借道拿家里内网地址 | ✅ | `192.168.0.50`，VLAN 31 透传 |
| 一条链路跑管理段 + LAN | ✅ | VLAN 100 / VLAN 31（docs/20） |
| 关机钩子（主机先与对端道别） | ✅ | `xgs-ntb-stop.service` |
| NPU 单独重启 → x86 自动恢复 | ✅ | `xgs-ntb-watch` 做完整重置（rmmod → remove/rescan → 重建），实测 90 s 自己回来、x86 不重启（docs/20 §20.10） |
| x86 时间同步 | ✅ | `systemd-timesyncd`，`timedatectl` = synchronized |
| **内核/系统可以随便升级** | ✅ | 两台都用**发行版内核 + DKMS**：x86 实测 6.12.94 → **6.12.118** 自动重编，NPU 用发行版内核（`kernel/npu`），自编内核已退役 |
| SFP 自适应模块 | ✅ | 端口只声明 `1000base-x` 基线 + `sfp` phandle，phylink 按插入的模块切换（实测 10G 模块被自动提到 `10gbase-r`） |
| NPU 掉链 lockup 取证 | ✅ | **netconsole 双目标**（NPU → x86 管理 VLAN + PC 的 `br-lan`），死前 printk 落在对方磁盘上；`ramoops` 已证伪（每次复位都 DDR scrub，见 docs/20 §20.8） |
| NPU 内核 `CONFIG_PSTORE_CONSOLE` | ✅ | 已重编并上线（37.7 → 44.3 MB），console 后端 `[ramoops-1] enabled`，但受上一条限制用不上 |
| 完整开机无牵连重启 | ❌ | x86 断 PCIe 链路 → NPU 被 `PERST#` 复位。软件手段已穷尽（停 EP、关 panic、看门狗 inactive 都试过），要改 ATF 才有意义（docs/20 §20.8） |
| LED / PCA9555 极性 | ⚠️ | 沿用原厂记录，未逐一验证（docs/06） |

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

> 上表是**现网这台**（手工装的旧系统）。[image/](image/) 构建出来的系统不一样：只有 `admin`
> （`P@ssw0rd`，`sudo` 需要密码），`root` 已 `passwd -l` 锁定、sshd 里 `PermitRootLogin no`，
> 所以新镜像上 `ssh root@…` 是进不去的。

⚠️ `/dev/ttyS2` **同一时刻只能有一个读者**，两个 `cat` 会把字节流切成乱码。
现成工具：NPU 控制台用 [tools/on-x86/npu-console.sh](tools/on-x86/npu-console.sh)（**在 x86 上跑**），
x86 自己的控制台用 [tools/on-pc/x86-console.py](tools/on-pc/x86-console.py)（**在 PC 上跑**）。

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
| [docs/09-remaining-work.md](docs/09-remaining-work.md) | **改造笔记：还剩什么没做、缺什么**（唯一的待办清单） |
| [docs/10-ideas.md](docs/10-ideas.md) | **这台机器独特设计的最佳用法**（持续更新） |
| [docs/12-measurements.md](docs/12-measurements.md) | 实测记录：LED、SFP 10G、原厂交换机初始化序列、PCIe、GPIO、备份 |
| [docs/13-npu-os-plan.md](docs/13-npu-os-plan.md) | 为什么选 Debian（不是 OpenWrt）、DTS 一行让 SFP 跑 10G、当时的安装步骤 |
| [docs/14-npu-debian-hardware.md](docs/14-npu-debian-hardware.md) | Debian 下硬件补齐：SFP+ 10G、SPI NOR/MTD、`fw_printenv`、EIP197 |
| [docs/15-performance.md](docs/15-performance.md) | 性能标定：CPU 1.6 GHz、转发、加密、可采纳项清单 |
| [docs/16-eip197-activated.md](docs/16-eip197-activated.md) | **EIP197 激活成功**、正确性验证、CPU 成本实测、为何最终不启用 |
| [docs/17-x86-npu-shared-mgmt.md](docs/17-x86-npu-shared-mgmt.md) | **x86 与 NPU 共享 p8 管理口**：阶段 1 桥接、阶段 2 NTB 的四个真实 bug |
| [docs/18-same-soc-platforms.md](docs/18-same-soc-platforms.md) | **同族平台调研**：上游 Sophos DTS、88E6193X 的 PTP/TCAM、mvpp2 旋钮、EP 的 `dbi2` 陷阱 |
| [docs/19-module-vs-kernel-rebuild.md](docs/19-module-vs-kernel-rebuild.md) | 模块 vs 重编内核、换模块的失联风险、风扇归属 |
| [docs/20-lan-over-vntb.md](docs/20-lan-over-vntb.md) | **一条 PCIe 链路跑两套网络**、NPU 串口的真相、hrtimer 把 RTT 从 4 ms 打到 0.6 ms、模块替换实录 |
| [docs/21-reproduce.md](docs/21-reproduce.md) | **换一台机器怎么把两套系统重新做出来**：构建步骤、占位符约定、发布前检查 |
| [systemd/](systemd/) | 设备上真正在跑的全部 unit 和脚本，按 **`npu/` / `x86/`** 分目录 |
| [kernel/npu/](kernel/npu/) | NPU 侧 out-of-tree 模块（DKMS 包：vNTB、`spi-orion`、`clkfix`） |
| [kernel/x86/](kernel/x86/) | x86 侧 out-of-tree 模块（DKMS 包：`ntb_*` 四个） |
| [image/](image/) | **最小化 Debian 构建**：`mmdebstrap` 脚本、软件包清单、x86 磁盘镜像、GitHub Actions |
| [installer/](installer/) | 维护 U 盘：把 `debian-x86.img.zst` / `debian-npu.tar.zst` 写回机器的菜单脚本 |
| [.github/workflows/](.github/workflows/) | CI：`arm64` / `amd64` 分开构建 rootfs |
| [ntb/](ntb/) | vNTB 驱动补丁（4 个 `.patch`），对照 pristine 源码生成 |
| [net/patches/](net/patches/) | mv88e6xxx 的两个上游 TCAM 修复 |
| [tools/](tools/) | 脚本按**运行位置**分目录：`build/`（PC 上交叉编译）、`on-npu/`、`on-x86/`、`on-pc/` |
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
| NPU console | x86 `/dev/ttyS2`，host 侧 **57600**；现网 `root` / `openwrt123`，`image/` 产出的是 `admin` / `P@ssw0rd` |
| x86 console | RJ45 / micro-USB 二选一，同一个 ttyS0，**115200** |
| 存储 | NPU：4 MB SPI NOR（U-Boot+env）+ 7.28 GiB eMMC；x86：16 GB eMMC |
| MAC | 面板口由 U-Boot env 里 1 个基址衍生 9 个连续地址（docs/06） |

## 免责声明

- 数据是实机采集，可能因批次/固件版本不同而变化；关键结论都标了"实测"。
- 不含 Sophos 专有二进制；`reference/npu-mtd0-uboot.bin.gz` 是 GPLv2 的 U-Boot 镜像，可自由分发。
- 拆机/改固件有风险，自行承担。
