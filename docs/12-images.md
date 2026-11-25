# 12 · 镜像与发布：在另一台机器上把两套系统做出来

> 🏷 **状态（2026-11-25 复核）**：✅ 构建与发布链路可用（GitHub Actions `image.yml`，手动触发）。
> ⚠️ 发布产物目前需要**手动**派发 workflow —— 仓库里没有 token，自动化派发不可用。
> 当前发布的是 `--variant lean`（x86 tar 199 MB / 镜像 727 MB，NPU 500 MiB / 190 MB）。

这一页回答一个问题：**拿到这个仓库（和历史里没有的真机标识），怎么在另一台机器上把
x86 / NPU 两套系统重新做出来。** 下面每一步都在 2026-11-23 用 Debian trixie 实跑过。
镜像内部怎么装出来（`image/build.sh` 的各个 variant、`setup.sh` 干了什么）看
[docs/12-images.md](../docs/12-images.md)；怎么把镜像写到机器上看 [13](13-installer.md)。

## 12.1 先分清哪些是"源码"，哪些是"产物"

| 路径 | 性质 | 换机器后 |
|---|---|---|
| `image/`、`kernel/`、`systemd/`、`board/`、`tools/` | 源码 | 直接可用 |
| `reference/` | 实机 dump（已脱敏） | 只读参考，构建不依赖 |
| `out/` | 构建产物（被 `.gitignore` 忽略） | 本机重新生成 |
| `installer/` | 维护 U 盘的脚本 | 依赖 `out/` 里的产物 |

构建只需要：**Linux 主机 + root**。x86 用任意 amd64 Debian/Ubuntu；NPU 用 arm64
（或者 GitHub 的 `ubuntu-24.04-arm` runner）。mmdebstrap 需要 `debian-archive-keyring`
不早于 trixie——Ubuntu 24.04 自带的太旧，`image/` 的 workflow 里有一段专门先装新 keyring。

## 12.2 rootfs

```sh
sudo ./image/build.sh --arch amd64 --variant full   # x86
sudo ./image/build.sh --arch arm64 --variant full   # NPU（在 arm64 上跑）
```

- `full` 会额外装 `dkms` + `build-essential` + `linux-headers-*`，并在 `setup.sh` 里
  把 `kernel/<side>/` 的模块编好、`dkms install` 进去（带 dkms，所以之后升级内核会自动重编）。
- `lean`（**workflow 发布用的就是它**）用普通 `make` 编一次模块，然后把工具链按 dpkg 快照
  差值 purge 掉：root 解开 387 MiB（`full` 是 ~900 MiB），代价是内核被 `apt-mark hold`、
  镜像里没有 dkms —— 换内核要 `apt-mark unhold` 后跑 `/opt/xgs87/kernel/<side>/install.sh`。
- `base` 不装工具链也不带模块；装到机器上后再跑一次 `kernel/<side>/install.sh`。
- 产物：`out/xgs87-<side>-<variant>.tar.zst`。

`image/setup.sh` 是唯一在 chroot 里跑的脚本：装 unit、enable 服务、建 `admin` 账户、
锁 root、清 apt 缓存。它要求 `sudo` 这个包（提供 `sudo` 组）已经在
`image/packages-common.list` 里——漏了就会在 `useradd --groups sudo` 这一步失败。

## 12.3 x86 整盘镜像

```sh
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst --out out/debian-x86.img
```

默认 `--size auto`：rootfs 实际大小 + 5% + 192 MiB，再加 128 MiB 的 ESP。**不要**再传 `--size 4G`，
镜像大小跟着内容走，首次开机由 `xgs87-growroot.service` 把 `p2` 扩到盘尾。

## 12.4 设备树和模块

```sh
./tools/build/build-dtb.sh                     # board/*.dts -> out/cn9130-sophos-xgs87w-sfp10g.dtb
sudo ./kernel/x86/install.sh                   # x86 上重装 ntb_* 四个模块
sudo ./kernel/npu/install.sh                   # NPU 上重装 vNTB / spi-orion / clkfix
```

DTB 是 NPU 启动必需：U-Boot 的 `bootcmd` 从 root 分区 `ext4load` 它，名字必须与
`reference/uboot-env.txt` 里的一致（`cn9130-sophos-xgs87w-sfp10g.dtb`）。

> `reference/uboot-env.txt` 是**26 键的精简参考**，不是芯片上完整原厂 env 的权威副本；
> 真正的 35 键版本在设备上/整片 dump 里。做写 env 的操作时以 `mcp2210-nor.py` 的 dump
> 为准，不要拿这个文本直接刷。

## 12.5 仓库里的占位符（把真值放回去）

仓库不保存这台机器的身份信息，下面这些值在源码里是占位符：

