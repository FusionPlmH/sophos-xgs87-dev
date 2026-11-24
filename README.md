# Sophos XGS 87 — 硬件档案、架构设计与改造记录

> 现场实测记录。所有数据来自一台 **Sophos XGS 87**（非无线版）实机，目标是**两边都跑 Debian 13**：
> x86 跑通用计算，NPU 跑数据面。本仓库记录把它改造成可自由使用设备（服务节点 / 路由器 / 自研固件）的全过程。
>
> **2026-11-25 现场状态**：x86 的 Debian 13 正常；NPU 从 eMMC p2 启动 Debian 13.8，
> `br-wan` 拿到 DHCP、`br-lan` 是 `10.234.56.1/24`，面板 p1/p2 都 link up。
> 2026-11-24 那次"砖机"已经复盘：**eMMC 数据从来没有丢过**，p2 只是缺 `/boot/initrd.img`
> 这个名字（补硬链接即可启动）；当时的 `No partition table`、env 被写坏、3.2 s 复位循环
> 各有别的解释，证据链见 docs/03 §3.6，结论见 docs/09 §9.1。
> p3 原厂系统完好，SPI NOR / env 已校验、`mtd0` 未损坏。不要因为"看到 U-Boot 复位"就继续刷
> SPI NOR —— 那次复位循环真正的来源是 x86 侧的 remove/rescan 循环，已从脚本里移除。
>
> 与 Sophos 官方无关。仓库内不含任何原厂二进制，只包含实测数据、设备树、补丁和脚本。

## 现在是什么状态

```
x86  eth0.100  DHCP（上游）  ──┐  面板 2/WAN → br-wan（VLAN 100）
x86  eth0.200  10.234.56.2/24 ┘  └─ 面板 1/LAN → br-lan（VLAN 200，NPU = .1）
NPU  br-lan 静态 10.234.56.1/24，不下发 DHCP；br-wan DHCP，管理也走这条路
```

`br-lan` 默认**只有 p1**，`p3`/`p4`/`p8` 不并入任何桥；LAN 段没有 DHCP 服务，下游要自己配
`10.234.56.x/24`。`br-wan` 才跑 DHCP。想改端口归属就改 NPU 上的 `/etc/xgs87/net.conf`。

**2026-11-23 逐项实测，2026-11-25 复核当前状态**，标记含义：✅ 实测通过 ｜ 📦 原厂档案 ｜ ❌ 不可用 ｜ ⚠️ 未验证。

