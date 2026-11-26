# 03 构建

镜像不是手工拼的，**CI 就是权威**：`.github/workflows/image.yml`，只能手动触发。

```sh
gh workflow run image.yml -f target=all -f variant=lean     # 或者 Actions 页面点
```

| 输入 | 取值 | 说明 |
|---|---|---|
| `target` | `all` / `x86` / `npu` / `usb` | 默认 all |
| `variant` | `full` / `lean` / `base` | **发布用 `lean`** |
| `size` | 默认 `auto` | x86 盘片大小；auto = rootfs + 5% + 256 MiB + 128 MiB ESP |

## 三个 job 各干什么

| job | runner | 做的事 | 产物 |
|---|---|---|---|
| `x86` | `ubuntu-24.04` | `image/build.sh --arch amd64` → `image/mkdisk.sh`（GPT + GRUB ESP）→ zstd | `out/debian-x86.img.zst`、`out/xgs87-x86-lean.tar.zst` |
| `npu` | `ubuntu-24.04-arm` | `tools/build/build-dtb.sh` → `image/build.sh --arch arm64 --dtb …` | `out/debian-npu.tar.zst`、`out/cn9130-sophos-xgs87w-sfp10g.dtb` |
| `usb` | `ubuntu-24.04` | `tools/build/build-rescue.sh`（急救包）→ `installer/mkusb.sh`（拼 U 盘） | `out/xgs87-rescue.tar.zst`、`out/debian-usb.img.zst` |
| `release` | — | 发/更新三个 Release，正文用 `image/release-{x86,npu,usb}.md` | tag：`debian-x86`、`debian-npu`、`debian-usb` |

**不用 qemu、不交叉编译**：每个 rootfs 都在自己架构的原生 runner 上 `mmdebstrap` 一次。
`trixie` 的 Release 签名要新的 `debian-archive-keyring`，CI 里那一步就是为它。

## image/build.sh

```sh
sudo ./image/build.sh --arch arm64 --variant lean \
     --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb --out out/debian-npu.tar.zst
```

- `mmdebstrap --variant=minbase` + `image/packages-common.list` + `image/packages-{x86,npu}.list`，
  顺手排掉 `/usr/share/{doc,man,locale,i18n}`（省 ~100 MB）。
- 把 `image/overlay/{common,<side>}`、`systemd/`、`kernel/`、`board/` 塞进 `/opt/xgs87/`，
  然后 chroot 跑 `image/setup.sh <side> <variant>` 装 unit、建 `/boot/Image`+`initrd.img`、
  生成 ssh host key、`growroot`、给 journal 封顶。
- 变体：`full` 带 dkms + 编译器（能自己重建模块）；`lean` 把模块编译一次后把编译器 purge 掉
  （发布用的就是它，代价是内核被 hold）；`base` 只有骨架，模块到机器上再 `kernel/*/install.sh`。
- 产出的 tar 是**整份根文件系统**（解包就是 `/`），打进 `p2` 或 U 盘 root 都行。

## U 盘和急救包

```sh
sudo ./tools/build/build-rescue.sh --npu out/debian-npu.tar.zst --out out/xgs87-rescue.tar.zst
sudo ./installer/mkusb.sh --x86 out/debian-x86.img.zst --npu out/debian-npu.tar.zst \
     --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb --rescue out/xgs87-rescue.tar.zst \
     --out out/debian-usb.img
```

急救包现在有两条路，默认第一条：

| 做法 | 包大小 | 串口推完 | 说明 |
|---|---|---|---|
| **自编精简内核** | **2.1 MB** | ~3.6 分钟 | 驱动全编进内核，initramfs 里只有一个裁剪过的 busybox（`board/rescue-kernel.config` + `board/busybox-rescue.config`） |
| Debian 内核 + 挑模块 | ~10.9 MB | ~19 分钟 | `Image.lzma`(9.8 MB) + `initramfs.xz`(0.47 MB) + DTB |

```sh
# 默认：自编内核（不需要 debian-npu.tar.zst）
./tools/build/build-rescue-busybox.sh                                   # → out/busybox-rescue
./tools/build/build-rescue-kernel.sh --src /path/linux-6.12 --out out/rescue-kernel
./tools/build/build-rescue.sh --kernel out/rescue-kernel --out out/xgs87-rescue.tar.zst
```

`build-rescue-busybox.sh` 少了也能构建 —— `build-rescue.sh` 会退回 Debian 的
`busybox-static`（功能一样够，initramfs 白胖 0.4 MB）。

走 Debian 内核那条路时**两条硬要求，少一条就起不来**（都是实测踩过的）：

1. initramfs 里必须有 `/bin/sh` 符号链接 —— `/init` 第一行是 `#!/bin/sh`，没有它内核
   exec 失败、一路退到 `/sbin/init`，最后 `No working init found`（日志里连 `Run /init` 都没有）。
