# 09 · 改造笔记：要做什么、缺什么

> 🏷 **状态（2026-11-25）**：⚠️ 活文档 —— 每次实机验证后更新。
> 这是**唯一**的"待办 + 缺口"清单；每条都能对应到一份带证据的文档。
> **当前现场**：x86 Debian 正常；NPU p2 的 MBR 已修回，但根文件系统仍待重刷；p3 原厂完好。

## 9.0 路线已经定了：两边都是 Debian

```
x86   Debian 13.6 / 6.12.118   通用计算、控制面（正常）
NPU   Debian 13.6 / 6.12.117   网络数据面（DSA + 10G 已跑通；p2 待重刷）
```

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
| x86 Debian 自启；NPU Debian 自启（p2 重刷后）；eMMC 整盘备份（7.28 GiB，SHA256 校验） | [07](07-storage.md)、[12](12-measurements.md) |
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
| 维护（诊断）U 盘：整盘重装 x86、ssh+tar / ssh+dd / U-Boot / 急救包推 NPU、备份内置盘 | [22](22-from-sfos.md)、[image/release-usb.md](../image/release-usb.md) |
| MCP2210 SPI NOR 救砖工具（GP0 CS、NPU hold/release、整片双遍 dump、只写 env、失败回滚） | [23](23-mcp2210-spi-nor.md) |
| 账号统一：只有 `admin`（sudo），root 锁定、SSH 拒绝 root | [image/release-x86.md](../image/release-x86.md) |

## 9.2 还没做完的

### 砖机复盘：eMMC 分区表被覆盖（**分区表已修好，p2 待重刷**）

**结论（2026-11-25 更新，推翻了"BL31 之后复位" / "CP0 MSS 起不来"的旧判断）**：U-Boot 本身是好的，
拿到过完整启动日志并停在 `Marvell>>`。真正卡住的是：

```
** No partition table - mmc 0 **
```

eMMC 的 **MBR（LBA 0）被覆盖**了 —— `p2.img` 是裸 ext4 镜像，被 `dd` 到
`/dev/mmcblk0`（整盘），LBA 0 变成 ext4 超级块。于是 `ext4load mmc 0:3` 全部失败，
看起来像"砖了"，其实 p3/p4 数据完好。成因与守则写在 [07](07-storage.md) §7.6。

**修复已就位**（不需要再动 SPI NOR）：env 里加了 `mbrfix`，`bootcmd=run mbrfix; run bootcmd_emmc3`。
U-Boot 只要启动一次就会：把原厂 512 字节 MBR（4 分区、磁盘签名 `0xFAE598E3`）铺进 RAM →
`mmc write 0x7000000 0 1` 写回 LBA 0 → `cmp.b` 回读校验 → `part start mmc 0 2` 判定，
每步 `setenv step N; saveenv` 留痕：

| `step` | 含义 |
|---|---|
| 0 | U-Boot 没跑过（环境变量里的值还是初值） |
| 1 / 2 / 3 / 4 | 开始 / RAM 缓冲铺好 / `mmc write` 已发 / 回读完成 |
| 10 / 11 | 回读与 RAM 内容一致 / 不一致 |
| **12** | **分区 2 已可见 —— MBR 修好了** |
| 13 | 分区仍不可见（`mmc` 或卡本身有问题） |

**修复结果（2026-11-25 实测：成功）**

U-Boot 跑起来之后 `mbrfix` 执行完毕，从芯片上读回的 env 提供了两个决定性证据：

```
step=12            ← part start mmc 0 2 成功
pstart=fa800       ← 0xFA800 = 1026048 = 原厂 MBR 里 p2 的起始 LBA
```

`pstart` 与原厂 MBR 完全吻合 ⇒ **LBA 0 的分区表已经恢复**，p1..p4 重新可见。
（`cmp.b` 回读也一致，因此 `step` 是 12 而不是 11。）

⚠️ **确认 `step=12` 后必须把 `bootcmd` 改回 `run bootcmd_emmc3`（或 `run bootcmd_deb10g`）**。
`mbrfix` 每步都 `saveenv`，留在启动路径里就是反复写 env，下一次就会再触发 §9.2 里
那个"半截默认 bootcmd"的坑。

**两个"自己坑自己"的陷阱（2026-11-25 排查出来，都已修）**

