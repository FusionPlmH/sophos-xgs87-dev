# debian-usb — XGS 87 的维护 / 诊断 U 盘

固定 release：每次跑 `image` workflow 的 usb 目标都会**覆盖**这里的资产和本文。

| 资产 | 是什么 | 实测 |
|---|---|---|
| `debian-usb.img.zst` | **整盘镜像**：可启动 U 盘，自带 x86 + NPU 两套安装包和串口菜单 | 解开约 1.6 GB（`lean`，2026-11-24 实测 1.56 GiB） |

插上从 U 盘启动，x86 串口上出菜单：格式化重装 x86、把新 rootfs 推给 NPU、备份内置盘、看状态。
这台双架构机器的急救盘——升级、刷坏、换系统都靠它。

## 里面是什么

| 分区 | 内容 |
|---|---|
| `p1` | ESP（64 MiB FAT32 + GRUB），能不能启动全靠它 |
| `p2` | 和 `debian-x86` 一样的 Debian root，多一个开机菜单和安装用的 payload（`/opt/xgs87/payload`） |
| `p3` | **第一次开机才切**：U 盘上剩下的全部空间，做成 `exfat`（标签 `XGS87BAK`），挂到 `/media/xgs87-bak` 存备份 |

镜像里只有 `p1` + `p2` 两个分区，安装用的 `debian-x86.img.zst` / `debian-npu.tar.zst` / DTB /
脚本都在 root 的 `/opt/xgs87/payload` 里。所以**不用预估"给备份留多少"**：32 GB 的盘装完
不到 1.5 GB 的系统，剩下 30 GB 第一次开机自己变成备份区；换 128 GB 的盘也不用重建镜像。

> ⚠️ 维护盘上的 `xgs87-growroot` 是**故意关掉**的（`installer/mkusb.sh` 直接删掉它的 enable 符号链接）：
> 分区是构建时按 payload 大小撑开的，如果 growroot 再把它扩到整个 U 盘，`usbstore` 就没有
> 空间切备份分区了 —— 这两者在盘尾抢地方，2026-11-25 审查时发现并修掉。

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

1. 用 7-Zip 解压 `debian-usb.img.zst`，得到 `debian-usb.img`（约 1.6 GB）。
2. Rufus 选这个 `.img`，**分区类型 GPT、写入方式 DD 镜像**，开始写。
   Win32DiskImager 也行；**不要**用 Rufus 默认的 ISO 模式，它会把 ESP 改坏。

## 常见"看起来像失败"的输出

- `zstd: error 70 : Write error : cannot write block : Broken pipe`：这是写盘前**探测 LBA0 签名**
  时只读了 512 字节就停，压缩进程收到 EPIPE 的正常噪音。真正的写入紧跟在后面
  （`dd ... 695205888 bytes`），只要最后看到 `分区表回读正常` 就是成功。
  2026-11-25 之后的 payload 已经把这条噪音消掉，并在写完后加了一行 `LBA0 回读一致`。

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
| `2` 重装 NPU | 按**前提最容易满足**的顺序试：**ssh + tar**（NPU 有 tar/zstd）→ **ssh + dd**（NPU 只有 busybox `dd`，原厂系统就是这种）→ **U-Boot + tftp**（前两条都不行，需要 USB 网卡）→ **急救 initramfs**。NBD 那一级目前禁用 | 目标分区被整个重写；前两条路装完会回读校验 |
| `3` 查看状态 / 备份 / 挂 NPU 硬盘 | 子菜单：`1` 看状态，`2` 备份 x86 内置盘，`3` 备份 NPU 分区，`4` NBD 挂载（**已禁用**） | 备份只读；NBD 要自己把 nbd-client/server 装回 |
| `4` NPU 串口 | 打开 NPU 控制台（`/dev/ttyS2`，**115200**；老 image 内核 57600）。NPU 起不来、SSH 不通时从这里进；`picocom` 退出是 Ctrl-A Ctrl-X | 同一时刻只能有一个读者 |
| `5` shell | 直接进 root shell（U 盘系统） | — |
| `9` / `0` | 关机 / 重启 | — |

## 写 NPU 的几种办法，哪种该用在哪

