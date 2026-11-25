# 09 · 改造笔记：要做什么、缺什么

> 🏷 **状态（2026-11-25）**：⚠️ 活文档 —— 每次实机验证后更新。
> 这是**唯一**的"待办 + 缺口"清单；每条都能对应到一份带证据的文档。
> **当前现场**：两台都在跑 Debian 13.8 / 6.12.117，vNTB 通（`eth0/.100/.200` 全 UP），
> 面板 `2/WAN` 没插线所以两边都还没有默认路由。NPU p2 的根文件系统已修复并通过
> `md5sum -c` 全量校验（砖机复盘见 §9.1 末尾）；p3 原厂完好可回滚。

## 9.0 路线已经定了：两边都是 Debian

```
x86   Debian 13.8 / 6.12.117   通用计算、控制面（正常）
NPU   Debian 13.8 / 6.12.117   网络数据面（DSA + 10G + 双面板口已跑通）
```

> 2026-11-25 实测：NPU 从 p2 正常启动、`br-lan` 是 10.234.56.1/24，端口 MAC 按 VPD 的
> 7 地址方案分配。面板 p2/WAN 现在没插线，所以 `br-wan` 退到 IPv4LL `169.254.38.2`、
> 两台都没有默认路由 —— 插上上游就恢复（`eth0.100` 的 DHCP 也一起来的）。

- **OpenWrt 不装了**：NPU 上原来那个 OpenWrt 已经删掉，x86 也只装 Debian。
  早期设想（"NPU 跑 OpenWrt 当路由、x86 装 OpenWrt"）**作废**，文中如遇一律以此处为准。
- 原厂 Buildroot 4.14 也已替换，只作为档案留在 [04](04-npu-system.md)；p3 那一槽仍保留着，
  是目前唯一能直接启动的系统。