1. **x86 自己的 PCIe 拆插循环把 NPU 按在启动里打**

   `systemd/x86/xgs-ntb-up.sh` 原来是「每 2 秒 `remove` + `rescan` 一次，最多 30 次」，本意是
   等 NPU 的 vNTB 功能启动后让内核重读 BAR 大小。实际后果是：remove/rescan 会重新拉 PERST#，
   **NPU 每次刚启动到一半就被打断**；`eth0` 因此永远不出现，`xgs-ntb-watch` 判定链路已死 →
   再调一次 `xgs-ntb-up.sh` → 闭环，机器无限打转。

   追了一整晚的"每 2.1–3.3 秒硬件自复位"就是它。实测判据：停掉服务后
   `lspci | grep -c 11ab` 连续 12 次采样恒为 1、`dmesg` 里 `11ab:7080` 的枚举计数不再增长
   （停之前是 31 次且持续增长）。

   已改成：先静等 180 秒**完全不碰 PCIe**，只有确实等不到 NTB 设备时才做**一次**
   `remove` + `rescan`。

2. **U-Boot 的 `saveenv` 会把 env 写坏（没擦干净就写）**

   `mbrfix` 里每步 `setenv step N; saveenv` 连续跑了 5 次之后，env 区变成了这样：

   | 偏移 | 内容 |
   |---|---|
   | 0x000 | CRC + `bootcmd=bootp; setenv bootargs root=/dev/nfs … bootm` ← **生效的是这条** |
   | 0x0CA | 双 NUL，第一份 env 结束 |
   | 0x0CC | `le=ttyS0,…` —— 我们那份 env 的**残片** |
   | 0x33B | `bootcmd=run mbrfix; run bootcmd_emmc3`（还在，但已不生效） |
   | 0x4000 | 之后全 `0xFF` |

   前 16 KiB 没有被擦除就覆盖写了新内容 → 生效的 `bootcmd` 变成默认的 NFS 网络启动，
   串口上就是无限 `BOOTP broadcast`。

   ⚠️ 这也意味着**不要频繁 `saveenv`**（尤其相位里带 `mbrfix` 那种每步保存的脚本），
   一次启动写 5 次很容易踩到。

   **坏到这个程度的 env，`env-write` 自己也救不了**：它要求备份里的 env 能被解析，
   而备份正是坏的那份（先有鸡先有蛋）。所以工具里新加了 `flash-write`：

   ```sh
   sudo python3 mcp2210-nor.py flash-write --cs-pin 0 \
        --image /tmp/env-new.bin --offset 0x3F0000 --commit --yes
   ```

   它**不做任何 env 解析**，只按显式区间擦/写/回读校验，自己的守卫是：64 KiB 对齐、
   不越出芯片、默认不许碰 mtd0（要碰必须 `--unsafe-mtd0`）。实测把 env 区整块重写后：

   ```
   region written and verified (sha256 ab8f6773…)
   env CRC 0x2A37867F OK, 30 keys        ← 不再有 garbage 警告
   ```

   （这是那次 `flash-write` 写进去的 30 键精简 env；后来从芯片复读到的完整 env 是
   35 项，见 [23](23-mcp2210-spi-nor.md) §23.7。以每次 dump 的实际内容为准。）

   注意 `bootcmd` 恢复成的是**原厂那条**——它就是从 **p3** 启动
   （`ext4load mmc 0:3 … booti`），而 p3 一直完好。所以 env 一修好，NPU 应该能直接进原厂系统，
   不必等 p2。

**还没做完的**

1. **p2 的根文件系统仍是坏的**（当初那句 `dd` 把前 1023 MiB 写到了 LBA 0）。
   分区表修好只是让它"能被找到"，内容还得重刷。**x86 上一条命令**：

   ```sh
   # p2.img 已确认是裸 ext4（LBA0 不以 55AA 结尾），XGS87BAK 分区里那份 SHA256 已验证
   sudo mount -o ro /dev/sda1 /mnt/usb
   NPU=<npu-ip> NPU_PASS=... SRC=/mnt/usb/p2.img sh npu-sshdd.sh
   ```

   `npu-sshdd.sh` 走 `ssh | dd of=/dev/mmcblk0p2`，两道守卫：`require_partition` 挡整盘名，
   `SRC=` 那条再挡"整盘镜像（LBA0 以 `55AA` 结尾）写进分区"。两种坏输入实测都被拒，
   `p2.img` 实测被接受。
   物料：`/mnt/usb/p2.img`，1,598,029,824 字节，
   SHA256 `383cb3aee23d325a25340e8e045f81c7b667252a3a0cbf3ae203708afeafb6e4`。
   刷完把 `bootcmd` 切成 `run bootcmd_deb10g`（从 p2 启动，顺带把 SFP port9 配成 10G）。

**下一步（按顺序）**

1. 重刷 p2：`NPU=<npu-ip> NPU_PASS=... SRC=/mnt/usb/p2.img sh npu-sshdd.sh`
   （或者用维护盘菜单 2 的 ssh+dd 路径）。刷完把 `bootcmd` 切成 `run bootcmd_deb10g`；
