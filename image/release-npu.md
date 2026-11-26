# debian-npu — XGS 87 的 NPU 侧（Marvell CN9130，arm64）

每次跑 `image` workflow 的 **npu** 目标都会覆盖这里的资产和本文。

| 资产 | 是什么 | 体积 |
|---|---|---|
| `debian-npu.tar.zst` | **根文件系统 tar**（不是磁盘镜像） | 压缩 **191 MB**，解开 **~500 MiB** |
| `cn9130-sophos-xgs87w-sfp10g.dtb` | 板级设备树，必须和这版内核配套 | **21 KB** |

NPU 没有 ESP、没有 GRUB：U-Boot 直接从 eMMC 的一个 ext4 分区里 `ext4load` 内核和 DTB
（`bootcmd` 见 [docs/02-system.md](https://github.com/FusionPlmH/sophos-xgs87-dev/blob/main/docs/02-system.md)）。

## 安装

```sh
mkfs.ext4 -L xgsroot /dev/mmcblk0p2          # ⚠️ 会清空 p2，先确认没选错
mount /dev/mmcblk0p2 /mnt
zstd -dc debian-npu.tar.zst | tar -xpf - -C /mnt
cp cn9130-sophos-xgs87w-sfp10g.dtb /mnt/boot/
```

- 写到 **root 分区**：原厂布局是 `p2`（1524 MiB）；`p1`（原厂 Marvell rootfs）、`p3`（原厂
  Sophos Buildroot，救生艇）、`p4`（VPD：序列号/MAC）**永远不写**。
- `/boot/Image`、`/boot/initrd.img` 由内核 postinst 钩子维护，升级内核不用改 U-Boot env。
- 首次开机会把 root 扩到盘尾；**后面还有分区（本机 p3/p4）就跳过**，不碰原厂槽和 VPD。

## 装完

- 登录 **`admin` / `P@ssw0rd`**（`sudo`），**没有 root 账户**，SSH 拒绝 root 登录。
- 主机名 **`xgs-debian-npu`**（x86 那半是 `xgs-debian-x86`）。
- 镜像带 `/etc/fw_env.config`，`fw_printenv` / `fw_setenv bootcmd …` 直接可用。

## 网络（面板口怎么分）

全在 **`/etc/xgs87/net.conf`**，改完 `systemctl restart xgs-net-up xgs-dhcp`：

| 桥 | 面板口 | VLAN | 默认模式 |
|---|---|---|---|
| `br-wan` | `2/WAN`（`p2`） | 100 | `dhcp`，管理地址也走这条 |
| `br-lan` | `1/LAN`（`p1`） | 200 | `static 10.234.56.1/24`，**不发 DHCP** |

`p3`/`p4`/`p8` 默认不并入任何桥；想用前面板调试口就把 `p8` 加到 `LAN_PORTS`。

LAN 到 WAN 的转发和 masquerade 由 `xgs-nat`（自己的 `inet xgs87` nft 表）默认开着 ——
`10.234.56.0/24` 的设备把网关指到 `10.234.56.1` 就能上网。要整块撤掉：停这个单元再
`nft delete table inet xgs87`，不碰别人的规则。

## 变体（自己构建时选）

| 变体 | root 解开 | 1.5 GB 的 `p2` | 内核升级 |
|---|---|---|---|
| `full` | ~815 MiB | ❌ 装不下（占用 90%+） | 带 dkms，自动重编 |
| **`lean`（发布用）** | **~500 MiB / 191 MB 压缩** | ✅ 约三分之一 | 内核 `apt-mark hold`，升级见 `/opt/xgs87/kernel/npu/install.sh` |
| `base` | ~550 MiB | ⚠️ 勉强 | 装完自己跑一次 `kernel/npu/install.sh` |

```sh
sudo ./image/build.sh --arch arm64 --variant lean     # 必须在 arm64 上跑
```

`lean` 是"工具链编完就删"：模块在 `/lib/modules/<kver>/updates/`，编译器、headers、dkms 都不在镜像里。

## 起不来怎么办

维护 U 盘 [`debian-usb`](https://github.com/FusionPlmH/sophos-xgs87-dev/releases/tag/debian-usb)
菜单选 `2`，按**前提最容易满足**的顺序自动试：**ssh + dd** → **急救 initramfs**（串口把
急救包推进 NPU 内存，起来后由 x86 走面板口喂整盘影像）。急救包是本仓库 CI 打的那版
（约 10.9 MB，串口 ~19 分钟）；在本地用 `board/rescue-kernel.config` 自编可降到 2.1 MB。
两条都不通就转菜单 `4`（NPU 串口，`/dev/ttyS2`）。
细节见 [docs/06-rescue.md](https://github.com/FusionPlmH/sophos-xgs87-dev/blob/main/docs/06-rescue.md)。
