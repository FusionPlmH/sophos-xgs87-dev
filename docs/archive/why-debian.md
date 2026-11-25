# 📦 档案：13 · NPU 换系统：为什么是 Debian，以及 SFP+ 怎么跑 10G

> 🏷 **状态（2026-11-23 复核）**：✅ **已落地** —— NPU 现在跑 Debian 13 + 6.12.117，SFP 实测 10G。
> 本文记录**当时的选择过程和 DTS 那一行改动**，实施细节见 [07](../07-npu-system.md)、[09](../09-vntb.md)。

本文回答两个问题：

1. NPU 装什么系统？
2. SFP+ 口怎么才能真正跑在 10 Gbps 并且转发？

结论先给：

> **装 Debian 13。OpenWrt 从头到尾没装过，也不打算装**
> （x86 侧同理，两个节点现在都是 Debian）。
> SFP+ 的 10G 只差 DTS 里 `phy-mode` 一行，已经验证。

---

## 13.1 为什么不是"随便装个 Debian"

NPU 的网络不是"一个普通网卡"，而是：

```
mvpp2 eth0 ──10G KR/R──> 88E6193X port 0 ──> port 1..4 (RJ45, 内置 PHY)
                                          └─> port 9 (SFP/SFP+)
```

要让这些前面板口工作，内核里必须有：

| 组件 | 作用 | 缺了会怎样 |
|---|---|---|
| `mvpp2` | CN9130 的 MAC | 没有 eth0 |
| `mvebu comphy` | 把 lane 4 配成 SFI0 10.3125G | eth0 无载波 |
| `mv88e6xxx` (DSA) | 交换机驱动：VLAN、port state、SerDes、SFP | 只有 U-Boot 配好的静态二层，重启即失，且**没法做 10G** |
| `phylink` + `sfp` | SFP 模块识别/限速/协商 | SFP 口不可用 |

