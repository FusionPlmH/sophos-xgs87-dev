# debian-npu — XGS 87 的 NPU 侧（Marvell CN9130，arm64）

`debian-npu.tar.zst` 是**根文件系统**，不是磁盘镜像 —— NPU 没有 ESP/GRUB，
U-Boot 直接从 eMMC 的一个 ext4 分区里 `ext4load` 内核和 DTB。

```sh
# 在正在跑的 NPU 上
mkfs.ext4 -L xgsroot /dev/mmcblk0p2          # ⚠️ 会清空 p2，确认没选错
mount /dev/mmcblk0p2 /mnt
zstd -dc debian-npu.tar.zst | tar -xpf - -C /mnt
cp cn9130-sophos-xgs87w-sfp10g.dtb /mnt/boot/
```

- 写到 **root 分区**（原厂布局是 `p2`，1.5 GB；`p1`/`p3` 留着回滚原厂系统）
- ⚠️ `full` 变体带 DKMS 工具链（约 500 MB），**1.5 GB 的 p2 装不下**：
  用 `--variant base`（约 224 MB），或者把 root 分区做到 ≥3 GB
- 登录：**`admin` / `P@ssw0rd`**（带 sudo）。**没有 root 账户**，SSH 拒绝 root 登录
- `/boot/Image`、`/boot/initrd.img` 由内核 postinst 钩子维护，升级内核不用改 U-Boot env
- 首次开机会把 root 分区扩到盘尾

U-Boot 的 `bootcmd` 见仓库 `docs/03-boot-chain.md`。

要重装或修复：维护 U 盘 [`debian-usb`](release-usb.md) 的菜单里选 `2`，它会通过 vNTB
把这个 tar 解到 NPU 的 root 分区（NPU 起不来时菜单会退化成 HTTP + 串口手动安装）。