| 驱动 / 功能 | 状态 | 证据 |
|---|---|---|
| NPU Debian 13 自启（eMMC p2） | ✅ | 2026-11-25 实测：`bootcmd=run bootcmd_deb10g` → Debian 13.8，`br-wan` DHCP、`br-lan` 10.234.56.1/24（docs/03 §3.6） |
| `mvpp2`（10G MAC，`end0`） | ✅ | 发行版模块；`AGGR_TXQ_SIZE=512` 自编译版是可选优化，镜像默认不用（docs/19） |
| `mv88e6xxx` + DSA（9 个 netdev） | ✅ | 发行版模块；TCAM 两个上游补丁是可选加固。`p1–p8` + `sfp`，本机面板只引出 p1–p4 + sfp（docs/06、docs/19） |
| 面板 1G / SFP+ 10G | ✅ | `ethtool`：`p1/p4` 1000 Mb/s、`sfp` **10000 Mb/s** |
| `spi_orion` + MTD | ✅ | `mtd0` u-boot 4032 KiB、`mtd1` env 64 KiB、`fw_printenv` 可读 |
| `crypto_safexcel`（EIP197） | ⛔ | 镜像不带 `ifpp.bin` 微码，probe 直接 `-ENOENT`；已在 `/etc/modprobe.d/xgs87-blacklist.conf` 里屏蔽。即使有固件 PE 也起不来，而单核 AES-256-GCM 已有 ~8.5 Gbps（docs/14 §14.4） |
| thermal（6 zone）+ 9 hwmon | ✅ | `ap-ic`/`ap-cpu0..3`/`cp0-ic` 51–54 ℃（2026-11-25 实测，随负载浮动）；`sfp` + 8 个 PHY 温度 |
| PWM / GPIO | ✅ | `pwmchip0-2`、3 个 `gpiochip`（base 0/32/64） |
| **cpufreq** | ❌ | 没有 `/sys/devices/system/cpu/cpu0/cpufreq`：DT 的 `cpu@0` 没有 `operating-points-v2`，`cpufreq-dt` 无表可读（docs/14 §14.13） |
| 风扇 | ✅有 / ❌不可控 | 整机一颗，上电即转；无 SuperIO、无 ACPI 风扇、DT 无 `fan` 节点（docs/19 §19.6） |
| x86 ↔ NPU vNTB | ✅ | 单流 1.2 Gbit/s、RTT 0.6 ms（docs/20 §20.5） |
| x86 借道拿地址 | ✅ | `eth0.100` 走 WAN（DHCP）、`eth0.200` 走 LAN（静态 `10.234.56.2/24`） |
| 一条链路跑 WAN + LAN | ✅ | VLAN 100（WAN）/ VLAN 200（LAN），两段在交换芯片上真隔离（docs/20 §20.1） |
| 面板口分 WAN / LAN 且可配 | ✅ | `/etc/xgs87/net.conf`：`2/WAN` = `p2` → `br-wan`（VLAN 100，DHCP），`1/LAN` = `p1` → `br-lan`（VLAN 200，静态 `10.234.56.1/24`，不发 DHCP）（docs/20 §20.2） |
| LAN 能真的上网（转发 + NAT） | ✅ | `xgs-nat.service`：`ip_forward=1` + `inet xgs87` 表里 `br-lan → br-wan` masquerade（docs/20 §20.2.1） |
| 维护 U 盘不用预留 payload 分区 | ✅ | 安装包放 root 的 `/opt/xgs87/payload`；U 盘剩余空间第一次开机自动切成 exfat（`XGS87BAK`，挂 `/media/xgs87-bak`）放备份 |
| 关机钩子（主机先与对端道别） | ✅ | `xgs-ntb-stop.service` |
| NPU 单独重启 → x86 恢复 | ⚠️ | **默认不自动碰 PCIe**（remove/rescan 会复位正在启动的 NPU）。NPU 起来后手动 `sudo xgs-ntb-up.sh --force-rescan`；`AUTO_RECOVER=1` 可在 5 分钟后自动试一次（docs/20 §20.10） |
| x86 时间同步 | ✅ | `systemd-timesyncd`，`timedatectl` = synchronized |
| **内核/系统可以随便升级** | ✅ | 两台都用**发行版内核 + DKMS**：x86 实测 6.12.94 → **6.12.118** 自动重编，NPU 用发行版内核（`kernel/npu`），自编内核已退役。想做小镜像可以用 `--variant lean`（工具链编完就删，内核需 hold） |
| SFP 自适应模块 | ✅ | 端口只声明 `1000base-x` 基线 + `sfp` phandle，phylink 按插入的模块切换（实测 10G 模块被自动提到 `10gbase-r`） |
| NPU 掉链 lockup 取证 | ✅ | **netconsole 双目标**（NPU → x86 管理 VLAN + PC 的 `br-lan`），死前 printk 落在对方磁盘上；`ramoops` 已证伪（每次复位都 DDR scrub，见 docs/20 §20.8） |
| NPU 内核 `CONFIG_PSTORE_CONSOLE` | 📦 | 自编内核已退役（37.7 → 44.3 MB 的那版）；发行版内核不带它，而且 ramoops 被 DDR scrub 证伪，净收益为零 |
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
                            │  port1-4 → 面板 1/LAN 2/WAN 3 4 (1G) │
                            │  port9   → 面板 F1 SFP (10G)        │
                            │  port0   → CN9130 (10G XFI)         │
                            └────────────────────────────────────┘
