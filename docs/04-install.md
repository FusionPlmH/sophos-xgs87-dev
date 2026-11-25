# 04 装机

两种介质：**维护 U 盘**（能救机器、能重装两台）和**整盘镜像**（只装 x86）。
NPU 只有一条路：从 x86 这边把字节灌进它的 p2。

## 维护 U 盘

`out/debian-usb.img.zst` → 解压后 `dd` 到 U 盘 → x86 从它启动 → 菜单（`xgs87-menu.sh`）：

| 选项 | 干什么 | 风险 |
|---|---|---|
| `1` 重装 x86 | 把 `debian-x86.img` 整盘写进 x86 内置盘 | 整盘覆盖 |
| `2` 重装 NPU | 见下面「刷 NPU 的两级阶梯」 | 目标分区被整个重写 |
| `3` 状态 / 备份 | 看状态、备份 x86 内置盘或 NPU 分区 | 只读 |
| `4` NPU 串口 | `picocom -b 115200 /dev/ttyS2`（`picocom` 退出是 Ctrl-A Ctrl-X） | 同一时刻只能有一个读者 |
| `5` shell / `9` 关机 / `0` 重启 | — | — |

U 盘的 payload 在 root 分区的 `/opt/xgs87/payload/`（`installer/payload/` 整个拷进去），
盘尾还有一个 `XGS87BAK` 的 exfat 分区放备份。

## 刷 x86

菜单 `1`，或者手工：

```sh
zstd -dc out/debian-x86.img.zst | dd of=/dev/mmcblk0 bs=1M conv=fsync status=progress
```

镜像自带 GPT + ESP + GRUB，写完直接能启动。首次开机 `xgs87-growroot.service` 把根扩到盘尾。

## 刷 NPU 的两级阶梯

**只留能走通的两级**（第三级"U-Boot + tftp"已在 2026-11-25 证伪并从仓库删除：那台 U-Boot
的网络完全不通 —— 面板口 link/VLAN/PVID 全对，ARP 和 TFTP RRQ 都收不到；而且它会先把 NPU
停进 U-Boot、vNTB 一断就没退路）。

### 第 1 级：x86 上 ssh + dd（日常）

```sh
NPU=10.234.56.1 sh installer/payload/npu-sshdd.sh          # 从 tar 造镜像再写
SRC=/mnt/usb/p2.img NPU=10.234.56.1 sh installer/payload/npu-sshdd.sh   # 写现成镜像
```

前提：NPU 用户态活着（sshd 或串口 shell），x86 的 vNTB 通。

**硬守卫**：脚本会读 NPU 的 `findmnt -n -o SOURCE /`，如果**目标分区正是 NPU 现在的根**，
直接拒绝 —— 在活着的根上 `dd` 会把它写成碎片（2026-11-25 事故就是这么来的）。
要写，就让 NPU 从**别的**系统起来（p3 原厂 或 急救 initramfs），或者明确
`ALLOW_LIVE_ROOT=yes`（先把整盘镜像备份到别处）。

### 第 2 级：串口急救 + 面板口（最后手段）

p2 起不来、sshd 没有、x86 只剩串口时用这条。**U 盘在这里只能帮一半**：从 U 盘启动的
x86 可以直接在 `/dev/ttyS2` 上敲 NPU 的 U-Boot、把急救内核推进去（不用另一个人敲串口），
但**镜像得由一台带网口的机器提供** —— x86 自己没有网口（`lspci` 里没有任何 Ethernet 控制器）。
完整 runbook 见 [06 救砖](06-rescue.md) §"第 2 级"。
一句话版本：x86（或 PC）推 3.1 MB 进 RAM（YMODEM，约 6 分钟）→ 急救系统起来后走面板口按
1 Gb/s 拉整盘 → `dd` 进 `/dev/mmcblk0p2` → 校验 → 重启。

## 装完必须确认的三件事

```sh
ssh admin@10.234.56.1 'findmnt -n -o SOURCE /; systemctl --failed --no-legend'   # p2 + 空
ssh admin@10.234.56.1 'df -h /'                                                  # 1524 MiB 用完就满
ip -br a | grep -E 'eth0\.(100|200)|br-'                                         # 两条 VLAN 都在
```

- 从 x86 第一次 ssh 会撞 host key：`-o StrictHostKeyChecking=accept-new`，或者先删掉
  `~/.ssh/known_hosts` 里那一行。
- **NPU 重装/重启之后，x86 的 vNTB 不会自己回来** → 重启一次 x86（见 [05](05-operations.md)）。
- 如果镜像里没带 ssh host key 又没跑 `ssh-keygen -A`，会表现为"网络通但 ssh 连不上"。
