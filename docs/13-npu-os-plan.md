# 13 · NPU 换系统方案（Debian vs OpenWrt）与 10G SFP 落地路径

> ✅ **方案已落地**：NPU 现在跑的就是 Debian 13 + 6.12.117，SFP 跑 10G。
> 本文保留取舍过程（OpenWrt vs Debian、DTS 那一行改动、回滚路径）；实施细节与踩坑见 [14](14-npu-debian-hardware.md) 和 [20](20-lan-over-vntb.md)。

本文回答两个问题：

1. NPU 要不要/能不能装 Debian？
2. SFP+ 口怎么才能真正跑在 10 Gbps 并且转发？

结论先给：

> **先刷 OpenWrt（参考项目已经把这台机器的活干完了），验证交换机和 10G；
> Debian 可行，但需要自己提供 DTB，属于第二阶段。**

---

## 13.1 为什么不是"随便装个 Debian"

NPU 的网络不是"一个普通网卡"，而是：

```
mvpp2 eth0 ──10G KR/R──> 88E6193X port 0 ──> port 1..4 (RJ45, 内置 PHY)
                                          └─> port 9 (SFP/SFP+)
```

要让这 8 个前面板口工作，内核里必须有：

| 组件 | 作用 | 缺了会怎样 |
|---|---|---|
| `mvpp2` | CN9130 的 MAC | 没有 eth0 |
| `mvebu comphy` | 把 lane 4 配成 SFI0 10.3125G | eth0 无载波 |
| `mv88e6xxx` (DSA) | 交换机驱动：VLAN、port state、SerDes、SFP | 只有 U-Boot 配好的静态二层，重启即失，且**没法做 10G** |
| `phylink` + `sfp` | SFP 模块识别/限速/协商 | SFP 口不可用 |

