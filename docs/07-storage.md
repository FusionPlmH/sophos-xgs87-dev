# 07 · 存储布局

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
├─p2  1 560 576 KiB (1.5 GiB)   Sophos 槽（2023-10）
├─p3  1 560 576 KiB (1.5 GiB)   当前 root（2024-04）← bootcmd 用的就是这个
└─p4    102 400 KiB (100 MiB)   /persistent（VPD，1.6 MB 已用）
mmcblk0boot0/1   4 MiB each      eMMC 硬件分区（全 0）
```

三个槽的 `/boot` 都有 `Image` + `cn9130-senao-xgs.dtb`：

| 槽 | kernel Image | dtb | 其它 |
|---|---|---|---|
| p1 | 20 720 128 B (2021-06) | 30 323 B | — |
| p2 | 20 656 640 B (2023-10) | 30 323 B | `xgsdt1-boot-env.bin`, `xgsdt1-boot.img` |
| p3 | 20 656 640 B (2024-04) | 30 323 B | 同上 |

> 三份 dtb 大小完全一样，基本可以认为是同一份设备树。

### 改造建议

- 把 OpenWrt 装到 **p1（500 MB）**，`bootcmd` 指向 `bootcmd_emmc1`，
  p2/p3 原厂系统留着当回退。
- 或者用一个槽做 **A/B 双系统**（原厂就是三个槽轮换升级的思路）。

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

| 对象 | 大小 | 备份方式 | 本仓库 |
|---|---|---|---|
| NPU U-Boot (mtd0) | 4 MiB | `dd` + gzip | `reference/mtd/npu-mtd0-uboot.bin.gz` |
| NPU env (mtd1) | 64 KiB | `dd` + gzip | `reference/mtd/npu-mtd1-env.bin.gz` |
| NPU rootfs (p3) | 278 MB 已用 | `tar czf` | 本地保存（未公开） |
| NPU p1/p2 | 500 MB / 1.5 GB | `dd` | 未备份（需要时再导） |
| NPU `/persistent` | 1.6 MB | `tar` | 已包含在 rootfs tar 里 |
| x86 ESP | 476 MB | `dd` 或 `rsync` | 未备份 |

### 完整备份命令（在 NPU 上）

```sh
# rootfs（不含虚拟文件系统）
tar -C / --exclude=./proc --exclude=./sys --exclude=./dev \
        --exclude=./tmp --exclude=./run -czf - . > /tmp/rootfs.tar.gz

# 整分区镜像（如果空间够）
dd if=/dev/mmcblk0p3 bs=4M | gzip -1 > /tmp/p3.img.gz
```

### 恢复注意

- eMMC 的 `boot0/boot1` 全 0，说明 **不是** 从 eMMC 硬件分区启动，靠 SPI NOR 的 U-Boot。
- 换 eMMC 后要先分好 p1-p4，再把 rootfs 解到 p3（或 p1），最后确认 `bootcmd`。

## 7.5 容量规划（做新系统时）

| 用途 | 建议 |
|---|---|
| OpenWrt 系统 | p1 500 MB 足够（原厂 rootfs 才用 278 MB） |
| 日志/容器数据 | 用 p4（100 MB）太小，建议在 NPU 上跑 tmpfs + 远端日志，或干脆放在 x86 的 16 GB eMMC |
| x86 服务 | 14 GB 够跑几个容器；注意 eMMC 写入寿命 |
