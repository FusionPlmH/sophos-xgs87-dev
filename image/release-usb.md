# debian-usb — XGS 87 的维护 / 急救 U 盘

每次跑 `image` workflow 的 **usb** 目标都会覆盖这里的资产和本文。

| 资产 | 是什么 | 体积 |
|---|---|---|
| `debian-usb.img.zst` | **整盘镜像**：能启动的 x86 Debian + NPU 安装包 + 急救包 + 串口菜单 | 压缩 **615 MB**，解开 **1.16 GiB** |

这台机器是 x86 + NPU 双 SoC，自带串口菜单；升级、刷坏、换系统都用这张盘。

## 里面是什么

| 分区 | 内容 |
|---|---|
| `p1` | ESP（128 MiB FAT32 + GRUB）。**BIOS 执行的就是这里的 `\EFI\BOOT\BOOTX64.EFI`** |
| `p2` | 和 `debian-x86` 同源的 Debian root + 菜单 + payload（`/opt/xgs87/payload`） |
| `p3` | **第一次开机才切**：盘上剩余空间做成 exfat（标签 `XGS87BAK`），挂 `/media/xgs87-bak` |

镜像里只有 `p1` + `p2`（payload 有 `debian-x86.img.zst`、`debian-npu.tar.zst`、DTB、急救包和脚本）。
剩余空间第一次开机自动变成备份区，换多大的盘都不用重建镜像。

> ⚠️ 维护盘上的 `xgs87-growroot` 是**故意关掉**的（`mkusb.sh` 删掉 enable 符号链接）：
> 分区已按 payload 撑开，growroot 再扩到盘尾就没地方切备份区了。

## 写进 U 盘

> 每条命令都**整条盘覆盖**。先 `lsblk` / `diskutil list` 确认目标盘。