厂商 4.14 内核**一个交换机驱动都没有**——二层完全是 U-Boot 写死的寄存器状态
（见 [12.12](12-measurements.md#1212)）。这正是"装了 Debian 也还是不通"的根因。

## 13.2 mainline 支持到什么程度（已查源码确认）

| 项目 | 状态 |
|---|---|
| 板级 DTS `cn9130-sophos-xgs107w.dts` | ✅ 已上游（commit `0f72e965`，2026-09 进 mvebu，**v6.18 里还没有**） |
| 88E6193X 探测（无 PTP 修正） | ✅ 已上游（`6b491af01aa5`，2026-09-24 进 net.git，已回灌 stable） |
| `mv88e6393x_phylink_get_caps` 声明 5G/10G | ✅ 存在 |
| `pcs-639x.c` 支持 `PHY_INTERFACE_MODE_10GBASER` | ✅ 存在 |
| `MV88E6393X_PORT_STS_CMODE_10GBASER` | ✅ `0x000d`（与我们手写值一致） |
| 板级 DTS 里 SFP 口的 `phy-mode` | ⚠️ `1000base-x`（只声明 1G） |

所以 10G 差的**不是驱动能力，而是一行 DTS**（见 13.4）。

## 13.3 两条路的取舍

| | OpenWrt（推荐先做） | Debian |
|---|---|---|
| 内核 | 6.18/7.x + 参考项目补丁，**现成** | 13 (6.12) **没有这板 DT**；forky/sid (7.x) 才有 |
| 交换机/10G | `kmod-dsa-mv88e6xxx` 直接可用 | 需要自备 DTB（见 13.5） |
| 体积/内存 | 小，2 GB 内存很宽裕 | 需要裁剪，但可用 |
| 软件生态 | 路由功能齐全，装其他软件麻烦 | apt 全生态，适合当通用服务器 |
| 上手成本 | 低（参考项目有 install 脚本） | 中高（debootstrap + 自编 DTB + env） |

**建议**：先用 OpenWrt 把"交换机 + 10G + LED + 端口"全部验证通过（也是最好的回归基线），
再把 Debian 当作"换根文件系统"的第二阶段——因为那时 DTB 和内核参数都已经调对了。

## 13.4 让 SFP+ 跑 10 Gbps：唯一必需的改动

mainline/参考项目的 DTS 里，SFP 口是这么写的：

```dts
port@9 {
	reg = <9>;
	label = "sfp";
	phy-mode = "1000base-x";    /* ← 只声明到 1G */
	managed = "in-band-status";
	sfp = <&sfp>;
};
```

改成：

```dts
port@9 {
	reg = <9>;
	label = "sfp";
	phy-mode = "10gbase-r";     /* 10GBASE-SR 模块 */
	managed = "in-band-status";
	sfp = <&sfp>;
};
```

改完由 `phylink` + `mv88e6393x_port_set_cmode()` 负责：

1. 写 `PORT_STATUS.CMODE = 0xD`（10GBASE-R）
2. `mv88e6393x_serdes_get_lane()` → lane 9 上电/复位
3. `pcs-639x.c` 把 PCS 配成 10GBASE-R
4. 端口 MAC 速率/流控同步

**这四步缺一不可**——我们手写第 1 步（+ 一个通用 PCS 复位）的结果就是：
链路 `0x0F4D`（10 Gbps UP）但整机不转发（见 [12.11](12-measurements.md#1211)）。

> 也可以用更"标准"的写法：把 `phy-mode`/`managed` 都删掉，只留 `sfp = <&sfp>`，
> 让 phylink 完全按模块能力协商（10GBASE-SR → 10gbase-r，SFP 1G → 1000base-x）。
> 两种写法哪个更稳需要在机器上实测。

## 13.5 Debian 落地步骤（第二阶段）

前置：eMMC 已整盘备份（[12.13](12-measurements.md#1213)），SPI `mtd0` 绝不写。

1. **准备 DTB**（Debian 6.12 没有）：从 mainline 源码单独编译，或在 OpenWrt 构建里取：

   ```sh
   git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
   cd linux
   make ARCH=arm64 marvell/cn9130-sophos-xgs107w.dtb
   # 得到 arch/arm64/boot/dts/marvell/cn9130-sophos-xgs107w.dtb
   ```

2. **准备 rootfs**：在 x86 的 Debian 上 debootstrap，然后在 NPU 上解包进 p1：

   ```sh
   # x86
   sudo debootstrap --arch=arm64 --foreign trixie /srv/npu-root http://deb.debian.org/debian
   sudo tar -C /srv/npu-root -czf /srv/npu-root.tgz .
   scp /srv/npu-root.tgz root@192.168.1.1:/tmp/     # 走当前能通的 1G LAN 口
   # NPU（原厂系统）
   mkdir -p /mnt/p1 && mount /dev/mmcblk0p1 /mnt/p1
   tar -C /mnt/p1 -xzf /tmp/npu-root.tgz
   ```

3. **放内核与 DTB**：U-Boot 的 `booti` 需要**未压缩**的 `Image`：

   ```sh
   # 在 x86 上取 Debian arm64 内核
   apt download linux-image-arm64        # 解开得到 vmlinuz-*
   # vmlinuz 是自解压/压缩镜像，必须解成裸 Image
   /usr/lib/linux-kbuild-*/scripts/extract-vmlinux vmlinuz-6.x-arm64 > Image
   ```

   放到 `/mnt/p1/boot/Image` 与 `/mnt/p1/boot/cn9130-sophos-xgs107w.dtb`。

4. **设置启动变量**（U-Boot，不改 SPI 内容，只改 env）：

   ```
   setenv bootargs_owrt 'console=ttyS0,115200 root=/dev/mmcblk0p1 rootwait rw'
   setenv bootcmd_owrt 'ext4load mmc 0:1 ${kernel_addr_r} /boot/Image; ext4load mmc 0:1 ${fdt_addr_r} /boot/cn9130-sophos-xgs107w.dtb; setenv bootargs ${bootargs_owrt}; booti ${kernel_addr_r} - ${fdt_addr_r}'
   setenv bootcmd_stock 'run bootcmd_emmc3'
   setenv bootcmd 'run bootcmd_owrt'
   saveenv
   ```

   ⚠️ 原厂 `bootcmd_emmcN` 里有 `run fdt_set_partno`，它会 `fdt set /usfp_rh ...` ——
   mainline DTB 里没有这个节点，**必须去掉**，否则 `fdt set` 报错。
   ⚠️ Debian 的 `vmlinuz` 不是裸 `Image`，必须用 `extract-vmlinux` 转换。

5. **回滚**：U-Boot 里 `run bootcmd_stock`（等价 `run bootcmd_emmc3`）随时回原厂 p3。

## 13.6 风险清单

| 风险 | 说明 / 缓解 |
|---|---|
| SPI U-Boot 被写坏 | 只有 `saveenv` 会动 mtd1；mtd0 我们从不写。已有 mtd0/mtd1 备份 |
| NPU 起不来 | U-Boot 3 秒 autoboot，串口可打断；`bootcmd_stock` 回原厂 |
| 2 GB 内存 | Debian 最小安装约 300 MB 常驻，够用；不要装桌面 |
| eMMC 寿命 | rootfs 开 `noatime`、日志限流；p1 只有 500 MB，注意空间 |
| 散热 | 无风扇机型，持续 10G 转发需关注 SoC 温度（`tsen`/thermal zone） |
| PCIe EP | Debian 侧不启用 endpoint，就不会卡在 "Waiting for host driver handshake" |
| x86 重启会复位 NPU + 交换机 | 已实测；跑 Debian 时注意别让 x86 无人值守重启 |

## 13.7 下一步（按顺序）

1. 用参考项目的 OpenWrt 镜像刷 p1，确认：交换机 probe、4 个 RJ45 口、SFP 口、LED、`10gbase-r` 改动。
2. 在 OpenWrt 上把 SFP 口 `phy-mode` 改成 `10gbase-r` 实测 10G 转发（**这是本项目最关键的一次验证**）。
3. 验证通过后，再决定是否换 Debian（步骤见 13.5），DTB 直接复用第 2 步验证过的那份。
