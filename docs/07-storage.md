# 07 · 存储布局

> 🏷 **状态（2026-11-23 复核）**：✅ **实测**：`mtd0` = u-boot 4032 KiB、`mtd1` = env 64 KiB；eMMC 7.3 GiB 分 4 区（p1 500M/p2 1.5G 根/p3 1.5G/p4 100M persistent）。

## 7.1 NPU：SPI NOR（4 MiB）

```
dev:    size   erasesize  name
mtd0: 003f0000 00001000 "U-Boot"       4032 KiB
mtd1: 00010000 00001000 "U-Boot-env"     64 KiB
```

- 芯片：**mx25l3205d**（4 MiB，256 B page，4 KiB erase）。
- `BootROM` 从 **SPI NOR flash 0** 启动 → **这里刷坏了机器就变砖**，
  只能靠 x86 的 MCP2210（USB-SPI）或者板载 JTAG 救。
- 救砖工具：[tools/on-x86/mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py)。在 x86 上通过
  `/dev/hidraw0` 操作；先 **hold NPU**（GP0/GP3/GP5）把总线切给 MCP2210，GP0 作 CS；
  先整片双遍 dump + manifest，`env-write` 只写 64 KiB env，失败自动回滚。
  详见 [23-mcp2210-spi-nor.md](23-mcp2210-spi-nor.md)。
- 备份：`reference/mtd/npu-mtd0-uboot.bin.gz`（解压 4 128 768 字节，已验证）。

```sh
# 在 NPU 上备份
dd if=/dev/mtd0 bs=65536 | gzip -1 > /tmp/uboot.gz
dd if=/dev/mtd1 bs=65536 | gzip -1 > /tmp/uboot-env.gz

# 恢复（危险，务必确认 U-Boot 镜像来源）
flashcp -v uboot.bin /dev/mtd0
```

## 7.2 NPU：eMMC（7.28 GiB）

```
mmcblk0       7 634 944 KiB   H8G4a2 (HS200)
├─p1    512 000 KiB (500 MiB)   最老的 Sophos 槽（文件日期 2021-06）
├─p2  1 560 576 KiB (1.5 GiB)   **当前 root = Debian 13（LABEL=debian）**
├─p3  1 560 576 KiB (1.5 GiB)   原厂 Sophos 系统（2024-04），回滚用
└─p4    102 400 KiB (100 MiB)   /persistent（VPD，1.6 MB 已用）
mmcblk0boot0/1   4 MiB each      eMMC 硬件分区（全 0）
```

实测（`lsblk` + `blkid`）：

```
mmcblk0p1  500M ext4                 UUID=ca3eca63-…（原厂冷备）
mmcblk0p2  1.5G ext4  /              LABEL=debian, UUID=eb94c11c-…
mmcblk0p3  1.5G ext4                 UUID=10bcb1fd-…（原厂 4.14，可用 bootcmd_emmc3 引导）
mmcblk0p4  100M ext4  /persistent    UUID=d5d1be41-…
```

`/` 用了 673 MB / 1.5 GB（50%），够用但别往根分区堆容器镜像。

三个槽的 `/boot` 里都有原厂的 `Image` + `cn9130-senao-xgs.dtb`：

| 槽 | 原厂 kernel Image | dtb | 其它 |
|---|---|---|---|
| p1 | 20 720 128 B (2021-06) | 30 323 B | — |
| p2 | 20 656 640 B (2023-10) | 30 323 B | `xgsdt1-boot-env.bin`, `xgsdt1-boot.img` |
| p3 | 20 656 640 B (2024-04) | 30 323 B | 同上 |

> 三份原厂 dtb 大小完全一样，基本可以认为是同一份设备树。
> p2 上现在多了一套 Debian 的 `/boot`（`Image` / `initrd` / `config` / `System.map` / 我们的 dtb）。

### 实际怎么用的

- **Debian 的目标槽是 p2**，正常时 `bootcmd` = `run bootcmd_deb10g` → `bootcmd_deb`（读 `mmc 0:2`）。
- **p1 / p3 保持原厂**，随时可以用 U-Boot 回滚：`setenv bootcmd 'run bootcmd_emmc3'; saveenv`。
- **2026-11-25 当前（已修复）**：p2 一直是好的，只是缺 `/boot/initrd.img` 这个名字；补上硬链接后
  `bootcmd=run bootcmd_deb10g` 实测能进 Debian 13.8。芯片上的 `bootcmd` 已经是 `run bootcmd_deb10g`，
  `mbrfix` 已从启动路径移除（见 [03](03-boot-chain.md) §3.6）。
- **2026-11-25 又补了三处**：p2 的 ext4 元数据损坏（inode checksum）用 `fsck.mode=force` 修好，
  状态从 `clean with errors` 变成 `clean`（fsck 需要 initramfs 里有 e2fsck，见
  [14](14-npu-debian-hardware.md) §14.13）；一个被写坏的 dpkg 文件清单
  （`libseccomp2:arm64.list`）用 `--reinstall` 重新生成；DNS 从"完全不可用"修到 DHCP 下发即用。
