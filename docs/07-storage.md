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

- **Debian 装在 p2**，`bootcmd` = `run bootcmd_deb10g` → `bootcmd_deb`（读 `mmc 0:2`）。
- **p1 / p3 保持原厂**，随时可以用 U-Boot 回滚：`setenv bootcmd 'run bootcmd_emmc3'; saveenv`。
- 没有做 A/B：p3 就是天然的"另一套"，但它跑的是 4.14 原厂系统，不是同一代 Debian。

## 7.3 x86：eMMC（16 GB）

```
mmcblk0      14.7 GiB
├─p1   476 MiB  vfat  /boot/efi   (GPT, ESP)
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
| x86 ESP | 476 MB | `dd` 或 `rsync` | 未备份（重装即可再生） |

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
