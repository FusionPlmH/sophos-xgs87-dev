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
| `p2` | 和 `debian-x86` 一样的 Debian root，多一个开机菜单和安装用的 payload（`/opt/xgs87/payload`） |
| `p3` | **第一次开机才切**：U 盘上剩下的全部空间，做成 `exfat`（标签 `XGS87BAK`），挂到 `/media/xgs87-bak` 存备份 |

镜像里只有 `p1` + `p2` 两个分区，安装用的 `debian-x86.img.zst` / `debian-npu.tar.zst` / DTB /
脚本都在 root 的 `/opt/xgs87/payload` 里。所以**不用预估"给备份留多少"**：32 GB 的盘装完
1.5 GB 的系统，剩下 30 GB 第一次开机自己变成备份区；换 128 GB 的盘也不用重建镜像。

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
| `4` 备份 x86 | 把内置盘整盘读成 `.img.gz` 写到 `/media/xgs87-bak` | 需要备份区 ≥ 内置盘 |
| `6` 备份 NPU | 把 NPU 的分区（默认 `p2`）经 ssh 流式读成 `npu-p2-<时间>.img.gz` 写到 `/media/xgs87-bak` | 需要备份区 ≥ 分区；p2 正在使用时镜像像"断电"那样需 fsck |
| `5` shell | 直接进 root shell（U 盘系统） | — |
| `7` NPU 串口 | 打开 NPU 控制台（`/dev/ttyS2`，57600）。NPU 起不来、SSH 不通时从这里进；`picocom` 退出是 Ctrl-A Ctrl-X | 同一时刻只能有一个读者 |
| `8` NPU 硬盘 | 让 NPU 用 `nbd-server` 导出它的 `p2`，在 x86 上变成 `/dev/nbd0`，可以 `mount` / `fsck -n` / `dd` | **默认只读**；`--rw` 要确认 NPU 没在使用该分区 |
| `9` / `0` | 关机 / 重启 | — |

`2` 在写之前会问一句"要先备份吗"，答 `Y` 就跑和 `6` 完全相同的备份流程；**备份失败会中止，不会格式化**。选项 `2` 在 NPU 起不来时退化成"起 HTTP 服务"，然后按屏幕提示在 NPU 控制台（x86 的 `/dev/ttyS2`，57600）里手动 `wget` + `tar` 安装——如果 x86 那边连 IPv4 地址都还没有（vNTB 没起来），它会直接告诉你去看 `ip -br a`，而不是硬绑一个不存在的地址。

## 备份区（`/media/xgs87-bak`）

第一次从 U 盘开机时，`xgs87-usbstore.service` 会：

1. 把 GPT 备份头搬到盘尾（`sgdisk -e`）——`dd` 到更大的盘之后它还在镜像原来的末尾；
2. 用 `sfdisk` 在剩下的空间上切一个 `p3`（能切多少切多少，盘尾留 1 MiB 给 GPT）；
3. `mkfs.exfat -n XGS87BAK` 并挂到 `/media/xgs87-bak`。

选 `exfat` 是为了插到 Windows / macOS 上也能直接读备份文件；单文件没有 4 GiB 上限，
`backup-x86.sh` 流出的是 `dd | gzip` 的 `.img.gz`，解压后是完整盘。手动跑一次：

```sh
sudo /usr/local/sbin/xgs87-usbstore.sh
```

U 盘和镜像一样大（没有剩余空间）时它只会打一行提示，菜单照常可用，只是备份选项会告诉你
没地方写。

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
