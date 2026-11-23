# image/ — 最小化 Debian 构建

两台机器都用 **通用内核 + 发行版模块 + DKMS**，所以镜像里没有任何自编内核，
系统更新不需要重新构建镜像。

```
image/build.sh       mmdebstrap 构建 rootfs（本机或 GitHub Actions）
image/setup.sh       在 chroot 里跑：装 unit、编 out-of-tree 模块、enable 服务
image/mkdisk.sh      把 x86 的 rootfs 变成可启动 GPT 镜像（ESP + GRUB EFI）
image/packages-*.list 软件包清单（common / x86 / npu）
image/overlay/      直接覆盖到 rootfs 根的文件（目前只有 NPU 的两个 boot 钩子）
```

## 本机构建

```sh
sudo ./image/build.sh --arch arm64              # NPU，含工具链和 DKMS 模块
sudo ./image/build.sh --arch amd64              # x86
sudo ./image/build.sh --arch amd64 --variant lean   # 编完模块就删工具链（小 ~380 MiB）
sudo ./image/build.sh --arch amd64 --variant base   # 只要骨架（tar ~240 MB）
```

- `--variant full`（默认）：额外装 `dkms` + `build-essential` + `linux-headers-*`，
  构建时就把 `kernel/<side>/` 的模块编好装上。**以后内核升级会自动重编**，代价是
  root 解开 ~900 MiB、tar ~350 MB。
- `--variant lean`：用普通 `make` 编一次模块（装进 `/lib/modules/<kver>/updates/`），
  然后把工具链按 **dpkg 快照差值**精确 purge 掉。**root 解开 525 MiB、tar 238 MB**
  （x86 实测，比 full 少约 380 MiB）。代价是镜像自己没法再编模块，所以内核被
  `apt-mark hold`；要升级内核就先 `apt-mark unhold linux-image-amd64`（NPU 是
  `linux-image-arm64`），再跑镜像里的 `/opt/xgs87/kernel/<side>/install.sh`。
- `--variant base`：不装编译器、不带模块。根分区小的时候用，之后再跑一次
  `kernel/<side>/install.sh`（它会自己装工具链）。

产物是 `out/xgs87-<side>-<variant>.tar.zst`。

> 为什么 `lean` 要在 chroot 里自己 `apt-get install` 工具链、而不是放进 `--include`：
> mmdebstrap 把 `--include` 里的包全标成 manual，`apt-get autoremove` 永远不会删它们，
> 于是 purge `build-essential` 之后 `gcc`/`cpp`/`make`/`libc6-dev` 全都留着（实测只小了
> 60 MiB）。用装前/装后的 `dpkg-query` 快照做差值，才能把 12 个包干净删掉。

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

⚠️ 根分区 1.5 GB 装不下 `full`（root 解开 ~900 MB）。用 `--variant lean`（解开 525 MiB，
工具链编完就删，占用约一半），或者把根分区做到 ≥3 GB。`base` 也行，但要自己再跑一次
`kernel/npu/install.sh`。

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

只有一个 workflow：[image.yml](../.github/workflows/image.yml)。每个目标都跑在原生架构的
runner 上（不做交叉编译、不用 qemu），USB 由前两者的产物在 amd64 上拼盘。

| 目标（`target`） | runner | 产物 | release tag |
|---|---|---|---|
| `x86` | `ubuntu-24.04`（amd64） | `debian-x86.img.zst` + `xgs87-x86-*.tar.zst`（artifact） | `debian-x86` |
| `npu` | `ubuntu-24.04-arm`（aarch64，公开仓库免费） | `debian-npu.tar.zst` + `cn9130-sophos-xgs87w-sfp10g.dtb` | `debian-npu` |
| `usb` | 上面两个 → amd64 拼盘 | `debian-usb.img.zst` | `debian-usb` |
| `all`（默认） | 三个都跑 | 全部 | 三个都更新 |

**只在手动触发时运行**，提交代码不会烧 CI 时间：

```sh
gh workflow run image.yml                                # all + full
gh workflow run image.yml -f target=usb -f variant=lean   # 只出 U 盘，用 lean 变体
```

可选的输入：`target`（all/x86/npu/usb）、`variant`（full/lean/base）、`size`
（x86 整盘镜像容量，默认 `auto`）。

**产物自动发 Release**：每个目标写一个**固定 tag**，每次覆盖同一个 release（没有
`<日期>-<sha>` 的临时 tag）。说明文件就是同目录的 `release-*.md`，用
`gh release create/edit --notes-file` 发出去，所以 release 页面和代码里的说明永远一致。

x86 的 `out/xgs87-x86-*.tar.zst` 只进 CI artifact（7 天），不发 release。

⚠️ arm64 runner 在**私有**仓库要付费计划；本仓库是公开的，`ubuntu-24.04-arm` 免费。

## 与 sophgo-sg200x-debian 的对照

构建思路参考过 [FusionPlmH/sophgo-sg200x-debian](https://github.com/FusionPlmH/sophgo-sg200x-debian)
（同作者的 SG200x 板子镜像）。相同的部分：`mmdebstrap` 一条命令出 rootfs、显式包清单、
overlay + chroot 定制、清 apt lists/cache、删 machine-id 和 SSH host key、镜像尺寸贴合内容
（他们 `size = 105%`，我们 `5% + 256 MiB + ESP`）、首次启动扩分区。不同的部分和取舍：

| 他们 | 我们 | 原因 |
|---|---|---|
| 内核/U-Boot/OpenSBI/FSBL 全从源码编成 `.deb` | 用发行版内核；只把 out-of-tree 模块编出来 | 我们的硬件在 mainline 6.12 里已经有了，不必背 vendor 5.10 |
| `genimage` 声明式分区表 | `mkdisk.sh` 里 `sfdisk` + `losetup` | 少一个构建依赖；GPT/ESP 只有一种布局，不值得再引一层声明 |
| Makefile + `-stamp` 增量目标 | 三个一次性 shell 脚本 | CI 是手动全量构建，增量收益只在本地调试 |
| 固定 builder 容器（ghcr） | 直接用 runner 自带工具 | 工具只有 mmdebstrap/zstd/dosfstools/grub，漂移很小 |
| `systemd-journald` 整个掩掉省空间 | 保留 journal | 这台机器就是拿来现场排障的，log 不能丢 |
| 禁 IPv6、压 `kernel.printk` | 不动 | vNTB / netconsole 用到 IPv6 链路本地地址，串口要看得见日志 |
| 首次启动建 swap、首次联网对时 | 只有 growroot | 两台机器都没有 swap，NPU 的 RAM 还够；对时用 `systemd-timesyncd` |

唯一真正借鉴过来的是"先把内核模块编成产物，再把编译器扔掉"——就是上面的 `lean` 变体。