2. 模块要成**依赖闭包**：MDIO 那层必须在 `mvmdio` 之前；`bridge` 要 `llc`+`stp`；
   `dsa_core` 要 `selftests`+`hsr`；eMMC 要 `sdhci-xenon-driver`。`build-rescue.sh` 现在用
   `depmod` 的闭包，不是手写清单。

## 精简内核：怎么裁、裁到多少（2026-11-25/26 真机验证）

15.9 MB 里 86% 是内核，所以只有裁内核才有意义。同一份 37.7 MB 的 Debian Image 做对照：

| 做法 | 结果 | 说明 |
|---|---|---|
| ~~defconfig 打底再关几十项~~ | **40.6 MB / gz 12.3 MB —— 反而更大** | arm64 defconfig 自带 2800 多个 `=y`，关 35 个等于没关。已试过，别再来 |
| **`tinyconfig` + `board/rescue-kernel.config`** | **Image 5.36 MB ｜ gz 2.14 MB ｜ lzma 1.63 MB** | 小 7 倍。**这条是现行默认** |
| 内核 `--kernel-fmt lzma` | 2.14 → **1.63 MB** | 已进默认。**`unzip` 不认 lzma，要用 `lzmadec`**（见下） |
| initramfs 换 `xz -9e` | 1.04 → **0.47 MB** | 内核 `CONFIG_RD_XZ=y` 自己解，U-Boot 不参与。已进默认 |
| 自编裁剪 busybox | 1.98 → **1.19 MB**（gz 1.03 → 0.60） | `board/busybox-rescue.config`，52 个 applet。已进默认 |
| 换 musl 交叉工具链编 busybox | 还能再省 ~0.4 MB | 现在 1.19 MB 里六成是静态 glibc。没做 |

合起来：**急救包 3.1 → 2.1 MB，串口 6 → 3.6 分钟**（YMODEM 实测 9.8 KiB/s）。

两个压缩格式的关键事实（都是真机撞出来的，别再猜）：

* **U-Boot 的 `unzip` 只认 gzip。** 这个固件（2019.10-10.22.03）喂 lzma 给 `unzip`
  只会打 `Error: Bad gzipped data`（`file_formats[]` 里没有 lzma，SPI NOR 备份里
  grep 到的 "lzma" 字样其实来自 `bootm` 的 image-type 表和 `lzmadec` 命令）。
  lzma 要用 **`lzmadec <srcaddr> <dstaddr>`**：它按 LZMA-alone 头里的 8 字节长度
  决定输出多少，所以**绝不能**把坏掉的 lzma 喂给它。
* **initramfs 不需要 U-Boot 解。** 内核有 `CONFIG_RD_GZIP/LZMA/XZ`，`booti` 的
  initrd 大小给压缩后的大小就行 —— 省掉一块 0x20000000 缓冲和一次内存拷贝。


`tinyconfig` = `allnoconfig` + `EXPERT`，也就是**所有 `default y` 的东西全被关掉**。
踩过的四个坑（每一个都表现为"QEMU 里能跑、真机上死"或"死得没声音"）：

1. **全部 CPU errata 被关掉**，包括 `CONFIG_ARM64_ERRATUM_843419`（Cortex-A53/A72 的
   ADRP 链接期修正）。QEMU 的 `-cpu max` 没这个 erratum，所以 QEMU 永远测不出来；
   真机上内核在打印任何东西之前就死了，`pstore` 也是空的。
2. **`CONFIG_BLOCK` 被关掉**（它带 `if EXPERT`），于是 `CONFIG_MMC_BLOCK` 这个符号
   根本不存在 —— 一个 `/dev/mmcblk0` 都不会有。
3. **`CONFIG_PSTORE` 被静默丢弃**：`fs/pstore/Kconfig` 在 `if MISC_FILESYSTEMS` 里面。
   `merge_config.sh` 不会报错，`build-rescue-kernel.sh` 现在逐行核对并打印丢弃项。
4. **交换机内部 PHY 退化成 "Generic PHY"**：缺少 `CONFIG_MARVELL_PHY` 时 88E6393 的口起不来。

顺带：`kernel/npu/` 的 `ntb_*` 模块**编不进** vanilla 内核（依赖 Marvell 厂商 API
`ntb_get_dma_dev`），所以精简内核里没有 PCI/vNTB —— 急救走面板口，本来也不需要它。

## 其他构建脚本

| 脚本 | 干什么 |
|---|---|
| `tools/build/build-dtb.sh` | 编译 `board/*.dts` → `out/cn9130-…dtb` |
| `tools/build/build-rescue-kernel.sh` | 用 `board/rescue-kernel.config` 做急救内核 |
| `tools/build/build-{npu,x86}-vntb.sh`、`build-npu-net.sh` | 单独编译 vNTB / mv88e6xxx 模块 |
| `tools/build/build-npu-kernel.sh` | NPU 内核相关的一次性操作 |
| `tools/check-docs.py`、`tools/check-hygiene.sh` | 文档链接 / 仓库卫生检查（提交前跑一下） |