| 办法 | 数据通道 | NPU 需要活着到什么程度 | 190 MB 大约要 | 适合 |
|---|---|---|---|---|
| **ssh + tar**（菜单 `2` 第 1 步） | vNTB，TCP | 还要 sshd、host key、tar/zstd | 1–2 分钟 | ✅ **首选**：NPU 跑着我们自己的镜像时最省事 |
| **ssh + dd**（菜单 `2` 第 2 步） | vNTB，TCP | 只要 sshd + busybox `dd` | 1–2 分钟 | ✅ **原厂系统就走这条**（实测它没有 tar/zstd，也装不上 nbd-server） |
| **U-Boot `tftpboot` + `mmc write`**（菜单 `2` 第 3 步） | 网线（x86 的 USB 网卡 → 面板口，交换机在 U-Boot 里默认转发） | 停在 `=> ` 即可，**不依赖任何用户态** | 1 Gbit/s 下 ~1 分钟 | ✅ NPU 全废（连 sshd 都没有）时的路，但要插 USB 网卡 |
| **NBD**（菜单 `2` 的 NBD 级 / 子菜单 `3`→`4`） | vNTB，块级 TCP | 能跑到用户态、能起 `nbd-server` | 1–2 分钟 | ⛔ **镜像里禁用**（没带 nbd-client/server）；要备份/fsck 先用 `ssh+dd` 或自己把 NBD 装回 |
| U-Boot `ext4load`/`ext4write` | 只能读它自己看得见的介质（eMMC 的 p1/p3、SD） | 停在 `=> ` 即可 | 取决于数据从哪来 | ✅ **救 bootcmd/env/DTB、验证分区可读、在 eMMC 内部搬文件** |
| U-Boot `tftpboot` | 网口（end0→交换机，或 `mvswitch` 拉起 SFP port9） | 同上 | 10G 时很快 | ⚠️ 得先有 SFP 模块 + TFTP 服务，交换机在 U-Boot 里没初始化 |
| U-Boot `loady`（串口 YMODEM） | 串口 115200 | 同上 | **几个小时** | ❌ 只适合几百 KB 的 DTB |
| 串口 shell 命令 | 串口 | 用户态 | 传输不可行，命令可以 | ✅ 修网络、修 sshd、手动 `wget`/`dd` |

**结论**：先试 **ssh + tar / ssh + dd**（都不动 NPU、不需要插网卡，`dd` 那条对原厂系统也成立）；
两条都失败才轮到 **U-Boot（tftpboot + mmc write，需要插 USB 网卡做物理旁路）**，最后是**急救包**。
NBD 目前禁用，别把它当默认退路。
U-Boot 还能做 ssh 路径做不到的事：`setenv bootcmd 'run bootcmd_emmc1'; saveenv` 换回 p1 的原厂系统、
修 `bootargs`、用 `mmc part` / `ext4load` 确认分区到底还在不在。

> ⚠️ **NPU 停在 U-Boot 时 vNTB 是断的**。x86 自己没有网口，那两条 VLAN（`eth0.100`/`eth0.200`）
> 全在 NPU 的 Linux 里 —— NPU 一进 U-Boot，x86 立刻没网、没默认路由。
> 所以 U-Boot 那条路的数据只能走 **物理旁路**：x86 的 USB 网卡 → 网线 → 面板口 → 交换机 → NPU `end0`
> （交换机在 U-Boot 里是默认转发状态，够用）。脚本因此**先确认有载波网口才去停 NPU**，
> 没网卡就直接退出，免得把机器停在"NPU 在 U-Boot、x86 又没网"的死角里。
> 串口（`/dev/ttyS2`）全程不受影响 —— 它不经过 PCIe。

`2` 在写之前会问一句"要先备份吗"，答 `Y` 就跑子菜单 `3`→`2`/`3` 的备份流程；
**备份失败会中止，不会格式化**。选项 `2` 在 NPU 起不来时退化成急救 initramfs，
按屏幕提示在 NPU 控制台（x86 的 `/dev/ttyS2`，**115200**）里操作；如果 x86 那边连
IPv4 地址都还没有（vNTB 没起来），它会直接告诉你去看 `ip -br a`，而不是硬绑一个不存在的地址。

## 急救包（NPU 起不来、也没有 USB 网卡时）

`/opt/xgs87/payload/xgs87-rescue.tar.zst`，由 `tools/build/build-rescue.sh` 从 `debian-npu.tar.zst`
里就地组装（不需要交叉编译）：

| 内容 | 大小 | 为什么需要 |
|---|---|---|
| `Image.gz` | **13.7 MB** | NPU 的内核（37.7 MB 的 Image 压过），U-Boot 用 `unzip` 解开 |
| `initramfs.gz` | **1.84 MB** | 静态 busybox（`wget`/`dd`/`ip`/`modprobe`）+ 9 个模块（EP、ntb、mmc、vlan）+ `/init` |
| `cn9130-…dtb` | 21 KB | 板级设备树 |
| 合计 | **≈15 MB** | 串口推得动 |

`/init` 只做三件事：拉起 vNTB 端点 → 给裸 `eth0` 配 `10.234.56.1/24` → 从 x86
`wget` 整盘影像并 `dd` 到 `p2`，然后 `reboot -f`。

**为什么不用 NBD/TFTP 做 initramfs**：那要把 `nbd-server`（glibc + 依赖，约 4 MB）或
TFTP 客户端塞进去，而 busybox 的 `wget`+`dd` 已经把这条链走完 —— 1.8 MB vs 6 MB，
而且 HTTP 比 TFTP 好传大文件（能续、能看到进度）。

串口耗时：15 MB 在 **115200 ≈ 24 分钟**，`BAUD=460800` 时 **≈6 分钟**。
要提速就改 U-Boot 的 `baudrate`：**在 NPU 的 Linux 里用 `fw_setenv baudrate 460800`**（它会先擦后写），
x86 侧相应把 `BAUD=460800`。别在 U-Boot 提示符下反复 `saveenv` —— 那颗 NOR 的 env 写入不先擦除，
连续写会把 env 写成半截（[docs/23](../docs/23-mcp2210-spi-nor.md) §23.7）。
（U-Boot 自己配置这个速率；老 image 内核的 2x 分频问题不适用于 U-Boot。）

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
