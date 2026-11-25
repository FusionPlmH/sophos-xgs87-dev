# 11 · 运维手册：开关机、复位、换盘

> 🏷 **状态（2026-11-25 复核）**：✅ 下面每条都在现机上走过一遍，代价也一并写上。

这份文档是**动手之前先读的那一份**：整机怎么重启、卡住了怎么复位、根分区怎么换。
子系统细节不在这里 —— vNTB 排障看 [09](09-vntb.md)，进不了机器看 [10](10-console.md)，
救砖看 [14](14-rescue.md)，红线清单在 [16](16-remaining-work.md) §16.4。

## 11.0 三十秒版本

| 我要… | 做什么 | 会不会牵连另一台 |
|---|---|---|
| 重启 x86 | `sudo systemctl reboot`（走 `xgs-ntb-stop.service` 干净道别） | **会**：x86 一断 PCIe，NPU 被 `PERST#` 复位（§11.1） |
| 重启 NPU | NPU 上 `sudo systemctl reboot` | 不会，但 x86 的 `eth0` 会停在 DOWN，`xgs-ntb-watch` 5 分钟后自己救回（§11.2.6） |
| 复位卡死的 NPU | 串口 SysRq：BREAK + `b`（§11.2.5） | 不会 |
| 复位卡死的 x86 | COM5 上 SysRq `s` 再 `b`（§11.2.5） | NPU 会被连带复位 |
| 换掉 NPU 的根分区 | 先读 §11.2，**绝对不要**对正在用的根 `dd` | — |
| 关机整机 | 两台都 `poweroff`，或直接断电（NPU 有干净卸载钩子） | — |

## 11.1 重启的真实代价（一次完整实测）

x86 侧已经做到干净关闭（`/dev/mmcblk0p2: clean`，不再有 journal recovery），启动 38 → 26 秒：

| 阶段 | 时间 | 说明 |
|---|---|---|
| firmware | 11.0 s | 主板 POST，改 BIOS 才能动 |
| loader | **2 s** | 原来是 18.2 s —— `recordfail=1` 时 GRUB 等 30 s，已加 `GRUB_RECORDFAIL_TIMEOUT=2` |
| kernel | 4.0 s | |
| userspace | 5.6 s | 我们的单元合计不到 1 s |

NPU 的 Linux 只要 **10.8 s**（kernel 3.8 + userspace 7.0），
`xgs-ports-up` → `xgs-vntb` → `xgs-net-up` → `xgs-dhcp` 串起来约 2.7 s。

### 11.1.1 NPU 仍会被牵连，但这是硬件的错

实测结论：**x86 一抽掉 PCIe 链路，NPU 就复位**，与我们做了什么无关：

| 试过的手段 | 结果 |
|---|---|
| 关机钩子先发 `COMMAND_LINK_DOWN` | x86 日志确认发出（`qp 0: Send Link Down`），NPU 仍复位 |
| NPU 侧 spad 读写加 `linkup` 守卫 | 守卫生效（不再 oops），仍复位 |
| 先把 EP 函数停掉（`start=0`）再重启主机 | EP 已停、主机安然无恙，NPU 仍复位 |
| 关掉 `panic_on_oops` / `hardlockup_panic` | 日志里连 panic 都没有，说明不是软件 panic |
| 看门狗状态 | `/sys/class/watchdog/watchdog0/state=inactive`，不是它 |

#### 11.1.1.1 ramoops + console 后端：这条路走不通（实测，自编内核已退役）

> 这一小节记录的是 2026-11-23 那版自编内核（带 `CONFIG_PSTORE_CONSOLE`）。
> 结论是 ramoops 在这块板子上没用，所以后来 NPU 又切回了发行版内核；下面的过程
> 只作为"为什么不用 ramoops"的证据。

给 NPU 的 DTB 加了 `ramoops`（DRAM 最后 1 MiB，`ramoops@7ff00000`），
并在 [board/](../board/) 的 DTS 里补了 `console-size = 0x80000` / `pmsg-size = 0x20000`，
同时**重编了 NPU 内核**把 `CONFIG_PSTORE_CONSOLE` / `CONFIG_PSTORE_PMSG` 从 `n` 改成 `y`
（`Image` 从 37.7 MB 变成 44.3 MB，`vermagic` 仍是 `6.12.117+deb13-arm64`，
`Module.symvers` 与 Debian 头包**逐字节相同**，所以所有自编模块不用重编）。

