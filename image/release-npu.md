# debian-npu — XGS 87 的 NPU 侧（Marvell CN9130，arm64）

固定 release：每次跑 `image` workflow 的 npu 目标都会**覆盖**这里的资产和本文。

| 资产 | 是什么 | 实测 |
|---|---|---|
| `debian-npu.tar.zst` | **根文件系统 tar**，不是磁盘镜像 | `full` ~320 MB；`lean` **199 MB**（2026-11-24 实测） |
| `cn9130-sophos-xgs87w-sfp10g.dtb` | 板级设备树，必须和这版内核配套 | **21 KB**（20.6 KiB） |

NPU 没有 ESP、没有 GRUB：U-Boot 直接从 eMMC 的一个 ext4 分区里 `ext4load` 内核和 DTB
（bootcmd 见仓库 `docs/03-boot-chain.md`）。

装出来的系统主机名是 **`xgs-debian-npu`**（x86 那半是 `xgs-debian-x86`），登录 `admin` / `P@ssw0rd`。
镜像已带 `/etc/fw_env.config`，所以 `fw_printenv` / `fw_setenv bootcmd …` 直接可用。
体积差异（为什么 x86 的 `.img` 比这个 tar 大好几倍）见 [`debian-x86` 的说明](release-x86.md)。

## 安装

```sh
# 在正在跑的 NPU 上（或从维护 U 盘 chroot 进去）
mkfs.ext4 -L xgsroot /dev/mmcblk0p2          # ⚠️ 会清空 p2，先确认没有选错
mount /dev/mmcblk0p2 /mnt
zstd -dc debian-npu.tar.zst | tar -xpf - -C /mnt
cp cn9130-sophos-xgs87w-sfp10g.dtb /mnt/boot/
```

- 写到 **root 分区**：原厂布局是 `p2`（1.5 GB），`p1`/`p3` 留着回滚原厂 SFOS
- `/boot/Image`、`/boot/initrd.img` 由内核 postinst 钩子维护，升级内核不用改 U-Boot env
- 首次开机会尝试把 root 分区扩到盘尾；**如果它后面还有分区（本机 p3/p4）就跳过**，
  不会碰原厂回滚槽和 VPD
- 登录 **`admin` / `P@ssw0rd`**（`sudo`），**没有 root 账户**，SSH 拒绝 root 登录

## 网络（面板口怎么分）

开箱就是这样，全在 **`/etc/xgs87/net.conf`** 里，改完 `systemctl restart xgs-net-up xgs-dhcp` 生效：

| 桥 | 面板口 | VLAN | 默认模式 |
|---|---|---|---|
| `br-wan` | `2/WAN`（`p2`） | 100 | `dhcp`，管理也走这条地址 |
| `br-lan` | `1/LAN`（`p1`） | 200 | `static 10.234.56.1/24`，**不发 DHCP** |

`p3`/`p4`/`p8` 默认不并入任何桥；想用前面板调试口就把 `p8` 加到 `LAN_PORTS`。

## 变体（自己构建时选）

| 变体 | root 解开 | 1.5 GB 的 `p2` | 内核升级 |
|---|---|---|---|
| `full`（默认） | ~900 MB | ❌ 装不下（占用 90% 以上） | DKMS 自动重编 |
| `lean` | ~525 MB（x86 实测，arm64 同量级） | ✅ 约一半 | 内核被 `apt-mark hold`，升级见 `/opt/xgs87/kernel/npu/install.sh` |
| `base` | ~550 MB | ⚠️ 勉强 | 装完自己跑一次 `kernel/npu/install.sh` |

```sh
sudo ./image/build.sh --arch arm64 --variant lean     # 必须在 arm64 上跑
```

`lean` 是把工具链编完就删掉：模块在 `/lib/modules/<kver>/updates/`，编译器、headers、dkms
都不在镜像里。根分区不想扩到 3 GB 的话这就是默认选择。

## 出问题

维护 U 盘 [`debian-usb`](https://github.com/FusionPlmH/sophos-xgs87-dev/releases/tag/debian-usb)
菜单选 `2`：自动按 **ssh+tar → ssh+dd → U-Boot+tftp → 急救 initramfs** 逐级尝试
（NBD 目前禁用）。网络到不了 NPU 时，选项 `2` 会自己走 `ttyS2` 串口登录、问出它的
`br-lan` 地址和 VLAN、在 x86 上镜像同样的 VLAN 再重试；两条都不通时它会提示走急救包
（串口是菜单 `4`）。