原厂 4.14 内核**一个交换机驱动都没有**——二层完全是 U-Boot 写死的寄存器状态
（见 [12.12](../archive/measurements.md#1212)）。这正是"装了 Debian 也还是不通"的根因，
也是我们后来必须自己编 `mv88e6xxx` 的原因。

## 13.2 mainline 支持到什么程度（已查源码确认）

| 项目 | 状态 |
|---|---|
| 板级 DTS `cn9130-sophos-xgs107w.dts` | ✅ 已上游（commit `0f72e965`，2026-09 进 mvebu，**v6.18 里还没有**） |
| 88E6193X 探测（无 PTP 修正） | ✅ 已上游（`6b491af01aa5`，2026-09-24 进 net.git，已回灌 stable） |
| `mv88e6393x_phylink_get_caps` 声明 5G/10G | ✅ 存在 |
| `pcs-639x.c` 支持 `PHY_INTERFACE_MODE_10GBASER` | ✅ 存在 |
| `MV88E6393X_PORT_STS_CMODE_10GBASER` | ✅ `0x000d`（与我们手写值一致） |
| 板级 DTS 里 SFP 口的 `phy-mode` | ⚠️ `1000base-x`（只声明 1G，需要改） |

所以 10G 差的**不是驱动能力，而是一行 DTS**（见 13.4）。

## 13.3 为什么是 Debian 而不是 OpenWrt

| | Debian 13（**已选**） | OpenWrt（未采用） |
|---|---|---|
| 内核 | 13 (6.12) 没有这板 DT，需要自己出；**已完成** | 6.18/7.x + 参考项目补丁，现成 |
| 交换机/10G | 发行版 `mv88e6xxx` + `mvpp2`；TCAM/ring 补丁可选 | `kmod-dsa-mv88e6xxx` 直接可用 |
| 体积/内存 | 需要裁剪，但 2 GB 够（实测常驻 ~200 MB） | 小，2 GB 很宽裕 |
| 软件生态 | apt 全量，适合当通用服务器和路由 | opkg，装通用软件麻烦 |
| 与 x86 统一 | 两边同一套 apt / systemd / 内核维护 | 两套系统两套维护 |
| 当时状态（2026-11-23） | **已经在跑，9 个 netdev（面板 4 口 + SFP）+ 10G 实测通过**（2026-11-25 复测 p2 仍能启动） | 从未安装 |

代价（自备 DTB、自编模块）**已经付完了**，没有回头换 OpenWrt 的理由。
完整取舍见 [16 §16.0](../16-remaining-work.md)。

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

`managed = "in-band-status"` 加上后，由 `phylink` + `mv88e6393x_port_set_cmode()` 负责：

1. 写 `PORT_STATUS.CMODE = 0xD`（10GBASE-R）
2. `mv88e6393x_serdes_get_lane()` → lane 9 上电/复位
3. `pcs-639x.c` 把 PCS 配成 10GBASE-R
4. 端口 MAC 速率/流控同步

**这四步缺一不可**——早期我们手写第 1 步（+ 一个通用 PCS 复位）的结果是：
链路 `0x0F4D`（10 Gbps UP）但整机不转发（见 [12.11](../archive/measurements.md#1211)）。

> **最终采用自适应**（2026-11-23 实测）：端口保留 **`1000base-x` 基线** +
> `managed = "in-band-status"` + `sfp = <&sfp>`，由 phylink 按插入的模块切换接口模式。
> 10G 模块实测被自动提到 `10gbase-r`：
>
> ```
> mv88e6085 ...: configuring for inband/10gbase-r link mode
> mv88e6085 ...: switched to inband/10gbase-r link mode
> sfp: Link is Up - 10Gbps/Full - flow control off
> ```
>
> ⚠️ **不要干脆删掉 `phy-mode`**：`PHY_INTERFACE_MODE_NA` 会让校验退化成 `gmii`，
> 报 `validation of gmii ... failed: -EINVAL` → `failed to connect to PHY`，端口直接死。
> 1G / 2.5G 模块没实测（手上只有 10G 模块），但走的是同一条 phylink 路径。

> **不要**把 `phy-mode`/`managed` 都删掉：`managed` 是避免 DSA 回退到假 PHY 的关键；
> `phy-mode` 删掉会退化成 `gmii` 校验失败。现在用的是 `1000base-x` 基线 + `managed`，
> 10G/1G 模块都由 phylink 自适应。

## 13.5 我们实际怎么装的（Debian 落地记录）

前置：eMMC 已整盘备份（[12.13](../archive/measurements.md#1213)），SPI `mtd0` 绝不写。

1. **DTB**：从 mainline 源码单独编（Debian 6.12 的包里没有这板）：

   ```sh
   git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
   cd linux
   make ARCH=arm64 marvell/cn9130-sophos-xgs107w.dtb
   ```

   然后我们把它复制成 `board/cn9130-sophos-xgs87w-sfp10g.dts` 并按本机改
   （4 个面板口、`10gbase-r`、`ramoops`）。

2. **rootfs**：在 x86 上 `debootstrap --arch=arm64 --foreign trixie`，
   打包后解到 **p2**（不是 p1/p3，那两个留给原厂回滚）：

   ```sh
   # x86
   sudo debootstrap --arch=arm64 --foreign trixie /srv/npu-root http://deb.debian.org/debian
   sudo tar -C /srv/npu-root -czf /srv/npu-root.tgz .
   ```

3. **内核与 initrd**：U-Boot 的 `booti` 需要**未压缩**的 `Image`。

   ```sh
   apt download linux-image-arm64
   /usr/lib/linux-kbuild-*/scripts/extract-vmlinux vmlinuz-6.x-arm64 > Image
   ```

   ⚠️ Debian 官方 `vmlinuz` 开头是 `MZ`（EFI stub），但里面含 arm64 magic，
   `booti` 能识别 —— 本机 `/boot/Image` 与 `vmlinuz-6.12.117+deb13-arm64` md5 完全相同。

4. **U-Boot env**（只改 env，不动 SPI 内容）：

   ```
   setenv bootargs_deb 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw'
   setenv bootcmd_deb 'ext4load mmc 0:2 ${kernel_addr_r} /boot/Image; ext4load mmc 0:2 ${fdt_addr_r} /boot/cn9130-sophos-xgs87w-sfp10g.dtb; ext4load mmc 0:2 ${ramdisk_addr_r} /boot/initrd.img; setenv bootargs ${bootargs_deb}; booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}'
   setenv bootcmd_deb10g 'mvswitch 2 write 9 0 0xd; mvswitch 2 dev_write 9 4 f002 0x804d; mvswitch 2 dev_write 9 4 2000 0x9140; run bootcmd_deb'
   setenv bootcmd 'run bootcmd_deb10g'
   saveenv
   ```

   ⚠️ 原厂 `bootcmd_emmcN` 里有 `run fdt_set_partno`，它会 `fdt set /usfp_rh ...` ——
   mainline DTB 里没有这个节点，**必须去掉**，否则 `fdt set` 报错。现在的 `bootcmd_deb` 就不带它。

5. **回滚**：U-Boot 里 `run bootcmd_emmc3`（原厂 p3）随时回去。

## 13.6 风险清单

| 风险 | 说明 / 缓解 |
|---|---|
| SPI U-Boot 被写坏 | 只有 `saveenv` 会动 mtd1；mtd0 我们从不写。已有 mtd0/mtd1 备份 |
| NPU 起不来 | U-Boot 3 秒 autoboot，串口可打断；`bootcmd_emmc3` 回原厂 |
| 2 GB 内存 | Debian 最小安装实测常驻 ~200 MB，够用；不要装桌面 |
| eMMC 寿命 | rootfs 开 `noatime`、日志限流；p2 只有 1.5 GB，实测用了 50% |
| 散热 | 机箱**有**风扇但软件不可控（见 [15](../15-modules-and-kernel.md)）；10G 满速时留意 `tsen` |
| PCIe EP | 端口/链路异常时先看 `pci_epf_vntb`，见 [档案](../archive/p8-shared-mgmt.md) |
| x86 重启会复位 NPU | 已实测，是 `PERST#` 的硬件行为；见 [09 §11.1](../09-vntb.md) |

## 13.7 下一步

没有"换系统"的下一步了 —— 这一步做完了。剩下的待办统一在 [16](../16-remaining-work.md)。