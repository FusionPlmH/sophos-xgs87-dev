# debian-x86 — XGS 87 的 x86 侧（UEFI，装到内置盘）

每次跑 `image` workflow 的 **x86** 目标都会覆盖这里的资产和本文。

| 资产 | 是什么 | 体积 |
|---|---|---|
| `debian-x86.img.zst` | **整盘镜像**：GPT + ESP(128 MiB FAT32) + ext4 root + GRUB EFI | 压缩 **207 MB**，解开 **727 MiB** |

## 刷入

```sh
zstd -d debian-x86.img.zst
lsblk                                        # 先确认目标盘
sudo dd if=debian-x86.img of=/dev/sdX bs=4M conv=fsync status=progress
```

- 写**整块盘**（`/dev/sdX`、`/dev/mmcblk0`、`/dev/nvme0n1`）；写成 `…p1` 起不来。
- Windows：7-Zip 解出 `.img` → Rufus 选它、**写入方式必须 DD 镜像**；Etcher 直接选 `.img`。
  Rufus 的 ISO 模式会重排分区，把 ESP 里的 `\EFI\BOOT\BOOTX64.EFI` 弄没，机器就只会
  "BIOS 认得出盘、一个字符不打就 reset"。
- 镜像按内容生成、不写死容量：**首次开机 `xgs87-growroot.service` 把 `p2` 扩到盘尾**
  （实测 ~600 MiB → 14.6 GB）。

## 开机

- 串口 **115200 8N1**（RJ45 或 micro-USB），GRUB 和内核都走 `ttyS0`。
- BIOS 执行的是 ESP 的兜底路径 `\EFI\BOOT\BOOTX64.EFI`；构建时已断言它在盘上，
  BIOS 里那条 NVRAM 项丢了也能起。
- 没有内置网口：**唯一 netdev 是 vNTB，NPU 起来之后这台机器才有网络。**

## 装完

- 登录 **`admin` / `P@ssw0rd`**（在 `sudo` 组）。**没有 root 账户**（`passwd -l` + sshd
  `PermitRootLogin no`），主机名 **`xgs-debian-x86`**。
- 网络跟着 NPU 的两条 VLAN 走，配置在 **NPU** 的 `/etc/xgs87/net.conf`：
  `eth0.100`（WAN/管理，DHCP）、`eth0.200`（LAN，静态 `10.234.56.2/24`，NPU 在 `.1`）。
- 刷坏了 → 维护 U 盘 [`debian-usb`](https://github.com/FusionPlmH/sophos-xgs87-dev/releases/tag/debian-usb)
  开机，串口菜单选 `1` 整盘重写。

## 变体（自己构建时选）

| 变体 | root 解开 | `.img.zst` | 内核升级 |
|---|---|---|---|
| `full` | ~900 MiB | ~350 MB | 带 dkms + 编译器，`apt upgrade` 自动重编 |
| **`lean`（发布用）** | **387 MiB** | **207 MB** | 内核 `apt-mark hold`；升级先 `apt-mark unhold linux-image-amd64` 再跑 `/opt/xgs87/kernel/x86/install.sh` |
| `base` | 和 `lean` 差不多 | 未测 | 骨架：模块到机器上再跑一次 `kernel/x86/install.sh` |

```sh
sudo ./image/build.sh --arch amd64 --variant lean
```

`lean` 在构建时把 `ntb_*` 编好放进 `/lib/modules/<kver>/updates/`，然后把 `gcc`/`make`/
`linux-headers`/dkms 全部 purge 掉 —— 这就是它比 `full` 小一半多的原因。

## 和 `debian-npu` 为什么不能直接比体积

一个是**整盘镜像**（含 ESP、ext4 元数据、GPT 对齐），一个是**压缩的根文件系统 tar**。
解压后两边装的东西差不多（x86 387 MiB / NPU 500 MiB），下载体积也接近（207 MB vs 191 MB）
—— 差的是未压缩的磁盘布局，影响的是 `dd` 时间。

细节见仓库 [docs/](https://github.com/FusionPlmH/sophos-xgs87-dev/tree/main/docs)：
`01-hardware` `02-system` `03-build` `04-install` `05-operations` `06-rescue`。
