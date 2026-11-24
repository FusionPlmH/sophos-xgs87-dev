# 21 — 在另一台机器上还原这套东西

这一页回答一个问题：**拿到这个仓库（和历史里没有的真机标识），怎么在另一台机器上把
x86 / NPU 两套系统重新做出来。** 下面每一步都在 2026-11-23 用 Debian trixie 实跑过。

## 21.1 先分清哪些是"源码"，哪些是"产物"

| 路径 | 性质 | 换机器后 |
|---|---|---|
| `image/`、`kernel/`、`systemd/`、`board/`、`tools/` | 源码 | 直接可用 |
| `reference/` | 实机 dump（已脱敏） | 只读参考，构建不依赖 |
| `out/` | 构建产物（被 `.gitignore` 忽略） | 本机重新生成 |
| `installer/` | 维护 U 盘的脚本 | 依赖 `out/` 里的产物 |

构建只需要：**Linux 主机 + root**。x86 用任意 amd64 Debian/Ubuntu；NPU 用 arm64
（或者 GitHub 的 `ubuntu-24.04-arm` runner）。mmdebstrap 需要 `debian-archive-keyring`
不早于 trixie——Ubuntu 24.04 自带的太旧，`image/` 的 workflow 里有一段专门先装新 keyring。

## 21.2 rootfs

```sh
sudo ./image/build.sh --arch amd64 --variant full   # x86
sudo ./image/build.sh --arch arm64 --variant full   # NPU（在 arm64 上跑）
```

- `full` 会额外装 `dkms` + `build-essential` + `linux-headers-*`，并在 `setup.sh` 里
  把 `kernel/<side>/` 的模块编好、`dkms install` 进去（以后内核升级自动重编）。
- `lean` 用普通 `make` 编一次模块，然后把工具链按 dpkg 快照差值 purge 掉：root 解开
  387 MiB（`full` 是 ~900 MiB），代价是内核被 `apt-mark hold`。
- `base` 不装工具链也不带模块；装到机器上后再跑一次 `kernel/<side>/install.sh`。
- 产物：`out/xgs87-<side>-<variant>.tar.zst`。

`image/setup.sh` 是唯一在 chroot 里跑的脚本：装 unit、enable 服务、建 `admin` 账户、
锁 root、清 apt 缓存。它要求 `sudo` 这个包（提供 `sudo` 组）已经在
`image/packages-common.list` 里——漏了就会在 `useradd --groups sudo` 这一步失败。

## 21.3 x86 整盘镜像

```sh
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst --out out/debian-x86.img
```

默认 `--size auto`：rootfs 实际大小 + 5% + 192 MiB，再加 64 MiB 的 ESP。**不要**再传 `--size 4G`，
镜像大小跟着内容走，首次开机由 `xgs87-growroot.service` 把 `p2` 扩到盘尾。

## 21.4 设备树和模块

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

## 21.5 仓库里的占位符（把真值放回去）

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

## 21.6 发布前检查

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

## 21.7 CI 与 release

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