| 位置 | 占位符 | 换成 |
|---|---|---|
| `systemd/npu/xgs-netconsole.service` 第二个目标 | `10.234.56.50` / `02:00:00:00:00:01` | 你自己的 br-lan 监听机地址和 MAC |
| 文档里的例子地址 | `192.168.0.0/24`（家里内网） | 你的内网 |
| `reference/*` | `<redacted-serial>`、`7c:5a:1c:xx:xx:xx`、`fe80::<redacted>`、`<redacted-mac>` | 只在本地留副本，不要提交 |
| 控制台账号 | `admin` / `P@ssw0rd`（`sudo` 要密码，root 锁定） | 装机后自己改 |

真机值放在仓库外面，例如 `~/xgs-private.txt`：

```sh
# 一行一个字面量，# 开头是注释
<redacted-serial>
7c:5a:1c:xx:xx:xx
```

再拿它去脱敏日志：

```sh
./tools/on-pc/redact.py --list ~/xgs-private.txt COM5.log COM5.log.redacted
```

`reference/mtd/npu-mtd1-env.bin.gz` 是唯一被改过的二进制：里面 `ethaddr` 换成了
`7c:5a:1c:xx:xx:xx`（等长替换），然后按 U-Boot env 的规则重算了头部 CRC32。
要再做一次就用 `python3`：读出 gzip → 等长替换 → `struct.pack_into("<I", buf, 0,
zlib.crc32(buf[4:]))` → 用 `gzip.GzipFile(..., mtime=0)` 写回。

## 12.6 发布前检查

```sh
./tools/check-hygiene.sh          # 真实 MAC / 内网地址 / 用户路径 / 序列号
```

它只放行仓库自己分配的地址（见脚本头部注释），其余一律报错。CI 的
`.github/workflows/image.yml` 只负责构建，不跑这个检查——它是提交前在本地跑的。

构建结果抽查：

```sh
tar --zstd -xOf out/xgs87-x86-full.tar.zst ./etc/passwd  | grep -E '^(admin|root):'
tar --zstd -xOf out/xgs87-x86-full.tar.zst ./etc/shadow  | grep -E '^(admin|root):' | cut -d: -f1,2
tar --zstd -xOf out/xgs87-x86-full.tar.zst ./etc/group   | grep '^sudo:'
```

期望：`admin` 有口令哈希（`$y$…`），`root` 是 `!*`，`sudo:x:27:admin`。

## 12.7 CI 与 release

只有一个 workflow（`.github/workflows/image.yml`），手动触发，用 `target` 选要出哪个产物；
每个目标维护一个**固定 tag**（每次覆盖，说明见 `image/release-*.md`）：

```sh
gh workflow run image.yml                                  # all + full
gh workflow run image.yml -f target=usb -f variant=lean     # 只出 U 盘
```

| `target` | tag | 资产 |
|---|---|---|
| `x86` | `debian-x86` | `debian-x86.img.zst` |
| `npu` | `debian-npu` | `debian-npu.tar.zst` + `cn9130-sophos-xgs87w-sfp10g.dtb` |
| `usb` | `debian-usb` | `debian-usb.img.zst`（维护 U 盘，见 [release-usb.md](../image/release-usb.md)） |

x86 的 rootfs tar 只作为 CI artifact 保留（7 天），不发 release——它和镜像里的内容一样，
自己 build 也能得到。

## 12.8 构建脚本与变体（原 `docs/12-images.md`）

```
image/build.sh        mmdebstrap 构建 rootfs（本机或 GitHub Actions）
image/setup.sh        chroot 里跑：装 unit、编 out-of-tree 模块、enable 服务
image/mkdisk.sh       把 x86 的 rootfs 变成可启动 GPT 镜像（ESP + GRUB EFI）
image/packages-*.list 软件包清单（common / x86 / npu）
image/overlay/        直接覆盖到 rootfs 根的文件
```

```sh
sudo ./image/build.sh --arch arm64                 # NPU
sudo ./image/build.sh --arch amd64                 # x86
sudo ./image/build.sh --arch amd64 --variant lean  # 发布用：编完模块就删工具链
sudo ./image/build.sh --arch amd64 --variant base  # 只要骨架，不带模块
```

| 变体 | root 解开 | 带什么 | 代价 |
|---|---|---|---|
| `full` | ~900 MiB | dkms + 编译器 + headers，模块编好 | 大；`p2` 1.5 GB 装不下 |
| **`lean`（发布用）** | **387 MiB**（tar 199 MB） | 模块编好放进 `/lib/modules/*/updates/`（`.ko.xz`），工具链按 dpkg 快照差值 purge | 镜像里没有 dkms，内核被 `apt-mark hold` |
| `base` | 更小 | 无模块 | 装完自己跑 `kernel/<side>/install.sh` |

`lean` 必须在 chroot 里自己 `apt-get install` 工具链：mmdebstrap 的 `--include` 会把包标成
manual，`autoremove` 永远删不掉，purge 完 `gcc`/`make`/`libc6-dev` 还在（实测只小 60 MiB）。
用装前/装后的 `dpkg-query` 快照做差值才能删干净。

