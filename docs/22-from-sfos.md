# 22 — 从原厂 SFOS 换成这套 Debian

这台机器的两个系统都能换，但入口不一样：**x86 只能从外部介质启动后整盘重写**，
**NPU 可以从旁边推过去**。原厂 SFOS 里没有第二个可写的系统盘，所以第一次换系统
走维护 U 盘（`debian-usb`），之后升级也用它。

参考项目：[nicologiuliani6/openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)。
它从 SFOS 的高级 shell 里用 `curl` 拉安装脚本，把 OpenWrt 写进 SFOS 的 swap 分区、
再加一条 GRUB 启动项；NPU 侧通过内部链路写 `mmcblk0p1` 并改 U-Boot 环境。思路可以借用，
但我们的镜像是**整块 GPT 盘**（ESP + GRUB + ext4），没法从正在运行的 SFOS 原地 dd，
所以 x86 侧换成"U 盘启动 → 整盘写回"。

## 22.1 先备份，再动手

最少要留这三样（`reference/` 里有脱敏后的样本，确认格式对得上）：

| 位置 | 怎么拿 |
|---|---|
| SPI NOR `mtd0`（U-Boot）、`mtd1`（环境） | NPU 上 `cat /dev/mtd0 > mtd0-uboot.bin`、`cat /dev/mtd1 > mtd1-env.bin`，或 `fw_printenv` 导出文本 |
| NPU eMMC | 在能启动的系统里 `dd if=/dev/mmcblk0 of=...`，至少把原厂 `p3` 留下 |
| x86 eMMC | 维护 U 盘菜单的 `1`（整盘 `debian-x86.img`），或者在 SFOS 里 `dd` 到网络盘 |

U-Boot 的 `bootcmd` 指向 `mmc 0:3`，原厂系统在 p3；只要不动 `mtd0`，uboot 就还在，
刷坏了还能从串口救。

## 22.2 进 SFOS 的高级 shell（需要用它的时候）

串口登进 SFOS 的 x86：账号 `admin`，菜单 **5**（Device Management）→ **3**（Advanced Shell）。
到了 shell 就有 root，能 `curl`、`dd`、`fw_printenv`。

> 波特率：参考项目那台 XGS 107w 在 SFOS 下是 **38400**，我们这台现在是 **115200**；
> 没输出就两个都试。`COM5`（RJ45）和 micro-USB 是同一个 UART，只能接一个。

这个 shell 能做的事：

```sh
# 从 PC 上取文件（PC 上先 python3 -m http.server 8000）
curl -fsS http://PC:8000/debian-npu.tar.zst -o /dev/shm/npu.tar.zst

# 看机器到底有几个盘、分区表长什么样
lsblk; sfdisk -d /dev/mmcblk0

# 备份 NPU 环境（如果 ttyS2 那头能登进去）
```

**它不能做的事**：把自己的根盘 `dd` 掉再重启 —— 所以 x86 侧的 Debian 只能从 USB 启动后写。

## 22.3 推荐路径：维护 U 盘

1. 在 PC 上生成或下载 `debian-usb.img.zst`，写到 U 盘（步骤见
   [image/release-usb.md](../image/release-usb.md)）。
2. U 盘插前面板 USB，开机按 **F11** 选 U 盘启动。
3. 串口 115200 上出菜单：
   - `1` 重装 x86 —— 把 `debian-x86.img` 整盘写进内置 eMMC；
   - `2` 重装 NPU —— 自动按 **ssh+tar → ssh+dd → U-Boot+tftp → 急救 initramfs** 逐级尝试
     （NBD 目前禁用；网络到不了就先走 `ttyS2` 串口，菜单 `4` 能直接开）。
4. 写 NPU 时默认目标是 `/dev/mmcblk0p2`。**想保留原厂回滚就留在 p2**；
   U-Boot 的 `bootcmd` 指向 p3，改过 `bootcmd` 的机器要确认它指向你装的那个分区。
5. 装完重启，x86 首次开机自动扩分区，NPU 由 U-Boot 拉起。

## 22.4 没有 U 盘启动时

BIOS 不认 U 盘（或者手头没有 U 盘）时，只能先换 NPU，x86 留在 SFOS：

- NPU：在 SFOS 高级 shell 里起 `python3 -m http.server`，然后从 NPU 控制台
  （x86 的 `/dev/ttyS2`，**115200**；老 image 内核用 57600）用 `wget` 拉
  `debian-npu.tar.zst`，`mkfs.ext4` + `tar -xpf` 到一个空闲分区，再改 U-Boot 的
  `bootcmd` 指过去。命令模板在
  [installer/payload/install-npu.sh](../installer/payload/install-npu.sh) 的“不可达”分支里。
- x86：需要另一次从外部介质启动（USB 或网络 PXE）。SFOS 的 swap 分区方案（参考项目那样）
  只适合"把 rootfs 塞进 swap + 加 GRUB 项"，不适合我们这套带 ESP 的整盘镜像。

## 22.5 换完之后

- 两个系统都不再依赖 SFOS；`mtd0`（U-Boot）没动过，`mtd1` 的 `bootcmd` 决定 NPU 从哪个分区起。
- 想回原厂：把备份的 eMMC 镜像写回对应分区，`fw_setenv bootcmd` 指回原厂槽位。
- 这一步之后，升级/修复都走维护 U 盘，不用再进 SFOS。