新内核上线后确认 console 后端真的挂上了：

```
[    6.524286] printk: legacy console [ramoops-1] enabled
[    6.536984] pstore: Registered ramoops as persistent store backend
[    6.543247] ramoops: using 0x100000@0x7ff00000, ecc: 0
```

然后照原样复现（从 x86 侧 `systemctl reboot`）：

```
npu uptime: 0 min        ← 又被牵连复位了
pstore: 0 records         ← console 后端明明在跑，却一条都没留下
```

**为什么**：这颗 SoC **每次复位都会重跑 BootROM → `mv_ddr` 训练 + 全内存 scrub**
（见 [03 §3.1](03-boot-chain.md) 的启动日志 `mv_ddr: scrubbing memory...`）。
保留区在 Linux 还没起来之前就被清干净了，所以 **ramoops 在这块板子上永远读不到上一次的内容**，
不管它是 panic、硬锁死还是 PERST# 复位。

#### 11.1.1.2 改用 netconsole（现在用的方案）

既然"事后读内存"不行，就改成"**事发前就把每一行 printk 送出去**"：

| 端 | unit | 做法 |
|---|---|---|
| NPU | `xgs-netconsole.service` | `modprobe netconsole`，双目标都走 `br-lan`：①`10.234.56.2`（x86）②`10.234.56.50`（操作者的 PC，示例地址/MAC，按你自己的监听机改） |
| x86 | `xgs-netconsole.service` | `nc -u -l -k 6666` → `/var/log/npu-netconsole.log` |
| PC | [tools/on-pc/netconsole-listen.py](../tools/on-pc/netconsole-listen.py) | 收 UDP 6666 存文件 |

- 打两个目标的原因：**走管理 VLAN 的那个能在 NPU 硬锁死时把日志送出来**（那一刻 PCIe 链路还活着）；
  **走 `br-lan` 的那个能在 NPU 整个复位、PCIe 全掉之后继续工作**（只要交换机和线还在）。
- 实测：`echo test > /dev/kmsg` 后 x86 立刻在 `/var/log/npu-netconsole.log` 里看到。
- 加载时内核会把 **printk 环形缓冲区的历史整段重放**给新控制台（约 30 KB），属正常现象。

#### 11.1.1.3 A/B 判别（硬锁死 vs PERST#）仍然待定

| 可能 | 特征 |
|---|---|
| A. 内核在 `ntb_transport` 掉链路径里**硬锁死**，随后 SoC 被复位 | 控制台最后两行是 `qp 0: Link Cleanup`，之后静默 |
| B. PERST# **直接**复位 SoC，内核来不及做任何事 | 同样静默 |

现有证据仍偏向 A：`Link Cleanup` 是 **NPU 内核自己打印的**。
现在 netconsole 已经把"死前最后几行"永久留在 x86 / PC 的磁盘上，
下一次复现就能直接看 `tail -50 /var/log/npu-netconsole.log` 定案。

复位发生在**主机断链的那一瞬间**（不是 30 秒后），属于板级设计（这颗 EP 本来就不预期主机会
单独重启）。要靠 ATF/板级配置解决，超出内核能改的范围 —— 这条路到此为止。

**实际影响**：x86 重启 → NPU 跟着重启 → 40 秒后两者都自己回来，链路、VLAN、DHCP 全部自动重建。
不需要人碰机器，但 NPU 的 uptime 会归零。

## 11.2 换掉 NPU 的根分区：唯一安全的做法，以及写坏之后怎么救

2026-11-25 用错了方法，把 NPU 的 p2 写坏了，代价是两台机器各宕一次。这一节把这
条路踩实，以后不要再试别的方式。

### 11.2.1 为什么"dd 到正在使用的根分区"一定会坏

那天的顺序是：

```
sync; dd of=/dev/mmcblk0p2 bs=1M conv=fsync     # 边跑边用旧根，45 秒写完 1.5 GB
sync; reboot
```

`conv=fsync` 只保证**设备**的写回落盘，管不了**旧文件系统还挂在内存里的脏数据**。
dd 一结束，旧 ext4（大小还是 597 MiB 时代的）继续按它自己的位图和 inode 表往下写：
journald 每几秒写一次日志，落点就是新镜像的元数据区。`reboot` 也写到那里。

