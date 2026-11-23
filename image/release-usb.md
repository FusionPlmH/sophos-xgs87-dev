# debian-usb — XGS 87 的维护 / 诊断 U 盘

`debian-usb.img.zst` 是一条**自带两套系统安装包的可启动 U 盘**。插到机器上从 U 盘启动，
串口控制台上出一个菜单：格式化并重装 x86、把新 rootfs 推给 NPU、备份 x86 内置盘、看状态。
它是这台双架构机器的"急救盘"，平时升级、刷坏、换系统都用它。

## 里面是什么

| 分区 | 内容 |
|---|---|
| `p1` | ESP（476 MiB FAT32 + GRUB），U 盘能不能启动全靠它 |
| `p2` | 和 `debian-x86` 一样的 Debian root，只多了一个开机菜单（不写回内置盘，只用来跑菜单） |
| `p3` | 标签 `XGS87` 的 ext4 payload：`debian-x86.img.zst`、`debian-npu.tar.zst`、DTB、`installer/payload/*.sh` |

镜像约 1.0 GB（zst），解开约 2.5 GB，写到 8 GB 以上的 U 盘即可。

## 写进 U 盘

> ⚠️ 下面每条命令都会**整条盘覆盖**。先 `lsblk` 确认目标盘，别写到系统盘上。

**Linux / macOS**

```sh
zstd -d debian-usb.img.zst
lsblk                                  # 找到 U 盘，例如 /dev/sdb / /dev/disk4
sudo dd if=debian-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

macOS 用 `diskutil list` 找盘，然后 `sudo dd if=debian-usb.img of=/dev/rdisk4 bs=4m`。

**Windows**

1. 用 7-Zip 解压 `debian-usb.img.zst`，得到 `debian-usb.img`（约 2.5 GB）。
2. 用 Rufus 选择这个 `.img`，**分区类型选 GPT、写入方式选 DD 镜像**，开始写入。
   Win32DiskImager 也可以；**不要**用 Rufus 默认的 ISO 模式，它会把 ESP 改坏。

## 启动

1. U 盘插到前面板 USB（那颗是 x86 的 USB，不是 NPU 的）。
2. 开机进 BIOS 启动菜单（AMI，一般按 **F11**；进 BIOS 是 **Del**），选 U 盘。
   如果 U 盘没出现在列表里：BIOS → Boot → 关掉 CSM/安全启动再试。
3. x86 控制台（RJ45 或 micro-USB，**115200 8N1**）上会出现菜单。
   串口没输出时，进 BIOS → Advanced → Console Redirection 打开。

## 菜单

| 选项 | 做什么 | 风险 |
|---|---|---|
| `1` 重装 x86 | 把 payload 里的 `debian-x86.img` 整盘写进**内置盘**（eMMC） | 整盘覆盖，原分区表和系统没了 |
| `2` 重装 NPU | 通过 vNTB 把 `debian-npu.tar.zst` 解到 NPU 的 root 分区（默认 `/dev/mmcblk0p2`） | 目标分区被 `mkfs.ext4` |
| `3` 查看状态 | 磁盘、vNTB 链路、NPU 是否可达、SSH 通不通 | 只读 |
| `4` 备份 x86 | 把内置盘整盘读成 `.img.gz` 写到 U 盘的 payload 分区 | 需要 U 盘剩余空间 ≥ 内置盘 |
| `5` shell | 直接进 root shell（U 盘系统） | — |
| `9` / `0` | 关机 / 重启 | — |

选项 2 在 NPU 起不来时会退化成"起 HTTP 服务"，然后按屏幕提示在 NPU 控制台
（x86 的 `/dev/ttyS2`，57600）里手动 `wget` + `tar` 安装。

重装完 x86 后，首次开机会自动把 root 分区扩到盘尾（`xgs87-growroot.service`）。
登录：**`admin` / `P@ssw0rd`**（`sudo` 要密码），`root` 已锁定、SSH 拒绝 root。

## 从原厂 SFOS 第一次装 Debian

SFOS 里没有第二个系统盘可以原地覆盖，所以走这条 U 盘：先备份（SPI 的 `mtd0`/`mtd1`
和 eMMC），再从 U 盘启动重装。SFOS 高级 shell、备份和串口波特率的细节见
[docs/22-from-sfos.md](../docs/22-from-sfos.md)。

## 自己构建

```sh
sudo ./image/build.sh --arch amd64 --variant full --out out/xgs87-x86-full.tar.zst
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-full.tar.zst --out out/debian-x86.img
sudo ./installer/mkusb.sh \
    --x86 out/debian-x86.img.zst \
    --npu debian-npu.tar.zst \
    --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
    --out out/debian-usb.img
```

CI 的 `.github/workflows/image-usb.yml` 跑的就是这串：两个原生 runner 各编一半，
第三个 job 拼盘，产物覆盖发布到这个 `debian-usb` release。