- 两个参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
  [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）现在的用途只剩两个：
  **查硬件事实**（端口映射、LED 表、MDIO 地址）和**取 DTS 片段**，不再作为系统方案。

### 为什么最终是 Debian 而不是 OpenWrt

| | Debian 13（已选） | OpenWrt（未走） |
|---|---|---|
| 交换机 / 10G | ✅ 发行版 `mv88e6xxx` + `mvpp2`，9 个 netdev 全在跑（面板 4 口 + SFP） | 有现成 kmod，但版本被发行版绑死 |
| 软件生态 | apt 全量（k3s、Docker、Python、编译工具链） | opkg，装通用软件麻烦 |
| x86 侧需求 | x86 要当通用服务器，本来就该是 Debian | OpenWrt x86 只能当路由 |
| 与 x86 统一 | 同一套 apt / systemd / 内核维护方式 | 两套系统两套维护方式 |
| 代价 | 自己出 DTB、自己编模块（已完成，见 [14](14-npu-debian-hardware.md)、[20](20-lan-over-vntb.md)） | 上手便宜，但长期被框架限制 |

结论：**代价已经付完了**，没有回 OpenWrt 的理由。

## 9.1 已经做完的（不用再惦记）

| 能力 | 证据文档 |
|---|---|
| x86 Debian 自启；NPU Debian 自启（p2，2026-11-25 复测）；eMMC 整盘备份（7.28 GiB，SHA256 校验） | [07](07-storage.md)、[12](12-measurements.md) |
| 88E6193X DSA 九个 netdev（`p1–p8` + `sfp`；面板只引出 p1–p4 + sfp），发行版驱动；TCAM 两个上游修复为可选补丁 | [06](06-switch-and-ports.md)、[19](19-module-vs-kernel-rebuild.md) |
| SFP+ 实测 10000 Mb/s | [14](14-npu-debian-hardware.md) |
| `mvpp2` 用发行版；`AGGR_TXQ_SIZE=512` 自编译版可选（[tools/build/build-npu-net.sh](../tools/build/build-npu-net.sh)） | [19](19-module-vs-kernel-rebuild.md) |
| SPI NOR / MTD / `fw_printenv` | [14](14-npu-debian-hardware.md) |
| thermal 6 zone + 9 hwmon、PWM、GPIO | [01](01-hardware.md) |
| x86 ↔ NPU vNTB（1.2 Gbit/s，RTT 0.6 ms） | [17](17-x86-npu-shared-mgmt.md)、[20](20-lan-over-vntb.md) |
| 一条链路同时跑 WAN + LAN（VLAN 100 / 200），x86 在 WAN 侧拿到 DHCP | [20](20-lan-over-vntb.md) |
| 管理段和家里 LAN 在交换芯片上真正隔离（WAN/LAN 各用一条 VLAN，都不碰默认 VLAN 1） | [20](20-lan-over-vntb.md) §20.1 |
| 掉链 / 关机不再 oops（peer_db 校验、spad 守卫、关机道别） | [20](20-lan-over-vntb.md) §20.7 |
| 崩溃取证：netconsole 双目标（NPU → x86 + PC） | [20](20-lan-over-vntb.md) §20.8 |
| 镜像构建：`image/` + 一个 CI workflow（`target=x86/npu/usb/all`），自动发 release | [image/README.md](../image/README.md)、[21](21-reproduce.md) |
| 维护（诊断）U 盘：整盘重装 x86、ssh+dd / U-Boot / 急救包推 NPU、备份内置盘 | [22](22-from-sfos.md)、[image/release-usb.md](../image/release-usb.md) |
| MCP2210 SPI NOR 救砖工具（GP0 CS、NPU hold/release、整片双遍 dump、只写 env、失败回滚） | [23](23-mcp2210-spi-nor.md) |
| 账号统一：只有 `admin`（sudo），root 锁定、SSH 拒绝 root | [image/release-x86.md](../image/release-x86.md) |
| **主机名**：x86 = `xgs-debian-x86`，NPU = `xgs-debian-npu`（2026-11-25 起，`image/setup.sh`） | [image/setup.sh](../image/setup.sh) |
| **硬件看门狗**：`xgs-watchdog.service` 喂 SBSA `/dev/watchdog0`，实测不喂狗 10–20 s 整机复位 | [04](04-npu-system.md) §4.13 |
| **默认 DNS**：`1.1.1.1` / `8.8.8.8`（NPU 用 `/etc/resolv.conf.head`，x86 用 resolved 全局 DNS + `UseDNS=no`），2026-11-25 实测两边都能解析 | [14](14-npu-debian-hardware.md) §14.13 |
| **NPU 的 DNS / NTP**：purge 掉 `systemd-resolved`，让 dhcpcd 直接写 `/etc/resolv.conf`；实测 DHCP 下发 `nameserver` 后 `getent hosts` 与 `timedatectl` 都正常 | [14](14-npu-debian-hardware.md) §14.13 |
| **NPU 的开机 fsck**：initramfs 现在带 `e2fsck`（自建 hook），p2 的 ext4 已用它修到 `clean` | [14](14-npu-debian-hardware.md) §14.13 |

### 2026-11-25 砖机复盘：已解决 —— eMMC 数据从来没丢过

**结论先行**：NPU 的 p2 一直是好的，现在跑着 Debian 13.8；当年的"砖"是三个独立问题叠在一起。
完整证据链见 [03](03-boot-chain.md) §3.6，这里只留结论和可复现的修法。

| 现象 | 真因 | 处置 |
|---|---|---|
| `** No partition table - mmc 0 **` | U-Boot 那一次分区表读取失败（当时正处在 x86 remove/rescan 的复位风暴里） | 无需处理；LBA0 签名 `0xFAE598E3`、p1/p2 内容都在，`mbrfix` 写回的就是原厂那份 MBR |
| 串口无限 `BOOTP broadcast` | env 被 `mbrfix` 的连续 `saveenv` 写坏（env 区不先擦除） | 用 [mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py) `flash-write --offset 0x3F0000` 整块重写；以后只用 `fw_setenv` |
| p2 "起不来" | `bootcmd_deb` 要 `/boot/initrd.img`，而 p2 里只有 `initrd.img-6.12.117+deb13-arm64` | 补一个硬链接即可，见下 |
| 约 3.2 s 一轮的"自复位" | x86 的 `xgs-ntb-up.sh` 每 2 s 一次 remove/rescan | 已改成**每次运行最多一次**、且只在"内核缓存的是固件出厂身份"时才做（§20.7.5）；不做循环 |

**复现修法（实测有效）**

```sh
# 在能写 p2 的系统上（p3，或 p2 自己）
ln /boot/initrd.img-6.12.117+deb13-arm64 /boot/initrd.img
fw_setenv bootcmd 'run bootcmd_deb10g'
reboot
```

`fw_setenv` 需要 `/etc/fw_env.config`（`/dev/mtd1 0x0000 0x10000 0x1000`）。老镜像里没有这个文件，
`fw_setenv` 会报 `Cannot initialize environment`，端口 MAC 也就不会被设置；现在镜像已带上
（[image/overlay/npu/etc/fw_env.config](../image/overlay/npu/etc/fw_env.config)）。

**什么时候才真的需要重刷 p2**：只有当 p2 挂不上（`bad magic` / 结构损坏）时才做。这时才用
`p2.img`（1,598,029,824 B，SHA256 `383cb3ae…afeafb6e4`）写**分区节点**：

```sh
sudo mount -o ro /dev/sda1 /mnt/usb          # x86 上，p2.img 在 U 盘的 XGS87BAK 分区
NPU=<npu-ip> NPU_PASS=... SRC=/mnt/usb/p2.img sh npu-sshdd.sh
```

`npu-sshdd.sh` 有 `require_partition` 挡整盘名，以及"整盘镜像（LBA0 以 `55AA` 结尾）写进分区"的守卫。

**恢复后确认三件事**

```sh
uname -r                      # 6.12.117+deb13-arm64
ip -br a                      # br-wan 拿到 DHCP，br-lan 10.234.56.1/24
ip -br link | grep -E '^(p1|p2|sfp|end0)'   # MAC 必须是 VPD 的 7 地址方案（[06](06-switch-and-ports.md) §6.6）
```

> ℹ️ p2 的 ext4 超级块上还留着 2026-11-24 那次事故的 **`errors` 标记**（`dumpe2fs -h` 显示
> `clean with errors`，每次挂载会打一行 `mounting fs with errors`）。它不影响读写，只是提醒该
> 做一次 e2fsck；真要清掉得**离线**跑 `e2fsck -fy /dev/mmcblk0p2`（p3 自带的是 e2fsprogs 1.44，
> 太老不认 `metadata_csum_seed`，要用 p2 自己那套 1.47 或在 PC 上做）。

**UART 通道**：x86 的 `/dev/ttyS2` 与 PC 的 USB 串口都是**双向**的；`mrvl-uart.py` 的 XMODEM-128
4 KiB 载荷 + EOT 实测成功，`npu-uboot.py` 能在 U-Boot `=>` 上敲命令（一行一条，别粘贴多行）。
BootROM 的 UART 恢复通道只在 SPI 镜像"无效"时才会停住，不能替代正常 U-Boot 控制台。

## 9.2 还没做完的

**vNTB 当前是通的**（2026-11-25 复核）：x86 上 `eth0/.100/.200` 全 UP、`10.234.56.2/24` 在
`eth0.200`，主机名 `xgs-debian-x86`。以前这里写着"唯一卡住的事是手动跑
`xgs-ntb-up.sh --force-rescan`"，那条已经不需要了：脚本自己会发现内核缓存的是固件出厂
身份并 `remove`+`rescan` 一次（[20](20-lan-over-vntb.md) §20.7.5），`xgs-ntb-watch` 默认
`AUTO_RECOVER=1` 兜底（§20.11.6）。

### 高优先级（有明显用户价值）

| # | 事项 | 现状 / 卡在哪 |
|---|---|---|
| 1 | **`cpufreq` 不可用** | `/sys/devices/system/cpu/cpu0/cpufreq` 不存在。2026-11-25 查明：DT 的 `cpu@0` 只有 `clocks`、没有 `operating-points-v2`，`cpufreq-dt` 无表可读（不是装包能解决的，见 [14](14-npu-debian-hardware.md) §14.13） |
| 2 | **x86 断 PCIe 链路 → NPU 整机复位** | 软件手段已穷尽（停 EP、关 panic、看门狗确认 inactive 都试过），判定是 SoC/ATF 对 `PERST#` 的反应。**要改 ATF 才有意义**，见 [20](20-lan-over-vntb.md) §20.8 |
| 3 | **掉链时 `ntb_transport` 的 lockup** | 现在靠 NPU 自身复位兜底。`ramoops` 这条路已证伪（每次复位都重跑 DDR scrub，保留区必被清空），改用 **netconsole 双目标**（NPU → x86 管理 VLAN + PC 的 `br-lan`），死前最后几行已经能落在磁盘上 —— 判据见 [20](20-lan-over-vntb.md) §20.8，只差一次复现 |
| 4 | **风扇不可控 / 温控不动作** | 整机一颗风扇，上电即转，曲线在硬件里；NPU 的 thermal zone 有 100 ℃ trip 但 **0 个 cooling device**（连 `cpufreq` 都没有），所以到点也不会做什么。要软件调速得先把 PWM 通道跟风扇对上 + 补 OPP（[19](19-module-vs-kernel-rebuild.md) §19.6、[14](14-npu-debian-hardware.md) §14.13） |
| 5 | **`kernel/x86/` 的四份拷贝比发行版内核旧一代** | 实测（2026-11-25，对着 Debian 的 `linux-source-6.12` = 6.12.117 逐文件 `diff`）：`ntb_hw_epf.c` / `ntb_transport.c` / `ntb_netdev.c` 是 **6.12.94 那一代**的上游源码（少了 `atomic64_t db_val` + 每 IRQ 一个 ctx 的 doorbell 修法、`ntb_get_dma_dev()` 的 DMA 设备修法、rx 侧重新分配 skb 的修法），`kernel/npu/` 的三份才是 6.12.117 的。它们**能编也能用**（当前链路就跑在这批上），只是没吃到上游 6.12.x 后续那几个 doorbell 修复。要刷新：把 6.12.117 的源码放进 `kernel/x86/`、用 `diff -u` 重新生成 `ntb/0101-ntb_hw_epf.patch`，然后**必须重启一次实测链路**（手工 `rmmod ntb_hw_epf` 会把 x86 带崩，见 §9.4） |

### 中优先级（想用某个功能时才需要）

| # | 事项 | 现状 |
|---|---|---|
| 6 | **LED 极性 / 映射未逐一验证** | 面板灯走 PHY 的 LED 控制寄存器；`PCA9555` 驱动面板灯已被证伪。要逐个口试（[06](06-switch-and-ports.md)、[12](12-measurements.md)） |
| 7 | ~~交换机 port 5–8 是否引到面板~~ | ✅ **已确认（用户）**：XGS 87 面板就是 4 口，port 5–8 是 **XGS 107** 才有。不用再查 |
| 8 | ~~**MCP2210 SPI NOR 读写工具**~~ | ✅ **已完成（2026-11-24）**：`tools/on-x86/mcp2210-nor.py`；实机读到 JEDEC `C2 20 16` 和 env。GP0=CS，GP0/3/5 hold/release，只写 env。见 [23](23-mcp2210-spi-nor.md) |
| 9 | **x86 的 i2c-dev / GPIO 暴露** | 目前没开，接外设时再弄 |
| 10 | **`dev_write … 4 f002/2000` 的字段含义** | 已确认是 SerDes/PCS 块，细节要 datasheet |

### 低优先级 / 也许永远不做

- **NPU 单独重启后，x86 侧自愈**：✅ **已修**（2026-11-23）。根因是 `ntb_epf_spad_write()` 把端点读回的
  `0xffffffff` 当偏移用 → 页错误 → panic；补丁 + watcher 的完整重置都补上了，实测 NPU 单独重启后
  90 秒链路自己回来、x86 不重启（[20 §20.10](20-lan-over-vntb.md)）。
- 内置（`=y`）而不是模块化 `mv88e6xxx` / `mvpp2`：现在模块换起来方便，没必要。
- 关机时对端已经下线：`xgs-ntb-stop` 里 `rmmod ntb_hw_epf` 会打 `Fail to disable link`，
  紧接着 `iounmap: bad address`（2026-11-23 19:27 那次关机实测）。只发生在断电前的
  最后一步，没造成数据损坏；要修得调 `kernel/x86/ntb_hw_epf.c` 的 remove 顺序。
- 原厂 CPSS / `mvpp2x` 多口驱动：只支持 4.14，且我们已经有 DSA。
- 自研交换机驱动：上游 `mv88e6xxx` 已经够用。
- Wi-Fi：本机（XGS 87 非无线版）没有无线模块。

## 9.3 事实证明"不用做"的（曾经的担忧）

| 曾经的担心 | 实测结论 |
|---|---|
| "NTB 必须换内核" | ❌ 不成立 —— Debian 内核开 `CONFIG_NTB` 就能用，我们跑的是 vNTB |
| "交换芯片没有 mainline 驱动" | ❌ 不成立 —— 88E6193X 在主line `mv88e6xxx` 里，`6b491af01aa5` 修了探测 |
| "SFP 口只能 1G" | ❌ 不成立 —— DTS 改 `10gbase-r` 后实测 10G |
| "NPU 是无风扇设计" | ❌ 不成立 —— 有风扇，只是软件不可控 |
| "NPU 是 Buildroot 空密码" | ❌ 不成立 —— 现在跑 Debian，root 有密码 |

## 9.4 维护红线（会把机器搞成砖的事）

| 别做 | 后果 | 现状 |
|---|---|---|
| ~~`apt upgrade` 内核~~ | 以前会：`ntb_*.ko`、`mv88e6xxx`、`mvpp2`、vNTB 全是对着固定版本编的 | ✅ **已解决**：`kernel/<side>/install.sh` 走 **DKMS**，装了 dkms 的镜像（`full` variant）升级内核会自动重编，历史实测 6.12.94 → 6.12.118 成功。**发布用的 `lean` 镜像不带 dkms、内核被 hold**，换内核要先 `apt-mark unhold` 再跑该脚本。见 [19](19-module-vs-kernel-rebuild.md) §19.2 |
| 手工 `rmmod ntb_hw_epf`（x86） | 端点已失联时 `ntb_epf_spad_write()` 会写野指针 → panic | 已修（spad 守卫），但顺序错了仍危险 —— 交给关机钩子做；`xgs-ntb-watch` 默认只重建本地 VLAN，不碰 PCIe |
| 写 SPI `mtd0` | U-Boot 在那儿，写坏就得靠 MCP2210 或 JTAG 救 | 只读，从不写；有备份。唯一的例外是 `mtd0-restore --unsafe-mtd0 --commit`（刷坏后回滚用，见 [23](23-mcp2210-spi-nor.md) §23.5） |
| 格式化 `/persistent`（p4） | 丢机型和 MAC 基址 | 只读使用 |
| 往 `p1` 上放系统 | 那是原厂冷备槽，留着回滚 | 空着 |
| **把裸文件系统镜像写到整盘**（`dd if=p2.img of=/dev/mmcblk0`） | **LBA 0 的 MBR 被 ext4 超级块覆盖 → `No partition table - mmc 0`**，所有分区消失（2026-11-24 那台就是这么砖的） | 脚本层已加守卫：`require_partition` / `require_whole_disk`（[07](07-storage.md) §7.6）。裸 FS 镜像只写 `...p2`，整盘镜像才写 `/dev/mmcblk0` / `/dev/sdX` |
| 在 NPU 还没稳定启动时跑 `xgs-ntb-up.sh --force-rescan` | 一次 remove/rescan 就会拉 PERST#，把正在启动的 NPU 打断；循环做就是 2026-11-25 的 3.2 s "自复位" | 脚本**每次运行最多 re-enumerate 一次**，且只在端点身份还是固件出厂值时；`xgs-ntb-watch` 默认 `AUTO_RECOVER=1` 但等 **5 分钟**（NPU 的 Linux 只要 11 s），不会撞上启动窗口 |
| **在端点抖动时读它的 PCIe 配置空间**（哪怕只是 `lspci`） | **x86 会直接重启**。2026-11-25 实测：`lspci -nn \| grep -i 11ab` 一跑机器就重启（当晚这样崩了 4~5 次）。端点复位风暴期间，主机在抖动窗口里读 config space 会触发致命错误 | 用 sysfs 判存在性（`[ -e /sys/bus/pci/devices/0000:03:00.0 ]`），**端点不稳定时不要 `lspci`**。要复位 NPU 优先用串口 SysRq（BREAK + `b`，见 [20](20-lan-over-vntb.md) §20.11.5）；Link Disable（`setpci -s 00:03.1 CAP_EXP+10.w=0010`）现在会把 x86 一起带下去，只是最后手段 |

> ⚠️ NPU 的 1.5 GB 根分区**装不下 `full` 变体**（root 解开约 900 MB）。现在实测 1.4G/1.5G，
> 只剩 276 MB。三条路：装 `--variant lean`（root 解开 387 MiB，**推荐**，工具链编完就删掉）、
> 把根分区做到 ≥3 GB、或者 `--variant base` + 之后自己跑 `kernel/npu/install.sh`
> （见 [image/README.md](../image/README.md)）。`lean` 的内核被 `apt-mark hold`，
> 要升级内核时先 `apt-mark unhold linux-image-arm64` 再跑 `/opt/xgs87/kernel/npu/install.sh`。

## 9.5 如果要重做一遍（换机 / 重刷的最小路径）

现在最省事的路是 **`debian-usb` 维护 U 盘**：插上去选 `1` 重装 x86、选 `2` 重装 NPU
（见 [21](21-reproduce.md)、[22](22-from-sfos.md)）。手工做的话按这个顺序：

1. **备份**：eMMC 整盘 + `mtd0`(U-Boot) + `mtd1`(env)，SHA256 存档（[07](07-storage.md)）。
2. **改 U-Boot env**：`bootcmd` → `bootcmd_deb10g`（`ext4load` Image + dtb + initrd → `booti`），
   注意 `bootcmd_deb10g` 先用 `mvswitch` 把 port 9 配成 10G（[03](03-boot-chain.md)）。
   在 NPU 上改就用 `fw_setenv`；确认 `/boot/Image` 和 `/boot/initrd.img` 两个名字都存在
   （[image/setup.sh](../image/setup.sh) 会自动硬链接）。
3. **DTB**：`board/cn9130-sophos-xgs87w-sfp10g.dts`（本仓库；节点里保留了 `ramoops`，
  但已被 DDR scrub 证伪，留着不影响启动），`tools/build/build-dtb.sh` 生成
  `out/cn9130-sophos-xgs87w-sfp10g.dtb`。
4. **模块**：`kernel/npu/install.sh` / `kernel/x86/install.sh`（DKMS 包；脚本会把 dkms 和
   headers 装上，之后再升级内核就是自动重编）。
   只有要改驱动源码时才用 `tools/build/*` —— 它负责先把 `ntb/*.patch`、`net/patches/*`
   打到上游源码上再编。
5. **网络**：`systemd/npu/` 装到 NPU、`systemd/x86/` 装到 x86（见 [systemd/README.md](../systemd/README.md)、[20](20-lan-over-vntb.md)）。
6. **别做的事**：见 §9.4 的维护红线 —— `mtd0` 永不写、别手工 `rmmod ntb_hw_epf`、
   `p1` 留给原厂回滚、`/persistent` 只读。内核包不用再 hold，DKMS 会跟着重编。

> 完整的实测数据见 [12-measurements.md](12-measurements.md)；
> 每篇文档开头都有状态标记（✅ 实测 / 📦 原厂档案 / 💡 设想 / ⚠️ 未验证）。