**x86 整盘镜像**：`sudo ./image/mkdisk.sh --rootfs out/xgs87-x86.tar.zst --out out/debian-x86.img`。
`--size auto`（rootfs + 5% + 192 MiB + 128 MiB ESP），首次开机 `xgs87-growroot` 扩到盘尾。
`grub-install --removable`（这块 BIOS 只认 `\EFI\BOOT\BOOTX64.EFI`），GRUB 超时压到 2 s
（否则 `recordfail` 白等 30 s）。

**压缩一律 `zstd -T0 -10`**。试过更狠的不划算：

| 方法 | 大小 | 压缩耗时（16 核） | 裸 `zstd -d` 能解 |
|---|---|---|---|
| **`-10`（现在用）** | 249.6 MiB | 2 s | ✅ |
| `-19 --long=27` | 222.6 MiB | 33 s | ✅ |
| `-22 --long=31` | 195.7 MiB | 159 s | ❌ 要 `--long=31` |
| `xz -9e` | 225.6 MiB | 110 s | 解压比 zstd 慢 5 倍 |

`-19` 省 11%，CI 上 x86 job 从 2.6 min 涨到 7.8 min、USB 拼盘从 3.4 min 涨到 20 min 以上，
不值。格式保持 `.zst`，解压永远是裸 `zstd -d`。

**解包时就扔掉的**（`--dpkgopt=path-exclude=`，事后删只是把时间挪个地方）：

| 排除 | 省 | 为什么可以 |
|---|---|---|
| `/usr/share/locale/*` | 56 MB | 串口机没有翻译需求 |
| `/usr/share/i18n/*` | 17 MB | 不跑 `locale-gen`，`C.UTF-8` 在 glibc 里 |
| `/usr/share/doc/*`（留 `copyright`） | 18 MB | dpkg 政策只要求许可证 |
| `/usr/share/man/*` | 11 MB | 有 `--help` 和这个仓库 |
| `locales`、`console-setup` | 30 MB | 同上 |

还没做的：内核模块白名单（`/lib/modules` 现在 108 MB，按真机 `lsmod` 能到 30 MB 量级）、
把 `python3-minimal` + `whiptail`（21 MB，只为 U 盘菜单）换成纯文本菜单。

**账号**：镜像里只有 `admin`（`P@ssw0rd`，sudo 组，sudo 要密码）；`root` 保留 uid 0 但
`passwd -l` 锁死，sshd `PermitRootLogin no`。维护 U 盘是例外（`XGS_LIVE_ROOT=1`），控制台
直接给 root。

**NPU 没有 ESP**：U-Boot 从 eMMC 分区 `ext4load` 内核 + DTB，所以装完必须保证
`/boot/Image` 和 `/boot/initrd.img` 两个固定名字存在（`installer/payload/*.sh` 会自动做）。
根分区 1.5 GB 装不下 `full`；`xgs87-growroot` 只在 root 是**最后一个分区**时才扩，
NPU 的 p2 后面还有 p3/p4，所以它跳过 —— 不会碰原厂回滚槽和 VPD。

## 12.9 构建工具（原 `docs/10-console.md` 的 `build/` 部分）

这些**在 PC 的 WSL 上跑**，不是在设备上。最容易搞混的就是这一点：编 NPU 的模块不代表
脚本在 NPU 上跑。

| 脚本 | 产物 → 装到 |
|---|---|
| `build-npu-vntb.sh` | 6 个 vNTB 模块 → **NPU**（`chroot /srv/npu` + qemu user-mode） |
| `build-x86-vntb.sh` | `ntb_*.ko` 四个 → **x86**（amd64 原生） |
| `build-dtb.sh` | `out/cn9130-sophos-xgs87w-sfp10g.dtb`（先 `cpp` 再 `dtc`） |
| `build-npu-net.sh` | 可选：带 TCAM 补丁的 `mv88e6xxx.ko`、`AGGR_TXQ_SIZE=512` 的 `mvpp2.ko` → **NPU**（镜像默认用发行版原版） |
| `build-rescue.sh` | `xgs87-rescue.tar.zst`（`Image.gz` + `initramfs.gz` + DTB，约 15 MB）→ **NPU 的 U-Boot 内存** |
| `build-rescue-kernel.sh` | 裁剪版急救内核；**默认不用**，只在想再压 10 MB 时才需要 |
| `build-npu-kernel.sh` | 整颗 `Image`。只有"必须编进 vmlinux"的选项才需要（`PSTORE_CONSOLE` 那次），`ramoops` 已证伪，别再为它重编 |

三条铁律（踩过的坑见 [15](15-modules-and-kernel.md) §15.5）：不能用 `linux-headers` 交叉编译
（包里的 `scripts/` 是 aarch64 二进制）、`vermagic` 必须带 `+deb13-<arch>`、**别手工 `xz -9`**。
