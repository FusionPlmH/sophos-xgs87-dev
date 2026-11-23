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
sudo ./image/build.sh --arch amd64 --variant base   # 只要骨架（~240 MB）
```

- `--variant full`（默认）：额外装 `dkms` + `build-essential` + `linux-headers-*`，
  构建时就把 `kernel/<side>/` 的模块编好装上。**以后内核升级会自动重编**，代价是
  tar 从 ~240 MB 涨到 ~350 MB（解开 ~900 MB）。
- `--variant base`：不装编译器、不带模块。根分区小的时候用，之后再跑一次
  `kernel/<side>/install.sh`（它会自己装工具链）。

产物是 `out/xgs87-<side>-<variant>.tar.zst`。

## x86：变成可启动镜像

```sh
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst --out out/debian-x86.img
```

`--size` 默认 `auto`（rootfs 实际大小 + 5% + 256 MiB，再加上 476 MiB 的 ESP），
首次开机由 `xgs87-growroot.service` 把 `p2` 扩到盘尾，所以不用再写死 4G/8G。
GPT + 476 MiB ESP(FAT32) + ext4 root，
`grub-install --removable`（这块 BIOS 只认 `\EFI\BOOT\BOOTX64.EFI`），并把 GRUB
超时压到 2 秒（否则 `recordfail` 会白等 30 秒）。

## 账号

镜像里只有 `admin`（`P@ssw0rd`，在 `sudo` 组里，`sudo` 要密码）。`root` 保留 uid 0
但被 `passwd -l` 锁死，sshd 里 `PermitRootLogin no`：

```sh
useradd --create-home --shell /bin/bash --groups sudo admin
echo "admin:P@ssw0rd" | chpasswd
passwd -l root
```

想换口令就改 `image/setup.sh` 这一段，或者装完机后 `passwd`。

## NPU：怎么装

NPU 没有 ESP，是 U-Boot 从 eMMC 的一个分区里 `ext4load` 内核和 DTB，所以：

```sh
# 在正在跑的 NPU 上
mkfs.ext4 -L xgsroot /dev/mmcblk0pX
mount /dev/mmcblk0pX /mnt
zstd -dc debian-npu.tar.zst | tar -xpf - -C /mnt
# fstab、/boot/Image、DTB 见 docs/07 与 docs/03
```

⚠️ 根分区 1.5 GB 装不下 `full`（解开约 900 MB）。要么用 `--variant base`（~240 MB），
要么把根分区做到 ≥3 GB。

## 维护 U 盘（diagnostic USB）

`installer/mkusb.sh` 把 x86 整盘镜像 + NPU 的 rootfs 拼成一条可启动 U 盘，串口上出菜单，
可以格式化重装 x86 / NPU、备份内置盘：

```sh
sudo ./installer/mkusb.sh \
    --x86 out/debian-x86.img.zst \
    --npu debian-npu.tar.zst \
    --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
    --out out/debian-usb.img
```

刷入和菜单说明见 [release-usb.md](release-usb.md)；从原厂 SFOS 第一次换系统见
[docs/22-from-sfos.md](../docs/22-from-sfos.md)。

## GitHub Actions

三个**独立**的 workflow，各自跑在原生架构的 runner 上（不做交叉编译、不用 qemu）：

| workflow | runner | 产物 |
|---|---|---|
| [image-x86.yml](../.github/workflows/image-x86.yml) | `ubuntu-24.04`（amd64） | `debian-x86.img.zst`（可启动镜像）+ `xgs87-x86-*.tar.zst`（artifact） |
| [image-npu.yml](../.github/workflows/image-npu.yml) | `ubuntu-24.04-arm`（aarch64，公开仓库免费） | `debian-npu.tar.zst` + `cn9130-sophos-xgs87w-sfp10g.dtb` |
| [image-usb.yml](../.github/workflows/image-usb.yml) | 两个原生 runner 各编一半 + amd64 拼盘 | `debian-usb.img.zst`（维护 U 盘） |

三个 workflow 都**只在手动触发**时运行（Actions → 选 workflow → Run workflow，或
`gh workflow run image-x86.yml`），提交代码不会再自动烧 CI 时间。

**产物自动发 Release**：三个 workflow 各写一个**固定 tag**，每次覆盖同一个 release
（不再有 `<日期>-<sha>` 的临时 tag）；说明文件就是同目录的 `release-*.md`，用
`gh release --notes-file` 发出去。

| workflow | tag | 资产 |
|---|---|---|
| `image-x86.yml` | `debian-x86` | `debian-x86.img.zst` |
| `image-npu.yml` | `debian-npu` | `debian-npu.tar.zst` + `cn9130-sophos-xgs87w-sfp10g.dtb` |
| `image-usb.yml` | `debian-usb` | `debian-usb.img.zst` |

x86 的 `out/xgs87-x86-*.tar.zst` 只进 CI artifact（7 天），不发 release。

⚠️ arm64 runner 在**私有**仓库要付费计划；本仓库是公开的，`ubuntu-24.04-arm` 免费。
