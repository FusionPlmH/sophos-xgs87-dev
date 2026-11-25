# Sophos XGS 87(w) → 双 SoC 的 Debian 小机器

一台防火墙被改成通用机器：x86 那半边跑 Debian，Marvell CN9130（下面都叫 **NPU**）那半边
也跑 Debian，两边用机内 **PCIe（vNTB）** 和一条 **UART** 连起来。原厂的两个系统（p1、p3）
一个字节都不动，坏了自己还能退回去。

## 两块板子各是什么

| | x86 半边 | NPU 半边 |
|---|---|---|
| SoC | AMD 嵌入式（Family 15h） | Marvell **CN9130**（AP807 4×A72 + CP115） |
| 系统 | Debian 13 | Debian 13 |
| 自己的盘 | eMMC 14.7 GB（GPT + GRUB ESP） | eMMC 7.3 GB（p1–p4，见下） |
| 网口 | `eth0` = vNTB | `eth0` = vNTB；**面板 1/2/3/4 + SFP 都挂在 88E6193X 上** |
| 控制台 | `/dev/ttyS0` → 面板 RJ45 / PC 的 COM5，115200 | `/dev/ttyS2`（在 x86 上），115200 |

两边之间**只有两条线**：

```
x86 eth0         ══ PCIe / vNTB（VLAN 100 + 200，10 Gb/s）══→  NPU eth0
x86 /dev/ttyS2   ── UART 115200 ──→  NPU ttyS0
面板 1/2/3/4+SFP ── 88E6193X（DSA）──→  NPU 的 10G CPU 口（mvpp2）
```

**NPU 自己没有物理网口** —— 面板口全部要经过那颗交换机，所以"面板口能不能通"取决于 NPU
内核里的 `mv88e6xxx`（原厂 4.14 里没有）。


## 谁是谁

| | 系统 | 能不能写 |
|---|---|---|
| NPU `p1` | 原厂 Marvell rootfs，500 MiB | **永远不写** |
| NPU `p2` | **我们的 Debian 13**，1524 MiB | 唯一写入目标 |
| NPU `p3` | 原厂 Sophos 系统，1524 MiB | **永远不写**，它是救生艇 |
| NPU `p4` | VPD：序列号 + MAC，100 MiB | **永远不写** |
| x86 内置盘 | 我们的 Debian 13（GPT + GRUB ESP），整盘镜像 | 整盘重装 |

## 摸它

```sh
ssh admin@10.234.56.1            # 从 x86 进 NPU（LAN，VLAN 200）
ssh admin@10.234.56.2            # 从 NPU 回 x86
picocom -b 115200 /dev/ttyS2     # 在 x86 上开 NPU 的串口
```

两个系统都是 `admin` / `P@ssw0rd`（`sudo` 要密码）；p3 原厂是 `root` / `openwrt123`。

## 文档（就这 6 篇）

| | 讲什么 |
|---|---|
| [01 硬件](docs/01-hardware.md) | 两个 SoC、面板口和交换芯片、串口、eMMC/SPI、PCIe 走线 |
| [02 系统](docs/02-system.md) | 分区表与启动链、两边的 Debian、VLAN/vNTB、模块 |
| [03 构建](docs/03-build.md) | 镜像怎么来的、内核/DTB/模块、产物清单 |
| [04 装机](docs/04-install.md) | 维护 U 盘、刷 x86、刷 NPU 的两级阶梯 |
| [05 运维](docs/05-operations.md) | 服务清单、控制台、开机自检、已知故障 |
| [06 救砖](docs/06-rescue.md) | ssh+dd → 串口急救 + 面板口 → MCP2210 写 SPI NOR |

## 仓库

| 目录 | 内容 |
|---|---|
| `board/` | 板级 DTS（`cn9130-sophos-xgs87w-sfp10g.dts`）、急救内核 config |
| `kernel/{x86,npu}/` | 打进镜像的 DKMS 模块（vNTB 那一套 + `clkfix`），每边一个 `install.sh` |
| `ntb/`、`net/` | 内核补丁：`pci-epf-vntb`、`ntb_hw_epf`、`mv88e6xxx` 端口检查 |
| `systemd/{common,npu,x86}/` | 开机要跑的东西（脚本一律装到 `/usr/local/sbin/`） |
| `image/` | rootfs 构建（`build.sh`）、U 盘镜像（`mkdisk.sh`）、包清单、`overlay/` |
| `installer/` | 维护 U 盘的菜单 + 所有 payload（含急救 initramfs 和串口工具） |
| `tools/` | `build/` 构建脚本；`on-pc/`、`on-x86/` 是一次性小工具 |
| `out/` | 构建产物（不入库） |

## 一句话历史

原厂 SPX 一路（BIOS → x86 SFOS + NPU 加速）换成了：BIOS → GRUB → x86 Debian，和
U-Boot → p2 → NPU Debian。PCIe 上跑的是 Marvell 的 vNTB（`1957:0809`），内核模块和补丁
都在本仓库里，不用外部源码树也能重建镜像。