结果（`e2fsck -fn /dev/mmcblk0p2` 实测）：

```
Inode 9635 passes checks, but checksum does not match inode.
Inode 9643 passes checks, but checksum does not match inode.
Multiply-claimed block(s) in inode 7: 26624--28669
```

现场症状很有辨识度：**随机某个二进制执行时报 `Input/output error`**（`grep`、
`lsinitramfs`、`depmod` 都中过），sshd 在 `kex_exchange_identification` 就
`Connection reset by peer`，串口 getty 能回显但 `login` 卡死。原因是这些进程要读的
块正好被写坏了，而它们各自的运气不同。

同一个机制也解释了 20.7.5 那个"缓存身份"坑：**只要旧文件系统还活着，它就会继续
写**。

### 11.2.2 正确的换根流程

三选一，按可靠性排：

1. **在 initramfs 里换**（p2 没有挂载，最干净）：`break=premount` 或急救 initramfs，
   在那里 `dd` / 解包。缺点是镜像得能进到 RAM 或另一个分区。
2. **先把根变成只读再 dd**：`mount -o remount,ro /` 成功之后 dd 才安全。注意它经常
   直接 EBUSY（有进程正开着文件写），`echo u > /proc/sysrq-trigger`（紧急只读重挂）
   也不保证成功；两条都失败就**不要** dd。
3. **只修不换**：文件系统只是元数据坏了就用 `e2fsck`（见 20.11.3）。2026-11-25 就是
   这么修的，修完 `md5sum -c` 对着 dpkg 的 `.md5sums` 全量校验，**3435 个"失败"全是
   镜像构建时故意排除的 `/usr/share/doc`、`/usr/share/man`，真正的校验错 0 个** ——
   所以元数据修复之后不需要重刷。

### 11.2.3 写坏之后的自救：让 initramfs 在挂载前修一次

前面说过镜像里的 initramfs **根本没有 fsck**（20.11.4），所以第一件事是把它补进去：

```sh
# 1) 让 fsck hook 别再"探测设备"，直接认 ext4
printf 'FSTYPE=ext4\n' > /etc/initramfs-tools/conf.d/10-xgs87-fstype.conf
# 2) 兜底 hook 把 fsck 本体也拷进去（见 image/overlay/common/etc/initramfs-tools/hooks/xgs87-e2fsck）
update-initramfs -u -k "$(uname -r)"
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'sbin/fsck'   # 必须能看到 usr/sbin/fsck
```

然后借 U-Boot 的环境变量强制一次（**不要 saveenv**，只在内存里改）：

```sh
fw_setenv bootargs_deb 'console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 \
  root=/dev/mmcblk0p2 rootwait rw fsck.mode=force fsck.repair=yes'
reboot
# 起来后确认干净，再把 bootargs_deb 改回去：
#   console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw
```

`fsck.mode=force` / `fsck.repair=yes` 是 initramfs-tools 自己认的（
`/usr/share/initramfs-tools/init:188-192` → `forcefsck=y`、`fsckfix=y`），不是 systemd
的专利。修完的开机日志里会看到正常的一次：

```
[/sbin/fsck.ext4 (1) -- /dev/mmcblk0p2] fsck.ext4 -a -C0 /dev/mmcblk0p2
root: clean, 16457/97536 files, 168940/390144 blocks
```

### 11.2.4 镜像的 initramfs 里为什么没有 fsck（已修）

开机一直打 `Warning: fsck not present, so skipping root file system`。原因不是没装
e2fsprogs，而是 initramfs-tools 的 stock `fsck` hook 有个反直觉的分支：**对 `/` 它不信
`/etc/fstab` 写的类型，要去探测设备**（`/usr/share/initramfs-tools/hooks/fsck` 里那段
`if [ "${MNT_DIR}" = "/" ]`），而 chroot 里没有 `/dev/mmcblk0p2` 可探 → `fsck_types`
为空 → 整个 hook 直接 `exit 0`，一个二进制都不拷。

修法（`image/overlay/common/` 下，两侧共用）：

