# image/ — 最小化 Debian 构建

两台机器都用 **通用内核 + 发行版模块 + DKMS**，所以镜像里没有任何自编内核，
系统更新不需要重新构建镜像。

```
image/build.sh       mmdebstrap 构建 rootfs（本机或 GitHub Actions）
image/setup.sh       在 chroot 里跑：装 unit、装 DKMS 模块、enable 服务
image/mkdisk.sh      把 x86 的 rootfs 变成可启动 GPT 镜像（ESP + GRUB EFI）
image/packages-*.list 软件包清单（common / x86 / npu）
image/overlay/      直接覆盖到 rootfs 根的文件（目前只有 NPU 的两个 boot 钩子）
```

## 本机构建

```sh
sudo ./image/build.sh --arch arm64              # NPU，含工具链和 DKMS 模块
sudo ./image/build.sh --arch amd64              # x86
sudo ./image/build.sh --arch amd64 --variant base   # 只要骨架（~224 MB）
```

- `--variant full`（默认）：额外装 `dkms` + `build-essential` + `linux-headers-*`，
  构建时就把 `kernel/<side>/` 的模块编好装上。**以后内核升级会自动重编**，代价约 500 MB。
- `--variant base`：不装编译器、不带模块。根分区小的时候用，之后再跑一次
  `kernel/<side>/install.sh`（它会自己装工具链）。

产物是 `out/xgs87-<side>-<variant>.tar.zst`。

## x86：变成可启动镜像

```sh
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst --out out/xgs87-x86.img --size 8G
```

GPT + 476 MiB ESP(FAT32) + ext4 root，`grub-install --removable`（这块 BIOS 只认
`\EFI\BOOT\BOOTX64.EFI`），并把 GRUB 超时压到 2 秒（否则 `recordfail` 会白等 30 秒）。

## NPU：怎么装

NPU 没有 ESP，是 U-Boot 从 eMMC 的一个分区里 `ext4load` 内核和 DTB，所以：

```sh
# 在正在跑的 NPU 上
mkfs.ext4 -L xgsroot /dev/mmcblk0pX
mount /dev/mmcblk0pX /mnt
zstd -dc xgs87-npu-full.tar.zst | tar -xpf - -C /mnt
# fstab、/boot/Image、DTB 见 docs/07 与 docs/03
```

⚠️ 根分区 1.5 GB 装不下 `full`（工具链约 500 MB）。要么用 `--variant base`，
要么把根分区做到 ≥3 GB。

## GitHub Actions

两个**独立**的 workflow，各自跑在原生架构的 runner 上（不做交叉编译、不用 qemu）：

| workflow | runner | 产物 |
|---|---|---|
| [image-x86.yml](../.github/workflows/image-x86.yml) | `ubuntu-24.04`（amd64） | `xgs87-x86-*.img.zst`（可启动镜像）+ `xgs87-x86-*.tar.zst` |
| [image-npu.yml](../.github/workflows/image-npu.yml) | `ubuntu-24.04-arm`（aarch64，公开仓库免费） | `xgs87-npu-*.tar.zst` + `cn9130-*.dtb` |

push 到 `main`（且改到 `image/` `kernel/` `systemd/` `board/`）或者手动 `workflow_dispatch` 触发。

**产物自动发 Release**：两个 workflow 都写到同一个 tag `images-<UTC 日期>-<短 sha>`，
谁先跑完谁先建 release，后跑完的用 `gh release upload --clobber` 补上自己的文件
（创建和上传都有 5 次重试，避免并发撞车）。

```
images-20261123-aa03d9e
├── xgs87-x86-full.img.zst
├── xgs87-x86-full.tar.zst
├── xgs87-npu-full.tar.zst
└── cn9130-sophos-xgs87w-sfp10g-aa03d9e.dtb
```

⚠️ arm64 runner 在**私有**仓库要付费计划；本仓库是公开的，`ubuntu-24.04-arm` 免费。
