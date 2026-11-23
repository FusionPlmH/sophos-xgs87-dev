# debian-x86 — XGS 87 的 x86 侧（16 GB eMMC，UEFI）

`debian-x86.img.zst` 是**整盘镜像**（GPT + ESP + ext4 + GRUB），不是一个分区。

```sh
zstd -d debian-x86.img.zst
sudo dd if=debian-x86.img of=/dev/sdX bs=4M conv=fsync status=progress
```

- 写到**整块盘**：`/dev/sdX` / `/dev/mmcblk0` / `/dev/nvme0n1` —— **不要**写到 `...p1` 这类分区
- 布局：`p1` = ESP 476 MiB (FAT32)，`p2` = root (ext4)
- 镜像按实际内容生成（约 1.7 GB：1.2 GB root + 476 MiB ESP），**首次开机会自动把 p2 扩到盘尾**（`xgs87-growroot.service`）
- 登录：**`admin` / `P@ssw0rd`**（带 sudo）。**没有 root 账户**，`root` 已锁定、SSH 拒绝 root 登录
- 串口：RJ45 或 micro-USB，115200 8N1
- 没有内置网口，唯一 netdev 是 vNTB，要等 NPU 起来才有网络

想自己改内容：`./image/build.sh --arch amd64 --variant base|full`

刷坏了要重装：用维护 U 盘 [`debian-usb`](release-usb.md)——插 U 盘、开机选它启动，
串口菜单里选 `1`，它会把这个镜像整盘写回 eMMC。