2. 如果 p2 暂时不刷：p3 原厂完好，`bootcmd=run bootcmd_emmc3` 就能用；
3. 只有在 p2 也起不来、串口完全没输出时才往硬件方向查：量 12V/3.3V、JTAG 读 AP806
   watchdog 与 PMIC fault。

**UART 通道**：x86 的 `/dev/ttyS2` 是**双向**的；`mrvl-uart.py` 的 pattern + XMODEM-128
4 KiB 载荷 + EOT 实测成功，`npu-uboot.sh` / `npu-uboot.py` 也能在 U-Boot `=>` 上敲命令。
PC 侧的 CH340（COM7）只接了输出、没有回传，所以它只能看，不能发。
BootROM 的 UART 恢复通道只在 SPI 镜像"无效"时才会停住，不能替代正常的 U-Boot 控制台。

（救砖镜像侧已就绪：[07](07-storage.md) §7.4 —— `p2.img` 可直接 `dd` 到 **p2 分区**，
`bootcmd_deb` 需要的 dtb / initrd 文件名已补齐，等 U-Boot 能跑起来即可写盘验证。）

### 高优先级（有明显用户价值）

| # | 事项 | 现状 / 卡在哪 |
|---|---|---|
| 1 | **`cpufreq` 不可用** | `/sys/devices/system/cpu/cpu0/cpufreq` 根本不存在；`ap-cpu-clk` 模块段错误未修。修好才能降频省电 / 看真实频率 |
| 2 | **x86 断 PCIe 链路 → NPU 整机复位** | 软件手段已穷尽（停 EP、关 panic、看门狗确认 inactive 都试过），判定是 SoC/ATF 对 `PERST#` 的反应。**要改 ATF 才有意义**，见 [20](20-lan-over-vntb.md) §20.8 |
| 3 | **掉链时 `ntb_transport` 的 lockup** | 现在靠 NPU 自身复位兜底。`ramoops` 这条路已证伪（每次复位都重跑 DDR scrub，保留区必被清空），改用 **netconsole 双目标**（NPU → x86 管理 VLAN + PC 的 `br-lan`），死前最后几行已经能落在磁盘上 —— 判据见 [20](20-lan-over-vntb.md) §20.8，只差一次复现 |
| 4 | **风扇不可控** | 整机一颗风扇，上电即转，温控曲线在硬件里；x86 无 SuperIO/ACPI 风扇，NPU DT 无 `fan`/`pwm` 节点。想做软件调速得先把 PWM 通道跟风扇对上（[19](19-module-vs-kernel-rebuild.md) §19.6） |

### 中优先级（想用某个功能时才需要）

| # | 事项 | 现状 |
|---|---|---|
| 5 | **LED 极性 / 映射未逐一验证** | 面板灯走 PHY 的 LED 控制寄存器；`PCA9555` 驱动面板灯已被证伪。要逐个口试（[06](06-switch-and-ports.md)、[12](12-measurements.md)） |
| 6 | ~~交换机 port 5–8 是否引到面板~~ | ✅ **已确认（用户）**：XGS 87 面板就是 4 口，port 5–8 是 **XGS 107** 才有。不用再查 |
| 7 | ~~**MCP2210 SPI NOR 读写工具**~~ | ✅ **已完成（2026-11-24）**：`tools/on-x86/mcp2210-nor.py`；实机读到 JEDEC `C2 20 16` 和 env。GP0=CS，GP0/3/5 hold/release，只写 env。见 [23](23-mcp2210-spi-nor.md) |
| 8 | **x86 的 i2c-dev / GPIO 暴露** | 目前没开，接外设时再弄 |
| 9 | **`dev_write … 4 f002/2000` 的字段含义** | 已确认是 SerDes/PCS 块，细节要 datasheet |

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
| ~~`apt upgrade` 内核~~ | 以前会：`ntb_*.ko`、`mv88e6xxx`、`mvpp2`、vNTB 全是对着固定版本编的 | ✅ **已解决（2026-11-23）**：模块改成 **DKMS**，内核升级会自动重编。x86 已实机从 6.12.94 升到 **6.12.118**，NPU 已切回**发行版内核**，全部正常。见 [19](19-module-vs-kernel-rebuild.md) §19.2 |
| 手工 `rmmod ntb_hw_epf`（x86） | 端点已失联时 `ntb_epf_spad_write()` 会写野指针 → panic | 已修（spad 守卫），但顺序错了仍危险 —— 交给关机钩子做；`xgs-ntb-watch` 默认只重建本地 VLAN，不碰 PCIe |
| 写 SPI `mtd0` | U-Boot 在那儿，写坏就得靠 MCP2210 或 JTAG 救 | 只读，从不写；有备份。唯一的例外是 `mtd0-restore --unsafe-mtd0 --commit`（刷坏后回滚用，见 [23](23-mcp2210-spi-nor.md) §23.5） |
| 格式化 `/persistent`（p4） | 丢机型和 MAC 基址 | 只读使用 |
| 往 `p1` 上放系统 | 那是原厂冷备槽，留着回滚 | 空着 |
| **把裸文件系统镜像写到整盘**（`dd if=p2.img of=/dev/mmcblk0`） | **LBA 0 的 MBR 被 ext4 超级块覆盖 → `No partition table - mmc 0`**，所有分区消失（2026-11-24 那台就是这么砖的） | 脚本层已加守卫：`require_partition` / `require_whole_disk`（[07](07-storage.md) §7.6）。裸 FS 镜像只写 `...p2`，整盘镜像才写 `/dev/mmcblk0` / `/dev/sdX` |
| 在 NPU 还没稳定启动时跑 `xgs-ntb-up.sh --force-rescan` | 一次 remove/rescan 就会拉 PERST#，把正在启动的 NPU 打断；循环做就是 2026-11-25 的 3.2 s "自复位" | **默认不自动 rescans**；等 NPU 起来后手动执行一次。`xgs-ntb-watch` 默认只重建本地 VLAN |
| **在端点抖动时读它的 PCIe 配置空间**（哪怕只是 `lspci`） | **x86 会直接重启**。2026-11-25 实测：`lspci -nn \| grep -i 11ab` 一跑机器就重启（当晚这样崩了 4~5 次）。端点复位风暴期间，主机在抖动窗口里读 config space 会触发致命错误 | 用 sysfs 判存在性（`[ -e /sys/bus/pci/devices/0000:03:00.0 ]`），**端点不稳定时不要 `lspci`**；真正要"脱开"这条链路就用 Link Disable（`setpci -s 00:03.1 CAP_EXP+10.w=0010`），见 [tools/on-x86/x86-linkoff-test.sh](../tools/on-x86/x86-linkoff-test.sh) |

