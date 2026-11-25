# debian-x86 — XGS 87 的 x86 侧（16 GB eMMC，UEFI 启动）

固定 release：每次跑 `image` workflow 的 x86 目标都会**覆盖**这里的资产和本文。

| 资产 | 是什么 | 实测 |
|---|---|---|
| `debian-x86.img.zst` | **整盘镜像**：GPT + ESP(128 MiB FAT32) + ext4 root + GRUB EFI | 解开 **727 MiB**（`lean`，2026-11-25 实测 762,314,752 B；ESP 从 476 MiB 降到 128 MiB 后小了约 350 MiB，见 docs/07 §7.3） |

## 为什么这个镜像比 `debian-npu` 大好几倍

两个 release 不是同一种东西，直接比会被误导：

| | `debian-npu` | `debian-x86`（这个） |
|---|---|---|
| 资产形态 | 根文件系统 **tar.zst**（压缩） | **整盘镜像** `.img`（GPT + ESP + ext4，压缩前就是完整磁盘布局） |
| 真正的根文件系统 | **~500 MiB** 解开 / 190 MB 压缩 | **387 MiB** 解开 / 199 MB 压缩（`lean`，包基本一样） |
| 额外占的空间 | 无 | ESP 128 MiB + ext4 日志/元数据 + 192 MiB 余量 + GPT 对齐 |
| 发布体积 | 190 MB | 207 MB（未压缩镜像 727 MiB，实测 762,314,752 B） |

注意 `.zst` 只有 207 MB（NPU 是 190 MB）——**下载体积几乎没差**，因为镜像里多出来的是零
（ESP 和 ext4 空闲块），zstd 本来就能压掉。差的是**未压缩镜像**（727 MiB），影响 dd 时间。

**两边装的东西一样大**，差的是"压缩的 tar"vs"未压缩的整盘"。ESP 定成 **128 MiB**：shim + grub
实测只用 4.4 MiB（约 29 倍余量），够 shim/grub 更新和一个 fwupd capsule —— **内核不在 ESP 里**，
所以在 root 分区上，内核升级跟 ESP 无关。ESP 是整盘镜像的第一个分区，装好之后没法像 root 那样
自动扩（要扩得把 p2 整体往后搬），所以尺寸只能在构建时定（`mkdisk.sh` 的 `ESP_MIB`，构建日志会
打印占用率，超过 80% 告警）。首次开机 `xgs87-growroot` 会把 root 扩到盘尾（实测 597 MiB → 14.6 GB）。

## 刷入

```sh
zstd -d debian-x86.img.zst
lsblk                                   # 先确认目标盘
sudo dd if=debian-x86.img of=/dev/sdX bs=4M conv=fsync status=progress
```

- 写到**整块盘**：`/dev/sdX` / `/dev/mmcblk0` / `/dev/nvme0n1`；写成 `...p1` 不会启动
- Windows：7-Zip 解出 `.img`，Rufus 选它并**用 DD 模式**（ISO 模式会改坏 ESP）；Etcher 直接选 `.img`
- 镜像按实际内容生成，不写死容量；**首次开机 `xgs87-growroot.service` 会把 `p2` 扩到盘尾**
- 串口 **115200 8N1**（RJ45 或 micro-USB）：GRUB 和内核都走 `ttyS0`（`GRUB_TERMINAL=serial`，
  内核 `console=ttyS0,115200n8`），没有 `console=` 就会卡在 `Loading initial ramdisk`

## 装完

- 登录 **`admin` / `P@ssw0rd`**（在 `sudo` 组里）。**没有 root 账户**：`root` 已 `passwd -l`，
  sshd 里 `PermitRootLogin no`；主机名是 **`xgs-debian-x86`**（NPU 那半是 `xgs-debian-npu`）
- 没有内置网口，唯一 netdev 是 vNTB → **NPU 起来之后**这台机器才有网络
- 网络跟着 NPU 的两条 VLAN 走：
  - `eth0.100`（WAN / 管理）跑 DHCP，地址和默认路由都是上游给的
  - `eth0.200`（LAN）静态 `10.234.56.2/24`，NPU 在 `.1`；这段**没有** DHCP 服务
  - 想改 WAN/LAN 的端口和模式，改 NPU 上的 `/etc/xgs87/net.conf`（见 `debian-npu` 的说明）
- 刷坏了：用维护 U 盘 [`debian-usb`](https://github.com/FusionPlmH/sophos-xgs87-dev/releases/tag/debian-usb)
  开机，串口菜单选 `1` 整盘重写

## 变体（自己构建时选）

| 变体 | root 解开 | `tar.zst` | 模块怎么来的 | 内核升级 |
|---|---|---|---|---|
| `full`（默认） | ~900 MiB | ~350 MB | 镜像里带 DKMS + 编译器，构建时编好 | `apt upgrade` 自动重编 |
| `lean` | **387 MiB** | **199 MB** | 构建时用 `make` 编一次，之后把工具链 purge 掉 | 内核被 `apt-mark hold`；要升就先 `apt-mark unhold linux-image-amd64` 再跑 `/opt/xgs87/kernel/x86/install.sh` |
| `base` | 比 `lean` 略小 | 未测 | 不带模块 | 装完自己跑一次 `kernel/x86/install.sh` |

```sh
sudo ./image/build.sh --arch amd64 --variant lean
```

`lean` 里 `/lib/modules/<kver>/updates/` 有编好的 `ntb_*`（`modules.dep` 已指向它们），
`gcc` / `cpp` / `make` / `linux-headers` 全都不在——`lean` 比 `full` 少的正是这部分工具链
（最近一次构建实测：`lean` 的 root 解开 387 MiB / 压缩 199 MB；装到盘上首次开机后 `df /` 报
440 MiB 已用 —— 差的是 ext4 元数据和块对齐。）
