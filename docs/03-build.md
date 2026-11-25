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

急救包只有 ~15.9 MB：`Image.gz`(13.7 MB) + `initramfs.gz`(2.2 MB) + DTB。它小是因为
用户态只有一个静态 busybox，模块只挑了急救要用的那一圈（eMMC + 面板口 + vNTB）。
**两条硬要求，少一条就起不来**（都是实测踩过的）：

1. initramfs 里必须有 `/bin/sh` 符号链接 —— `/init` 第一行是 `#!/bin/sh`，没有它内核
   exec 失败、一路退到 `/sbin/init`，最后 `No working init found`（日志里连 `Run /init` 都没有）。
2. 模块要成**依赖闭包**：MDIO 那层必须在 `mvmdio` 之前；`bridge` 要 `llc`+`stp`；
   `dsa_core` 要 `selftests`+`hsr`；eMMC 要 `sdhci-xenon-driver`。`build-rescue.sh` 现在用
   `depmod` 的闭包，不是手写清单。

## 其他构建脚本

| 脚本 | 干什么 |
|---|---|
| `tools/build/build-dtb.sh` | 编译 `board/*.dts` → `out/cn9130-…dtb` |
| `tools/build/build-rescue-kernel.sh` | 用 `board/rescue-kernel.config` 做急救内核 |
| `tools/build/build-{npu,x86}-vntb.sh`、`build-npu-net.sh` | 单独编译 vNTB / mv88e6xxx 模块 |
| `tools/build/build-npu-kernel.sh` | NPU 内核相关的一次性操作 |
| `tools/check-docs.py`、`tools/check-hygiene.sh` | 文档链接 / 仓库卫生检查（提交前跑一下） |