- 没有做 A/B：p3 就是天然的"另一套"，但它跑的是 4.14 原厂系统，不是同一代 Debian。

## 7.3 x86：eMMC（16 GB）

```
mmcblk0      14.7 GiB
├─p1    64 MiB  vfat  /boot/efi   (GPT, ESP)
└─p2  14.2 GiB  ext4  /
```

- 根分区 14.2 GB，当前 Debian 只用了很小一部分。
- `/etc/fstab` 用 UUID 挂载。
- 参考机型的 XGS 107 是 **64 GB SATA + MBR**，本机是 **16 GB eMMC + GPT/EFI**，
  两者装系统的方式完全不同。

## 7.4 镜像与备份清单

| 对象 | 大小 | 备份方式 | 本仓库 / 本地 |
|---|---|---|---|
| NPU U-Boot (mtd0) | 4 MiB | `dd` + gzip | `reference/mtd/npu-mtd0-uboot.bin.gz` |
| NPU env (mtd1) | 64 KiB | `dd` + gzip | `reference/mtd/npu-mtd1-env.bin.gz` |
| **NPU 整盘 eMMC** | **7.28 GiB** | `dd` 全盘 | 本地 `npu/backup/mmcblk0-full.img`（SHA256 记录在 [12](12-measurements.md)）**不可再生** |
| **NPU p2 根分区（救砖镜像）** | **1 524 MiB** | `dd` 到 `/dev/mmcblk0p2` | 本地 `p2.img`（仓库不放二进制），SHA256 `383cb3aee23d325a25340e8e045f81c7b667252a3a0cbf3ae203708afeafb6e4`（2026-11-24 修补后） |
| x86 ESP | 64 MiB | `dd` 或 `rsync` | 未备份（重装即可再生） |

### 救砖镜像 `p2.img` 的实测要点（2026-11-24）

- **裸 ext4，没有分区表**：`s_blocks_count` 390 144 × 4 KiB = 1 598 029 824 B = 文件长度，
  卷标 `root`，`e2fsck -fn` 干净 → 直接 `dd if=p2.img of=/dev/mmcblk0p2 bs=4M`。
- `/boot` 里是 `Image`（36 MiB）、`board.dtb`、`initrd.img-6.12.117+deb13-arm64`（34 MiB）。
- ⚠️ **`bootcmd_deb` 要的文件名原本不存在**：它 `ext4load mmc 0:2 … /boot/initrd.img`，
  而镜像里只有带版本号的 `initrd.img-6.12.117+deb13-arm64` → 用 **hardlink** 补齐这个名字
  （同一 inode，不占额外空间，U-Boot `ext4load` 读得到）。补完用 `e2fsck -fy` 修了 debugfs 没更新的
  链接计数，再 `e2fsck -fn` 确认干净。
  **这份 PC 上的 `p2.img` 一直没有刷回机器**；机器上的 p2 是 2026-11-25 现场补的硬链接，
  补完即可启动（[03](03-boot-chain.md) §3.6）。新的 `debian-npu.tar` 已经由
  [image/setup.sh](../image/setup.sh) 自动补齐这两个名字。
- initrd 是**未压缩 cpio**（1705 项），含 `ext4.ko`、`jbd2.ko`、`sdhci-of-dwcmshc.ko`、`mvpp2.ko`、
  `dsa_core.ko`，**但没有 `mv88e6xxx.ko`**（交换机驱动只在 rootfs 的 `/lib/modules` 里）。
  所以 initramfs 阶段只有 `mvpp2` 的口能通；root 挂上、systemd 加载 rootfs 里的 `mv88e6xxx` 之后
  才是九口全通。`CONFIG_EXT4_FS=m`/`MMC_SDHCI_OF_DWCMSHC=m`，所以**不能扔掉 initrd 直接 `booti Image - dtb`**。
- 地址不冲突：`kernel_addr_r` 0x07000000 + 36 MiB、`fdt_addr_r` 0x06f00000、`ramdisk_addr_r` 0x0a000000 + 34 MiB。

### 完整备份命令（在 NPU 上）

```sh
# 整盘（最省事，也是我们做过的）
dd if=/dev/mmcblk0 bs=4M | gzip -1 > /tmp/mmcblk0.img.gz

# 只要 Debian 根分区
dd if=/dev/mmcblk0p2 bs=4M | gzip -1 > /tmp/p2.img.gz

# 只要文件（不含虚拟文件系统）
tar -C / --exclude=./proc --exclude=./sys --exclude=./dev \
        --exclude=./tmp --exclude=./run -czf - . > /tmp/rootfs.tar.gz
```

### 恢复注意

- eMMC 的 `boot0/boot1` 全 0，说明 **不是** 从 eMMC 硬件分区启动，靠 SPI NOR 的 U-Boot。
- 换 eMMC 后要先分好 p1-p4，再把 Debian 解到 p2，最后确认 `bootcmd`（见 [03](03-boot-chain.md) §3.3）。
- **p4 是出厂的 VPD**（机型/序列号/MAC 基址），任何时候都不要格式化它。

## 7.5 容量规划