> ⚠️ NPU 的 1.5 GB 根分区**装不下 `full` 变体**（root 解开约 900 MB）。现在实测 1.4G/1.5G，
> 只剩 276 MB。三条路：装 `--variant lean`（解开 525 MiB，**推荐**，工具链编完就删掉）、
> 把根分区做到 ≥3 GB、或者 `--variant base` + 之后自己跑 `kernel/npu/install.sh`
> （见 [image/README.md](../image/README.md)）。`lean` 的内核被 `apt-mark hold`，
> 要升级内核时先 `apt-mark unhold linux-image-arm64` 再跑 `/opt/xgs87/kernel/npu/install.sh`。

## 9.5 如果要重做一遍（换机 / 重刷的最小路径）

现在最省事的路是 **`debian-usb` 维护 U 盘**：插上去选 `1` 重装 x86、选 `2` 重装 NPU
（见 [21](21-reproduce.md)、[22](22-from-sfos.md)）。手工做的话按这个顺序：

1. **备份**：eMMC 整盘 + `mtd0`(U-Boot) + `mtd1`(env)，SHA256 存档（[07](07-storage.md)）。
2. **改 U-Boot env**：`bootcmd` → `bootcmd_deb10g`（`ext4load` Image + dtb + initrd → `booti`），
   注意 `bootcmd_deb10g` 先用 `mvswitch` 把 port 9 配成 10G（[03](03-boot-chain.md)）。
3. **DTB**：`board/cn9130-sophos-xgs87w-sfp10g.dts`（本仓库；节点里保留了 `ramoops`，
  但已被 DDR scrub 证伪，留着不影响启动），`tools/build/build-dtb.sh` 生成
  `out/cn9130-sophos-xgs87w-sfp10g.dtb`。
4. **模块**：`kernel/npu/install.sh` / `kernel/x86/install.sh`（DKMS 包，内核升级自动重编）。
   只有要改驱动源码时才用 `tools/build/*` —— 它负责先把 `ntb/*.patch`、`net/patches/*`
   打到上游源码上再编。
5. **网络**：`systemd/npu/` 装到 NPU、`systemd/x86/` 装到 x86（见 [systemd/README.md](../systemd/README.md)、[20](20-lan-over-vntb.md)）。
6. **别做的事**：见 §9.4 的维护红线 —— `mtd0` 永不写、别手工 `rmmod ntb_hw_epf`、
   `p1` 留给原厂回滚、`/persistent` 只读。内核包不用再 hold，DKMS 会跟着重编。

> 完整的实测数据见 [12-measurements.md](12-measurements.md)；
> 每篇文档开头都有状态标记（✅ 实测 / 📦 原厂档案 / 💡 设想 / ⚠️ 未验证）。