```

- **面板上 4 个 RJ45 + 1 个 SFP 全部挂在 NPU 的交换机上**，x86 自己没有网口 ——
  它通过 vNTB 上的 VLAN 借道 NPU 上网。面板 `2/WAN` 单独划成 `br-wan` 接上游（DHCP）；
  `1/LAN` 是 `br-lan`（静态 `10.234.56.1/24`，**不跑 DHCP 服务**）；`3`、`4`、`8` 默认不并入任何桥。
- x86 与 NPU 之间只有 **PCIe 端点** + **一路内部 UART**。
- 原厂设计里 x86 做控制面/应用（Wi-Fi、管理界面），NPU 做数据面（交换、转发）。
  两家参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
  [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）都是围绕这个分工做的。

## 怎么进去

| 目标 | 方法 |
|---|---|
| x86（`image/` 系统） | `ssh admin@10.234.56.2`（LAN），或 `eth0.100` 从上游拿到的 DHCP 地址；旧手工系统曾用 `192.168.0.50` |
| NPU（`image/` 系统） | `ssh admin@10.234.56.1`（LAN）或 `192.168.31.x`（WAN 侧 DHCP）；旧手工系统曾用 `192.168.0.66` |
| x86 控制台 | COM5（RJ45）或 micro-USB，**115200**；`admin` / `P@ssw0rd` |
| NPU 控制台 | **x86 的 `/dev/ttyS2`，host 侧 115200**（老 `image/` 内核是 2x 分频，才需要 host 57600） |

> [image/](image/) 构建出来的系统只有 `admin`（`P@ssw0rd`，`sudo` 需要密码），`root` 已
> `passwd -l` 锁定、sshd 里 `PermitRootLogin no`，所以新镜像上 `ssh root@…` 是进不去的。
> p3 原厂系统仍是 `root` / `openwrt123`（只在从那槽启动时有效）。

⚠️ `/dev/ttyS2` **同一时刻只能有一个读者**，两个 `cat` 会把字节流切成乱码。
现成工具：NPU 控制台用 [tools/on-x86/npu-console.sh](tools/on-x86/npu-console.sh)（**在 x86 上跑**），
x86 自己的控制台用 [tools/on-pc/x86-console.py](tools/on-pc/x86-console.py)（**在 PC 上跑**）。
SPI NOR 救砖用 [tools/on-x86/mcp2210-nor.py](tools/on-x86/mcp2210-nor.py)（**在 x86 上跑**，见 [docs/23](docs/23-mcp2210-spi-nor.md)）。

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
| [docs/08-console-access.md](docs/08-console-access.md) | 进机方式与坑（115200 / 老内核 57600 的来龙去脉） |
| [docs/09-remaining-work.md](docs/09-remaining-work.md) | **改造笔记：还剩什么没做、缺什么**（唯一的待办清单） |
| [docs/12-measurements.md](docs/12-measurements.md) | 实测记录：LED、SFP 10G、原厂交换机初始化序列、PCIe、GPIO、备份 |
| [docs/13-npu-os-plan.md](docs/13-npu-os-plan.md) | 为什么选 Debian（不是 OpenWrt）、DTS 一行让 SFP 跑 10G、当时的安装步骤 |
| [docs/14-npu-debian-hardware.md](docs/14-npu-debian-hardware.md) | Debian 下硬件补齐：SFP+ 10G、SPI NOR/MTD、`fw_printenv`、EIP197 |
| [docs/17-x86-npu-shared-mgmt.md](docs/17-x86-npu-shared-mgmt.md) | **x86 与 NPU 共享 p8 管理口**：阶段 1 桥接、阶段 2 NTB 的四个真实 bug |
| [docs/19-module-vs-kernel-rebuild.md](docs/19-module-vs-kernel-rebuild.md) | 模块 vs 重编内核、换模块的失联风险、风扇归属 |
| [docs/20-lan-over-vntb.md](docs/20-lan-over-vntb.md) | **一条 PCIe 链路跑两套网络**、NPU 串口的真相、hrtimer 把 RTT 从 4 ms 打到 0.6 ms、模块替换实录 |
| [docs/21-reproduce.md](docs/21-reproduce.md) | **换一台机器怎么把两套系统重新做出来**：构建步骤、占位符约定、发布前检查 |
| [docs/22-from-sfos.md](docs/22-from-sfos.md) | **从原厂 SFOS 换成这套 Debian**：高级 shell、备份、维护 U 盘、没有 USB 启动时的退路 |
| [docs/23-mcp2210-spi-nor.md](docs/23-mcp2210-spi-nor.md) | **MCP2210 SPI NOR 救砖工具**：GP0/3/5 hold/release、GP0 CS、整片双遍 dump、只写 env、失败回滚 |
| [systemd/](systemd/) | 设备上真正在跑的全部 unit 和脚本，按 **`npu/` / `x86/`** 分目录 |
| [kernel/npu/](kernel/npu/) | NPU 侧 out-of-tree 模块（DKMS 包：vNTB、`spi-orion`、`clkfix`） |
| [kernel/x86/](kernel/x86/) | x86 侧 out-of-tree 模块（DKMS 包：`ntb_*` 四个） |
| [image/](image/) | **最小化 Debian 构建**：`mmdebstrap` 脚本、软件包清单、x86 磁盘镜像、GitHub Actions |
| [installer/](installer/) | 维护 U 盘：把 `debian-x86.img.zst` / `debian-npu.tar.zst` 写回机器的菜单脚本 |
| [.github/workflows/](.github/workflows/) | CI：一个 `image.yml`，手动触发，`target=x86/npu/usb/all` 选产物，各自跑在原生 runner 上 |
| [ntb/](ntb/) | vNTB 驱动补丁（4 个 `.patch`），对照 pristine 源码生成 |
| [net/patches/](net/patches/) | mv88e6xxx 的两个上游 TCAM 修复 |
| [tools/](tools/) | 脚本按**运行位置**分目录：`build/`（PC 上交叉编译）、`on-x86/`、`on-pc/` |
| [reference/](reference/) | 设备树 DTS、内核 config、U-Boot/env 镜像、脱敏后的完整信息 dump |

## 关键事实速查

| | |
|---|---|
| 型号 | Sophos XGS 87，DMI `XGS 87r1`，板卡 rev 07，BIOS 1906 |
| NPU SoC | Marvell CN9130（AP807-B0 + CP115-A0），4×A72@1.6G，2 GB DDR |
| NPU 系统 | p2 **Debian 13.8 / 6.12.117+deb13-arm64**（2026-11-25 实测启动）；p3 原厂 Buildroot 4.14 完好（档案见 docs/04） |
| 交换机 | Marvell 88E6193X，MDIO addr 2，product 193，11 口（本机面板 4×RJ45 + 1×SFP） |
| x86 | AMD RX-216TD（2C），2×2 GB DDR4-1600，16 GB eMMC，Debian 13.6；`lean` 镜像自带 **6.12.117** 且内核被 hold，`apt-mark unhold linux-image-amd64` 后可升（实机已升到 **6.12.118**，DKMS 自动重编） |
| x86 PCIe | NPU 端点 `1957:0809`（vNTB function），Gen3 ×2 |
| NPU console | x86 `/dev/ttyS2`，host 侧 **115200**（老 `image/` 内核才要 57600）；p3 原厂 `root` / `openwrt123`，`image/` 产出的是 `admin` / `P@ssw0rd` |
| x86 console | RJ45 / micro-USB 二选一，同一个 ttyS0，**115200** |
| 主机名 | x86 = **`xgs-debian-x86`**，NPU = **`xgs-debian-npu`**（`image/` 产出；p3 原厂仍是 `marvell`） |
| 存储 | NPU：4 MB SPI NOR（U-Boot+env）+ 7.28 GiB eMMC；x86：16 GB eMMC |
| MAC | VPD 的 7 个连续地址：p1–p4 = base+0..3，sfp = base+4，end0/ethaddr = base+5（docs/06 §6.6） |

## 免责声明

- 数据是实机采集，可能因批次/固件版本不同而变化；关键结论都标了"实测"。
- 不含 Sophos 专有二进制；`reference/mtd/npu-mtd0-uboot.bin.gz` 是 GPLv2 的 U-Boot 镜像，可自由分发。
- 拆机/改固件有风险，自行承担。