- `etc/initramfs-tools/conf.d/10-xgs87-fstype.conf` → `FSTYPE=ext4`，hook 走不探测的
  分支；顺带 arm64 交叉构建下 `copy_exec` 解析库失败时也有兜底。
- `etc/initramfs-tools/hooks/xgs87-e2fsck` → 无条件拷 `e2fsck`、`fsck.ext4`、
  **`fsck` 本体**、`logsave`。只拷 `fsck.ext4` 不够：`scripts/functions` 里是
  `command -v fsck` 判断，缺了它照样跳过。
- `image/setup.sh` 现在**两侧都重建 initramfs 并校验** `(usr/)?sbin/fsck` 在不在，
  不在就打警告。以前只有 NPU 侧重建，x86 侧用的还是内核包在 mmdebstrap 阶段生成
  的那份（那时 overlay 还没拷进去）。

### 11.2.5 复位两台机器：串口 SysRq（不碰 PCIe）

那天的教训：**从 x86 去拉根端口 `00:03.1` 的 Link Disable 会把 x86 自己带下去**
（20.7.6 那招现在不再可靠）。可靠的替代是串口 SysRq：

```sh
# 在 x86 上对 NPU 的 /dev/ttyS2，或用 COM5 对 x86 自己的 ttyS0
# 1) 发一个 BREAK（.NET: SerialPort.BreakState，Linux: termios.tcsendbreak）
# 2) 250 ms 内发一个字符：s=sync  u=只读重挂  b=立刻复位
```

实测 NPU 回了 `sysrq: HELP : ...`，`b` 干净复位并回到 U-Boot；x86 在用户态已经卡死
（回车只回 CRLF、没有 shell）的情况下，`s`+`b` 照样把机器拉了回来。**用户态挂了也要
能救**，这是它比脚本更值钱的地方。

### 11.2.6 NPU 一重启，x86 那条 vNTB 就不会自己回来

实测两次：NPU 重启后 x86 侧 `eth0` 的 operstate 停在 DOWN / 端点
`endpoint unreachable, dropping doorbell`，`xgs-ntb-watch` 因为 `AUTO_RECOVER=0`
只记日志不动手，于是**从 PC 到 x86 的路整段消失**（PC → NPU br-lan → eth0.200 → x86）。
现在镜像里默认 `AUTO_RECOVER=1`（`image/overlay/x86/etc/default/xgs-ntb-watch`）：链路
连续 5 分钟不通就主动跑一次 `xgs-ntb-up.sh --force-rescan`，之后冷却 10 分钟。5 分钟
的延迟是为了不打断正在启动的 NPU（它的 Linux 只要 11 秒）。

## 11.3 开机之后先看这五行

```sh
systemctl --failed --no-legend          # 必须是空的
ip -br a                                # x86: eth0/eth0.100/eth0.200；NPU: eth0 + br-wan/br-lan
df -h /                                 # x86 应该 ~15 GB（growroot 生效），NPU 1.5 GB
sudo dmesg | grep -iE 'EXT4-fs error|I/O error'   # 必须是空的
ssh admin@10.234.56.1 'uptime'          # x86 → NPU 那一跳
```

`xgs-ntb.service` 成功时是 `active (exited)`（`RemainAfterExit=yes`），不是 `active (running)`。

## 11.4 设备上到底装了什么 unit

`image/setup.sh` 构建时就把这些装好并 `enable` 了；下面只在"不用镜像、自己装"时才需要。
脚本一律装到 `/usr/local/sbin/`，unit 到 `/etc/systemd/system/`。

### 两台都装（`systemd/common/`）

| unit | 干什么 |
|---|---|
| `xgs87-growroot.service` | 首次开机 `growpart` + `resize2fs` 把 root 扩到盘尾，成功后留 `/var/lib/xgs87/grown` |

`setup.sh` 另外做了几件"减负"的事：`journald.conf.d/xgs87.conf`（`SystemMaxUse=64M`、
`SystemKeepFree=256M`，journal 是唯一的取证材料所以不能关但要封顶）；`mask` 掉
`getty@tty1`、`man-db.timer`、`dpkg-db-backup.timer`、`e2scrub_all.timer`；
`ssh.service.d/10-xgs87-hostkeys.conf` 先 `ssh-keygen -A` —— 镜像故意不带
`/etc/ssh/ssh_host_*`，而 Debian 13 的 `ssh.service` 自己不会生成，没这个装完机就没有 SSH。

