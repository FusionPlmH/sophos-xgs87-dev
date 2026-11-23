# debian-usb — XGS 87 的维护 / 诊断 U 盘

固定 release：每次跑 `image` workflow 的 usb 目标都会**覆盖**这里的资产和本文。

| 资产 | 是什么 | 实测 |
|---|---|---|
| `debian-usb.img.zst` | **整盘镜像**：可启动 U 盘，自带 x86 + NPU 两套安装包和串口菜单 | 解开 ~2.5 GB |

插上从 U 盘启动，x86 串口上出菜单：格式化重装 x86、把新 rootfs 推给 NPU、备份内置盘、看状态。
这台双架构机器的急救盘——升级、刷坏、换系统都靠它。

## 里面是什么

| 分区 | 内容 |
|---|---|
| `p1` | ESP（476 MiB FAT32 + GRUB），能不能启动全靠它 |
| `p2` | 和 `debian-x86` 一样的 Debian root，只多一个开机菜单（不写回内置盘） |
| `p3` | 标签 `XGS87` 的 ext4 payload：`debian-x86.img.zst`、`debian-npu.tar.zst`、DTB、`installer/payload/*.sh` |

payload 是构建 workflow 当时选的那个变体（`full` / `lean` / `base`），所以 U 盘里装出来的
系统和你构建时选的一致。

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
2. Rufus 选这个 `.img`，**分区类型 GPT、写入方式 DD 镜像**，开始写。
   Win32DiskImager 也行；**不要**用 Rufus 默认的 ISO 模式，它会把 ESP 改坏。

## 启动

1. U 盘插到前面板 USB（那颗是 x86 的 USB，不是 NPU 的）。
2. 开机进启动菜单（AMI，一般 **F11**；进 BIOS 是 **Del**），选 U 盘。
   列表里没有 U 盘：BIOS → Boot → 关掉 CSM / 安全启动再试。
3. x86 控制台（RJ45 或 micro-USB，**115200 8N1**）上出现菜单。
   串口没输出：BIOS → Advanced → Console Redirection 打开。

## 菜单

| 选项 | 做什么 | 风险 |
|---|---|---|
| `1` 重装 x86 | 把 payload 里的 `debian-x86.img` 整盘写进**内置盘**（eMMC） | 整盘覆盖，原分区表和系统没了 |
| `2` 重装 NPU | 通过 vNTB 把 `debian-npu.tar.zst` 解到 NPU 的 root 分区（默认 `/dev/mmcblk0p2`）| 目标分区被 `mkfs.ext4`；**动手前会先问要不要备份** |
| `3` 查看状态 | 磁盘、vNTB 链路、NPU 是否可达、SSH 通不通 | 只读 |
| `4` 备份 x86 | 把内置盘整盘读成 `.img.gz` 写到 U 盘的 payload 分区 | 需要 U 盘剩余空间 ≥ 内置盘 |
| `6` 备份 NPU | 把 NPU 的分区（默认 `p2`）经 ssh 流式读成 `npu-p2-<时间>.img.gz` 写到 U 盘 | 需要 U 盘剩余空间 ≥ 分区；p2 正在使用时镜像像"断电"那样需 fsck |
| `5` shell | 直接进 root shell（U 盘系统） | — |
| `9` / `0` | 关机 / 重启 | — |

`2` 在写之前会问一句"要先备份吗"，答 `Y` 就跑和 `6` 完全相同的备份流程；**备份失败会中止，不会格式化**。选项 `2` 在 NPU 起不来时退化成"起 HTTP 服务"，然后按屏幕提示在 NPU 控制台（x86 的 `/dev/ttyS2`，57600）里手动 `wget` + `tar` 安装——如果 x86 那边连 IPv4 地址都还没有（vNTB 没起来），它会直接告诉你去看 `ip -br a`，而不是硬绑一个不存在的地址。

重装完 x86 后首次开机会自动把 root 分区扩到盘尾（`xgs87-growroot.service`）。
登录 **`admin` / `P@ssw0rd`**（`sudo` 要密码），`root` 已锁定、SSH 拒绝 root。

## 从原厂 SFOS 第一次装 Debian

SFOS 里没有第二个系统盘可以原地覆盖，所以走这条 U 盘：先备份（SPI 的 `mtd0`/`mtd1` 和 eMMC），
再从 U 盘启动重装。SFOS 高级 shell、备份、串口波特率的细节见
[docs/22-from-sfos.md](../docs/22-from-sfos.md)。

## 自己构建

```sh
sudo ./image/build.sh --arch amd64 --variant lean --out out/xgs87-x86-lean.tar.zst
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-lean.tar.zst --out out/debian-x86.img
zstd -T0 -10 --rm out/debian-x86.img
sudo ./installer/mkusb.sh \
    --x86 out/debian-x86.img.zst \
    --npu out/debian-npu.tar.zst \
    --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
    --out out/debian-usb.img
```

CI 的 `.github/workflows/image.yml`（`target=usb`）跑的就是这串：amd64 runner 出 x86 整盘镜像、
arm64 runner 出 NPU rootfs + DTB，第三个 job 拼盘，产物覆盖发布到 `debian-usb`。