```sh
zstd -d debian-usb.img.zst
lsblk
sudo dd if=debian-usb.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

Windows：7-Zip 解出 `.img`（1.16 GiB）→ Rufus 选它、**分区 GPT、写入方式 DD 镜像**；
Etcher 直接选 `.img`。**不要用 ISO 模式**——它会重排分区、把 ESP 里的兜底启动器弄没，
表现是"BIOS 认得出 U 盘、一个字符不打就 reset"。

写完自检（可选但强烈建议）：`sfdisk -d /dev/sdX` 能读出分区表，且 ESP 的 `\EFI\BOOT\`
里有 `BOOTX64.EFI` —— 构建时 `mkdisk.sh`/`mkusb.sh` 都断言这一条，写坏了它就只能进 BIOS。

## 启动与菜单

1. U 盘插**前面板** USB（那颗是 x86 的，不是 NPU 的）。
2. 开机按 **Esc** 进 BIOS，在 **Boot** 页把 U 盘排到第一位（串口重定向只转发 Esc，
   F 键不转发，所以别指望串口上按 F7）。BIOS 执行的是 ESP 里那条兜底路径
   `\EFI\BOOT\BOOTX64.EFI`，NVRAM 项丢了也能起。
3. x86 控制台（RJ45 或 micro-USB，**115200 8N1**）上出菜单。

| 选项 | 做什么 | 风险 |
|---|---|---|
| `1` 装 x86 | 把 payload 里的 `debian-x86.img` 整盘写进**内置盘**，写前先问要不要备份 | 整盘覆盖 |
| `2` 装 NPU | 自动按 **ssh + dd** → **急救 initramfs** 逐级试；写前回读校验 | 目标分区被重写 |
| `3` 看状态 / 备份 | 子菜单：看状态、备份 x86 内置盘、备份 NPU 分区 | 只读 |
| `4` NPU 串口 | NPU 控制台（`/dev/ttyS2`，115200）；`picocom` 退出是 Ctrl-A 再 Ctrl-X | 同一时刻只能一个读者 |
| `5` shell / `9` 关机 / `0` 重启 | — | — |

## U 盘对 NPU 能做什么

| NPU 的状态 | U 盘能做 | 还缺什么 |
|---|---|---|
| 用户态活着 | ✅ 整盘重写 p2（vNTB + ssh + dd，1.6 GiB ≈ 45 秒） | 无 |
| 只剩 U-Boot | ✅ 把急救系统推进内存（`/dev/ttyS2` 在 x86 上，不用第二个人敲串口） | **一台带网口的机器接面板口**：x86 自己没有网口（`lspci` 里没有任何 Ethernet，`eth0` 是 vNTB 虚拟网卡），没法同时当"串口驱动方"和"HTTP 服务方" |
| U-Boot 也没了 | ✅ x86 上的 MCP2210 直接写 SPI NOR | 无 |

**别在这些方向上白花时间**：U-Boot 的 `tftpboot`/`ping` 实测完全不通（2026-11-25 证伪，脚本已删）；
"ssh + tar 流式解包"和 NBD 也删了——前者要在正挂着的根分区上 `mkfs`，内核必拒；后者两个镜像都没带
`nbd-client`/`nbd-server`，从未跑通。

> ⚠️ **NPU 停在 U-Boot 时 vNTB 是断的**：那两条 VLAN 都在 NPU 的 Linux 里，NPU 一进 U-Boot，
> x86 立刻没网、没默认路由。所以 U-Boot 那条路的数据只能走物理旁路（x86 的 USB 网卡 → 面板口），
> 脚本会**先确认有载波网口才去停 NPU**。串口全程不受影响，它不经过 PCIe。

## 急救包（NPU 起不来、也没有 USB 网卡时）

`/opt/xgs87/payload/xgs87-rescue.tar.zst`，由 `tools/build/build-rescue.sh` 组装：

| 内容 | 体积 | 说明 |
|---|---|---|
| `Image.lzma` | **1.63 MB**（5.36 MB 未压缩） | U-Boot 用 `lzmadec` 解——**这台固件的 `unzip` 只认 gzip** |
| `initramfs.xz` | **0.47 MB** | 裁剪过的静态 busybox（52 个 applet）+ `/init`；xz 由内核自己解 |
| `cn9130-…dtb` | 21 KB | 板级设备树 |
| 合计 | **2.1 MB** | 115200 的 YMODEM ≈ 9.8 KiB/s → **3.6 分钟** |

上面是本地拿 `board/rescue-kernel.config` 自编的版本。CI 里没有自编内核，会退回 Debian 的
arm64 内核，整包约 **10.9 MB**（`Image.lzma` 9.8 + `initramfs.xz` 0.47 + DTB，串口要推
~19 分钟）—— 所以急救包值得在本地编。

`/init` 只做三件事：找网口（面板口 p1/p2 或 vNTB 的 `eth0`）→ 配地址 → 从 HTTP `wget`
整盘影像并 `dd` 到 `p2`，然后 sysrq-b 硬重启。想只验证"能不能起来、面板口通不通"：

```sh
RESCUE_PROBE=1 sh /opt/xgs87/payload/npu-rescue.sh     # 不建镜像、不写盘，跑完自己重启
```

⚠️ **给内核清零的"一次性信标"只能指向 DTB，不能指向 `Image.lzma`** ——
那等于让 `lzmadec` 去解一段坏流。见 `installer/payload/rescue-init` 里的注释。

要提速就改 U-Boot 的 `baudrate`：在 NPU 的 Linux 里 `fw_setenv baudrate 460800`，x86 侧把
`BAUD=460800`。别在 U-Boot 提示符下反复 `saveenv` —— 那颗 NOR 的 env 写入不先擦除，
连写会把 env 写半截。

## 自己构建

```sh
sudo ./image/build.sh --arch amd64 --variant lean --out out/xgs87-x86-lean.tar.zst
sudo ./image/mkdisk.sh --rootfs out/xgs87-x86-lean.tar.zst --out out/debian-x86.img
zstd -T0 -10 --rm out/debian-x86.img
bash ./tools/build/build-rescue-busybox.sh            # 可省略：省则退回 Debian 的 busybox-static
sudo bash ./tools/build/build-rescue.sh --npu out/debian-npu.tar.zst --out out/xgs87-rescue.tar.zst
sudo bash ./installer/mkusb.sh \
    --x86 out/debian-x86.img.zst --npu out/debian-npu.tar.zst \
    --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
    --rescue out/xgs87-rescue.tar.zst --out out/debian-usb.img
```

`.github/workflows/image.yml`（`target=usb`）跑的就是这串：amd64 runner 出 x86 整盘镜像、
arm64 runner 出 NPU rootfs + DTB，第三个 job 编 busybox、打急救包、拼盘，产物覆盖发布到 `debian-usb`。

细节见 [docs/](https://github.com/FusionPlmH/sophos-xgs87-dev/tree/main/docs)：
`04-install`（从原厂 SFOS 第一次装）、`06-rescue`（三级救砖）。