### NPU（`systemd/npu/`）

| unit / 脚本 | 干什么 |
|---|---|
| `xgs-ports-up` / `xgs-ports-init.sh` | 等 DSA 把面板口建出来 → 按 U-Boot env 的 `ethaddr` 推 MAC（p1–p4 = base+0..3，sfp = base+4，end0 = base+5）→ `up` 让 PHY 协商。p5–p8 面板没引出，不配 |
| `xgs-vntb` / `xgs-vntb.sh` | configfs 建 `pci_epf_vntb`（`1957:0809`）→ `start` EPC → 装 `ntb_transport` + `ntb_netdev` |
| `xgs-net-up` / `xgs-net-up.sh` | 按 `/etc/xgs87/net.conf` 把面板口分成 `br-wan`（`p2` + `eth0.100`）和 `br-lan`（`p1` + `eth0.200`），两个桥各一条 VLAN（100/200），谁都不用默认 VLAN 1 |
| `xgs-dhcp` / `xgs-dhcp.sh` | 在 `net.conf` 里选 `dhcp` 的桥上跑**一个** `dhcpcd`（默认只有 `br-wan`） |
| `xgs-nat` / `xgs-nat.sh` | LAN → WAN 的转发 + `masquerade`（`inet xgs87` 表，子网从 `LAN_ADDR` 推） |
| `xgs-netconsole` | `modprobe netconsole`，把内核 console 推给 x86 和 PC（崩溃取证的主要手段） |

```sh
sudo install -m755 systemd/npu/*.sh      /usr/local/sbin/
sudo install -m644 systemd/npu/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xgs-ports-up xgs-vntb xgs-net-up xgs-dhcp xgs-nat xgs-netconsole
```

### x86（`systemd/x86/`）

| unit / 脚本 | 干什么 |
|---|---|
| `xgs-ntb` / `xgs-ntb-up.sh` | 装 `ntb_hw_epf`+`ntb_transport`+`ntb_netdev`；按 `1957:0809` 找端点（BDF 由 BIOS 分配）→ 必要时**重枚举一次** → 等 netdev → 建 `eth0.100/.200` 并钉 MAC |
| `xgs-ntb-watch` / `xgs-ntb-watch.sh` | 每 15 s 查 carrier + ping 对端；默认 `AUTO_RECOVER=1`，5 分钟不通自动 `--force-rescan` 一次，冷却 10 分钟 |
| `xgs-ntb-stop` / `xgs-ntb-stop.sh` | 关机前卸掉 `ntb_hw_epf`，给端点发 `COMMAND_LINK_DOWN` |
| `xgs-netconsole` | `nc -u -l -k 6666`，收 NPU 推来的 console → `/var/log/npu-netconsole.log` |
| `xgs-npu-console` | **可选**：`cat /dev/ttyS2` 连续录到 `/var/log/npu-console.log`。它**独占** ttyS2，交互调试前要先停 |
| `100-wan.network` / `200-lan.network` | `eth0.100` DHCP（默认路由从这来）；`eth0.200` 静态 `10.234.56.2/24` |

```sh
sudo install -m755 systemd/x86/*.sh      /usr/local/sbin/
sudo install -m644 systemd/x86/*.service /etc/systemd/system/
sudo install -m644 systemd/x86/*.network /etc/systemd/network/
sudo systemctl daemon-reload
sudo systemctl enable --now xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole systemd-networkd
```

### 装错机器的症状

| 装错方向 | 现象 |
|---|---|
| NPU 脚本装到 x86 | `xgs-ports-init.sh` 等不到 `p1`/`sfp` 直接退出；`xgs-vntb.sh` 找不到 `/sys/class/pci_epc/f2600000.pcie` |
| x86 脚本装到 NPU | `xgs-ntb-up.sh` 找不到 `/sys/class/ntb/devices/...`（NPU 是 EP 不是 host），且会占用 `eth0` 这个名字 |
| 两个都装 | 最惨：两边都去建 `eth0.100`，互相抢 |

x86 上可能还有一个历史遗留的 `/usr/local/sbin/npuc`，功能和 [10](10-console.md) 里那套重复
（少了 login 分支），以仓库里的 `tools/on-x86/npu-console.sh` 为准。