| 用途 | 建议 |
|---|---|
| Debian 根（p2） | 1.5 GB，实测用了 673 MB；够，但别往这里堆镜像 |
| 大文件（备份、容器镜像） | 放 **x86 的 16 GB eMMC**，别占 NPU 的 1.5 GB |
| 日志 | NPU 侧用 journald 限流（eMMC 写入寿命）；要长期留就把 `/var/log` 转去 x86 |

## 7.6 镜像该写到哪儿：分区 vs 整盘（2026-11-24 的教训）

这条规则是拿一台真砖机换来的，写在这里防止再犯。

**两类镜像，两个目标，不能混：**

| 镜像 | LBA 0 有什么 | 只能写到 |
|---|---|---|
| `p2.img`、`debian-npu.tar` 解出来的 rootfs —— **裸文件系统** | ext4 超级块 | **分区** `/dev/mmcblk0p2` |
| `debian-usb.img`、`xgs87-x86.img` —— **整盘镜像**（GPT/MBR + 分区） | `55AA` + 分区表 | **整盘** `/dev/sdX` / `/dev/mmcblk0` |

**2026-11-24 那次"砖机"到底发生了什么**：U-Boot 报过一次

```
** No partition table - mmc 0 **
```

当时被判断成"`p2.img` 被 `dd` 到了整盘、MBR 被 ext4 超级块覆盖"，于是往 env 里塞了
`mbrfix` 去写回 MBR。**2026-11-25 现场复查把那个判断推翻了**：

| 检查 | 结果 |
|---|---|
| LBA0 偏移 `0x438` 的 ext4 magic | `0000` —— 没有 ext4 超级块（真被裸 ext4 盖过就一定会有，`mbrfix` 只写前 512 字节清不掉） |
| LBA0 签名 / 分区项 | `0xFAE598E3`（原厂磁盘签名）+ 4 个分区项 + `55AA` |
| p1 / p2 / p3 / p4 | 全部能挂载/启动：p1 旧 Sophos 槽、p2 Debian 13.8、p3 原厂、p4 VPD |

⇒ **eMMC 的数据从来没有丢过**，`mbrfix` 写回的其实就是原来那份 MBR。p2 起不来的真正原因是
`bootcmd_deb` 要的 `/boot/initrd.img` 这个名字不存在（只有 `initrd.img-6.12.117+deb13-arm64`）。
修法和证据见 [03](03-boot-chain.md) §3.6。

**这条规则本身仍然成立**（它是从那次误判里留下来的守卫，防的是真出事）：裸文件系统只能写
**分区节点**，整盘镜像才写整盘。真写错了，p1 和 p2 开头会一起没掉，那时才需要重刷。

**脚本里现有的守卫**（都在 `installer/payload/lib.sh`）：

- `is_partition` / `is_whole_disk` —— 按设备名判断，两者互斥
  （`/dev/mmcblk0boot0` 这种 eMMC 硬件分区两个都拒绝）。
- `require_partition <dev> [说明]` —— 写裸文件系统镜像前必须调用，给整盘名直接退出。
- `require_whole_disk <dev> [说明]` —— 写整盘镜像前必须调用，给分区名直接退出。

调用点：`install-npu.sh`、`npu-sshdd.sh`、`npu-disk.sh`（`require_partition`）；
`install-x86.sh`、`backup-x86.sh`（`require_whole_disk`）。

反过来也一样：`npu-sshdd.sh SRC=<镜像>` 直接写现成的裸 ext4 镜像时会检查
**`LBA0` 不能以 `55AA` 结尾** —— 整盘镜像写进分区等于把分区表塞到 p2 里，
p2 反而还是坏的。实测：`p2.img`（`LBA0`=`0000`、ext4 magic `53ef`）通过，
1 MiB 的整盘测试镜像被拒。

`install-x86.sh` 还有两道额外的闸：

1. 写之前从镜像解压流里读 LBA 0 的最后两字节，**必须是 `55aa`** —— 裸文件系统镜像
   在这一步就被拒绝，不会等到 dd 跑完才发现。
2. 写完 `sfdisk -d "$TARGET"` 回读分区表，读不出来就告警，别急着重启。

目标盘的选择也不再"挑最后一块"：显式 `TARGET=/dev/sdX` 或 `$1` 优先，否则列出所有
候选；**候选多于一块就退出**，不会静默选错。当前根所在的盘永远被排除。

`usbstore.sh` 另有一条：备份分区**只切可移动盘**（`/sys/block/<disk>/removable == 1`）。
它随镜像装进了内置盘，没有这条检查的话，装好之后的系统每次开机都会在自己的 eMMC
尾部切一块出来当备份区。

**验证方法**（不用真写盘）：

```sh
# 镜像到底是整盘还是裸文件系统？
dd if=<镜像> bs=512 count=1 | tail -c 2 | od -An -tx1     # 55aa = 整盘镜像

# 守卫本身（给出设备名即可，不碰硬件）
. installer/payload/lib.sh
require_partition   /dev/mmcblk0p2 && echo ok     # ok
require_partition   /dev/mmcblk0   && echo 不该到这  # 退出 1 并说明原因
require_whole_disk  /dev/sda       && echo ok     # ok
```
