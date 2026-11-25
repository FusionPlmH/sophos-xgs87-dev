# 📦 档案：改造前的机器、原始测量、走过的弯路

> **这不是现状**，读现状去 [README 的文档表](../README.md)。这里只留"以后可能还要查"的
> 事实：原厂 p3 槽里有什么、几个仍然有效的原始数字、以及两个被推翻的方案里值得记住的
> 东西。完整的原始记录在 git 历史里（2026-11-25 之前的 `docs/04`、`12`、`13`、`17`）。

## A.1 原厂 p3 槽（Buildroot 4.14）：回滚时要对照的东西

p3 是原厂系统，**没动过**，是目前唯一能直接启动的备份；`bootcmd` 指回它即可：
`fw_setenv bootcmd 'run bootcmd_emmc3'`（用 `fw_setenv`，别反复 `saveenv`，那颗 NOR 的
env 区不先擦除）。

| 项 | 原厂值 |
|---|---|
| 内核 | Linux 4.14.207（Marvell BSP），`bootargs_emmc3` 里带 `cpuidle.off=1 isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3` |
| init | BusyBox init → `/etc/init.d/S91xgsstartup` → `xgsps/` 下一串脚本（`xgs-platform-init`、`xgs-ports`、`xgs-sff`、`xgs-mvl6193-init`） |
| 数据面 | CPSS + `pcinet`（x86 ↔ NPU 的私有通道），管理面 SFOS 在 x86 上 |
| 机型库 | `/opt/sophos`（机型数据库）、`/usr/marvell`（SDK 用户态）、`/persistent`（p4，出厂 VPD） |
| 工具 | `devmem`、`flashcp/flash_erase`、`fw_printenv/fw_setenv`、`xz/gzip/tar`、`wget`、`mvswitch` |
| 账号 | `root` / `openwrt1234` |
| 我们改过的 | `bootcmd`（指向 p2 的 Debian）、`bootargs_deb`、`/etc/fw_env.config`（**这个文件是我们加的**，没有它 `fw_setenv` 直接报 `Cannot initialize environment`） |

`/persistent`（p4）是出厂数据（机型、序列号、MAC 基址），**任何时候都不要格式化**。

## A.2 2026-11-22 原始测量里仍然有效的数字

| 事实 | 值 | 现在还用来做什么 |
|---|---|---|
| SFP+ 实测速率 | **10000 Mb/s**（10GBASE-SR 模块） | [07](07-npu-system.md) §7.2 的依据 |
| SFP 与铜口 1G 共存 | 可以，互不影响 | §7.6 |
| 交换机 MDIO | addr **2**，product id **193**（88E6193X） | [04](04-switch.md) |
| 面板 PHY 地址 | p1..p4 = PHY 1..4；SFP 走 port9 的 SerDes | §4.2 |
| MAC 方案 | VPD 里 7 个连续地址：p1–p4 = base+0..3，sfp = base+4，end0/ethaddr = base+5 | §4.6 |
| SPI NOR | `mtd0` = u-boot **4032 KiB**，`mtd1` = env **64 KiB**（`/dev/mtd1 0x0 0x10000 0x1000`） | [05](05-storage.md) §5.1 |
| eMMC | 7.28 GiB，4 区：p1 500M（原厂备槽）/p2 1.5G（Debian 根）/p3 1.5G（原厂系统）/p4 100M（VPD） | §5.2 |
| PCIe 端点能力的坑 | 设备同时声明 MSI 和 MSI-X（16 向量），但**只能用 MSI**：选 MSI-X 得到空向量表 + IOMMU `IO_PAGE_FAULT address=0x0` | [09](09-vntb.md) §9.3 |
| EP 的内存窗口 | 必须 **1 MiB 对齐**（iATU 忽略目标地址低 20 位）；节点里**不能**写 `dma-coherent` | 同上 |
| NPU 串口 | 0x3E8 / irq 5（标准 COM2），**115200**；老 `image/` 内核因 16550 报 2x 分频才要 host 57600（该内核已退役） | [10](10-console.md) §10.3 |
| 板载 RTC | **坏的**，靠 `fake-hwclock` + NTP | [07](07-npu-system.md) §7.11 |

## A.3 四个真实的 NTB bug（2026-11-23，为"共享管理口"那版踩出来的）

那版方案（p8 当 x86/NPU 共用管理口 + `192.168.100.0/24`）**已退役**，而且本机面板根本
没引出 p8。但这四个 bug 是 vNTB 真正的坑，修法一直有效：

| # | 现象 | 真因 | 修法 |
|---|---|---|---|
| 1 | 主机能看到端点，`ntb_hw_epf` 也绑上了，但 `eth0` 永远没有 carrier | 端点侧把 `db_count` 写成 1，主机按 4 个门铃去算 BAR 布局，两边对不上 | `xgs-vntb.sh` 固定 `db_count=4`、`spad_count=128`、`num_mws=1`、`mw1=0x100000` |
| 2 | 链路一断，主机 panic（`panic_on_oops` 后 30 s 自重启） | 端点不在时，从它 BAR 里读出的 `spad_offset` / `db_entry_size` 是 `0xffffffff`，直接被当成偏移写内存 | 补丁给 `ntb_epf_spad_read/write`、`ntb_epf_peer_db_set` 全部加 `~0U` 与越界判据（[ntb/0101](../ntb/0101-ntb_hw_epf.patch)） |
| 3 | 选 MSI-X 时端点中断一次都不来 | DW 核声明 MSI-X 但只发 MSI | 主机侧 `pci_alloc_irq_vectors(..., PCI_IRQ_MSI)`，只看 MSI |
| 4 | 端点重编程 BAR 后，主机还拿着旧地址 | `remove`+`rescan` 才重读 BAR 尺寸，普通 rescan 不会 | `xgs-ntb-up.sh` 的 stale 检测 + 一次重枚举（[09](09-vntb.md) §9.3.5） |

## A.4 为什么最后是 Debian，而不是 OpenWrt

早期设想过"NPU 跑 OpenWrt 当路由"。否决理由（结论在 [16](16-remaining-work.md) §16.0）：

| | Debian（已选） | OpenWrt（未走） |
|---|---|---|
| 交换机 / 10G | 发行版 `mv88e6xxx` + `mvpp2`，9 个 netdev 全在跑 | 有 kmod，但版本被发行版绑死 |
| 生态 | apt 全量（k3s / Docker / Python / 工具链） | opkg，装通用软件麻烦 |
| x86 侧 | 本来就要当通用服务器 | OpenWrt x86 只能当路由 |
| 维护 | 两台同一套 apt / systemd / 内核 | 两套体系 |
| 代价 | 自己出 DTB、自己编模块（已完成） | 上手便宜，长期被框架限制 |

两个参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
[os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）现在只用于**查硬件事实**和
**取 DTS 片段**，不再作为系统方案。
