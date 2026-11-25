# 03 · 启动链（实录）

> 🏷 **状态（2026-11-23 复核）**：📦 **原厂档案**：BootROM / TF-A / U-Boot 的实录，改造后未变（U-Boot 仍是原厂 2019.10，只换了它引导的内核）。

以下是 NPU 从上电到 shell 的完整串口输出，可作为调试基线。

## 3.1 NPU 启动日志

```
BootROM - 2.03
Starting CP-0 IOROM 1.07
Booting from SPI NOR flash 0 (0x34)
Found valid image at boot postion 0x000
NOTICE:  Starting binary extension
Setting up Comphy lane 0 as PCIe
Setting up Comphy lane 1 as PCIe
NOTICE:  SVC: DEV ID: CN913x, FREQ Mode: 0xd
NOTICE:  SVC: AVS work point changed from 0x2e9 to 0x2df
mv_ddr: 10.22.03-g1ef15fe (Sep 22 2022 - 09:52:35 AM)
SNPS DDR: 1D training passed
SNPS DDR: 2D training passed
mv_ddr: scrubbing memory...
mv_ddr: completed successfully
NOTICE:  Booting Trusted Firmware
NOTICE:  BL1: v2.2(release):1ef15fe (Marvell-10.22.06)
NOTICE:  BL2: v2.2(release):1ef15fe (Marvell-10.22.06)
NOTICE:  SCP_BL2 contains 7 concatenated images
NOTICE:  Load image to CP0 MG
NOTICE:  Load image to CP0 MSS AP0
NOTICE:  BL31: v2.2(release):1ef15fe (Marvell-10.22.06)

U-Boot 2019.10-10.22.03 (Sep 22 2022 - 09:52:18 -0400)
Model: Marvell CN9130 Senao XGS board
SoC: cn9130-A1; AP807-B0; CP115-A0
Clock:  CPU 1600 [MHz]  DDR 1200 [MHz]  FABRIC 1200 [MHz]  MSS 200 [MHz]
DRAM:  2 GiB
Comphy chip #0:
Comphy-0: IGNORE        Comphy-1: IGNORE
Comphy-2: UNCONNECTED   Comphy-3: UNCONNECTED
Comphy-4: SFI0          10.3125 Gbps
Comphy-5: UNCONNECTED
UTMI PHY 0 initialized to USB Host0
UTMI PHY 1 initialized to USB Host1
MMC:   sdhci@6e0000: 0
Loading Environment from SPI Flash... SF: Detected mx25l3205d with page size 256 Bytes,
erase size 4 KiB, total 4 MiB
OK
Net:   eth0: mvpp2-0
Autoboot in 3 seconds - press SPACE to stop...
```

要点：

- **Comphy lane 4 固定为 SFI0 10.3125 Gbps** —— 这是到交换机的 10G 链路。
- Comphy lane 0/1 给 PCIe 用（endpoint）。
- SPI NOR 型号 `mx25l3205d`，4 MiB。
- `BootROM` 从 **SPI NOR flash 0** 启动（不是 eMMC），所以 U-Boot 刷坏了需要用
  x86 的 MCP2210 或者板载 JTAG 救。

## 3.2 内核命令行

**原厂（p3，历史）**：

```
console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 rootwait ro
pci=pcie_bus_safe root=/dev/mmcblk0p3 cpuidle.off=1
isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3
```

`isolcpus=1-3` / `nohz_full=1-3` —— 原厂把 3 个核隔离出来专给转发，只有 CPU0 跑控制面。

**Debian 正常时（实测 `/proc/cmdline`，2026-11-25 p2 启动）**：

```
console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
```

- 去掉了 `isolcpus` / `nohz_full` / `rcu_nocbs`：我们不再把 CPU 绑给转发平面，
  4 个核交给调度器（原本那是给原厂包转发线程的准备）。
- 加了 **initrd**：Debian 的 `Image` 需要它来加载早期模块（`spi-orion`、`clkfix` 等）。
- `rootwait rw`：等 eMMC 就绪再挂根。
- `pci=pcie_bus_safe` 也去掉了（vNTB 自己做 BAR 对齐）。

## 3.3 U-Boot 完整环境变量

### 原厂（备份，见 `reference/uboot-env.txt`）

```
arch=arm
cpu=armv8
soc=mvebu
bootdelay=3
bootcmd=ext4load mmc 0:3 $kernel_addr_r /boot/Image; ext4load mmc 0:3 $fdt_addr_r /boot/cn9130-senao-xgs.dtb; run fdt_set_partno; booti $kernel_addr_r - $fdt_addr_r
bootcmd_emmc1=ext4load mmc 0:1 $kernel_addr_r /boot/Image; ext4load mmc 0:1 $fdt_addr_r /boot/cn9130-senao-xgs.dtb; run fdt_set_partno; booti $kernel_addr_r - $fdt_addr_r
bootcmd_emmc2=… 同上, 0:2 …
bootcmd_emmc3=… 同上, 0:3 …
bootargs=console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 rootwait ro pci=pcie_bus_safe root=/dev/mmcblk0p3 cpuidle.off=1 isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3
bootargs_emmc1/2/3=… root=/dev/mmcblk0p1/p2/p3 …
kernel_addr_r=0x7000000
fdt_addr_r=0x6f00000
fdt_set_partno=fdt addr $fdt_addr_r; fdt set /usfp_rh assembly_partno $partno
partno=AMDA0200-0001
ethaddr=<redacted>
eth1addr=00:51:82:11:22:01 … eth4addr=00:51:82:11:22:04
sw_init_p0=gpio clear C17; sleep 2; gpio set C17; sleep 2
sw_init_p1=for i in '0 1 2 3 4 5 6 7 8 9' ; do mvswitch 2 write $i 4 0x7f ; done
sw_init_p2=for i in '0 9'; do mvswitch 2 dev_write $i 4 f002 804d ; mvswitch 2 dev_write $i 4 2000 9140 ; done
sw_init_p3=for i in '1 2 3 4 5 6 7 8' ; do mvswitch 2 phy_write $i 0 0 9140 ; done
sw_init_2=run sw_init_p0; run sw_init_p1; run sw_init_p2; run sw_init_p3
```

### 现在（Debian 时代的变量，`fw_printenv` 实测）

Debian 槽正常时，`bootcmd` 指向 `bootcmd_deb10g`：

```
bootcmd=run bootcmd_deb10g
bootcmd_deb10g=mvswitch 2 write 9 0 0xd; mvswitch 2 dev_write 9 4 f002 0x804d; mvswitch 2 dev_write 9 4 2000 0x9140; run bootcmd_deb
bootcmd_deb=ext4load mmc 0:2 ${kernel_addr_r} /boot/Image; ext4load mmc 0:2 ${fdt_addr_r} /boot/cn9130-sophos-xgs87w-sfp10g.dtb; ext4load mmc 0:2 ${ramdisk_addr_r} /boot/initrd.img; setenv bootargs ${bootargs_deb}; booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
bootargs_deb=console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw
bootdelay=3
partno=AMDA0200-0001
```

> **2026-11-25 复测**：芯片上的 `bootcmd` 已是 `run bootcmd_deb10g`，p2 正常起 Debian 13.8。
> 之前 p2 "像砖"只是因为 `/boot/initrd.img` 这个名字不存在（见 §3.6）；`/boot/Image` 和
> `/boot/initrd.img` 都是固定文件名，安装 tar 时必须补齐（[05](05-storage.md) §5.4）。
> 回原厂槽：`fw_setenv bootcmd 'run bootcmd_emmc3'`（用 `fw_setenv`，不要反复 `saveenv`）。

- 原厂的 `bootcmd_emmc1/2/3`、`sw_init_*`、`fdt_set_partno` **都还在**，只是不再被 `bootcmd` 引用。
  回原厂：`setenv bootcmd 'run bootcmd_emmc3'; saveenv`。
- `mvswitch … write 9 0 0xd` 是**在 U-Boot 里手工把 port9 的 CMODE 设成 10GBASE-R**
  （DSA 起来后会重新配一遍，这一步只是让 SFP 在 boot 早期就能 link）。

### 怎么用这些槽位

- `bootcmd_emmc1/2/3` 就是"从第 N 个分区启动"，换系统时最省事（当初装 Debian 就是这么来的）：
  ```
  setenv bootcmd "$bootcmd_emmc1"
  saveenv
  ```
- `fdt_set_partno` 会把 `$partno` 塞进 DT 的 `/usfp_rh/assembly_partno` —— 原厂用它区分机型。
  mainline DTB 里没有这个节点，**现在不调它**（调了会 `fdt set` 报错）。
- **`for i in '0 1 2 3 …'` 是坑**：U-Boot 的 hush 会把引号里的整串当一个词，
  循环体只会执行一次（参数爆炸）。要可靠就逐口写死：

  ```
  mvswitch 2 write 0 4 0x7f
  mvswitch 2 write 1 4 0x7f
  …
  mvswitch 2 phy_write 1 0 0 0x9140
  ```

  （实测：port1/port4 的 reg4 都确实读回 0x7F，说明还有别的路径配过，但脚本本身不可靠。）

## 3.4 中断进 U-Boot 的方法

> 2026-11-24 凌晨曾经到不了 `Autoboot in 3 seconds`，根因是 x86 侧的 remove/rescan
> 风暴（见 §3.6），不是 U-Boot 本身。停掉之后 U-Boot 正常。

- 上电后 `Autoboot in 3 seconds - press SPACE to stop...`，3 秒内敲任意键（空格即可）。
- 从 Linux 里：`reboot`，然后立刻在串口上连续发空格（每 150 ms 一个，坚持 8-10 秒）。
  可直接用维护盘的 **菜单 4（NPU 串口）**，或
  [installer/payload/npu-uboot.sh](../installer/payload/npu-uboot.sh)；它自己发
  `sudo -S systemctl reboot` + 密码，然后连敲 20 秒空格再交给 picocom。

> ⚠️ 停在 U-Boot 意味着 NPU 的 Linux 不在跑 —— **vNTB 也就断了**，x86 那两条 VLAN
> （`eth0.100`/`eth0.200`）随之消失。要用 U-Boot 从 x86 传数据，必须插一块 USB 网卡、
> 用网线接到面板口（交换机在 U-Boot 里默认转发）；只有串口的话 190 MB 要几个小时。

## 3.5 x86 启动

```
AMI UEFI (BIOS 1906) → Boot0000 shimx64.efi → grub → Debian (6.12.117+deb13-amd64)
```

`efibootmgr -v`：

```
BootCurrent: 0000
BootOrder: 0000,0002,0001
Boot0000* debian  HD(1,GPT,…)/File(\EFI\DEBIAN\SHIMX64.EFI)
Boot0001* grub    VenHw(99e275e7-…)
Boot0002* debian  HD(1,GPT,…)/File(\EFI\DEBIAN\GRUBX64.EFI)
```

- 走 **UEFI + GPT**（参考机型的 XGS 107 是 MBR/SATA，装系统的方式不一样，注意别照抄）。
- Secure Boot 处于未启用状态（shim 存在但内核未签名也能起）。

## 3.6 2026-11-24/25 砖机事件：复盘与最终结论

> **2026-11-25 现场复查后的结论：eMMC 上的数据从来没有丢过。** p1/p2/p3/p4 全部完好，
> SPI NOR 也没坏。当时看到的三个现象各有别的解释 —— U-Boot 一次分区表读取失败
> （`** No partition table - mmc 0 **`）、env 被反复 `saveenv` 写坏、x86 侧 remove/rescan
> 造成的 3.2 s 复位风暴。真正让 p2 "起不来"的原因是 **`/boot/initrd.img` 不存在**。

### 决定性证据（2026-11-25 直接从机器上读）

| 检查 | 结果 |
|---|---|
| LBA0 偏移 `0x438` 的 ext4 magic | `0000` —— **没有** ext4 超级块。把裸 ext4 写到整盘一定会在 1024 字节处留下 magic，而 `mbrfix` 只写前 512 字节，清不掉它 |
| LBA0 偏移 `0x1B8` / `0x1BE` | 磁盘签名 `0xFAE598E3`（原厂值）+ 4 个分区项 + `55AA` |
| p1 挂载 | ✅ 旧 Sophos 槽（有 `linuxrc`、`persistent`），超级块完好 |
| p2 挂载 | ✅ Debian 13.8，570 MB / 1536 MB 已用，`/etc/debian_version` = `13.8` |
| p3 | ✅ 原厂 Buildroot 正常启动（本节的现场） |
| p4 | ✅ VPD：`eth.mac=7C:5A:1C:XX:XX:0C`（基址，已脱敏）、`eth.macs=7` |

⇒ "那句 `dd if=p2.img of=/dev/mmcblk0` 把前 1.5 GiB 写到了 LBA 0" 这个说法**被证伪**：
磁盘开头没有任何 ext4 痕迹，p1 和 p2 的内容也都还在。那次 `dd` 要么没落到这块盘上，
要么刚写了个开头就被中断（那也足以让 U-Boot 报一次 `No partition table`）。

### p2 起不来的真正原因

`bootcmd_deb` 按**固定文件名**加载三样东西：

```
/boot/Image                                 ← p2 里有
/boot/cn9130-sophos-xgs87w-sfp10g.dtb       ← p2 里有
/boot/initrd.img                            ← p2 里【没有】，只有 initrd.img-6.12.117+deb13-arm64
```

第三次 `ext4load` 失败后，`bootcmd_deb` 仍然往下执行 `booti … ${filesize}`，用的是上一次成功
加载的长度 ⇒ 内核拿到一个无效的 initrd，表现为"卡住/像砖了"。文件系统本身一直是好的。

**修复（2026-11-25 实测，一条命令级）**：

```sh
# 从 p3 或任何一个能写 p2 的系统上
ln /boot/initrd.img-6.12.117+deb13-arm64 /boot/initrd.img   # 硬链接，不占空间
fw_setenv bootcmd 'run bootcmd_deb10g'
reboot
```

改完立刻进 Debian 13.8。镜像侧也已经修好：[image/setup.sh](../image/setup.sh) 构建时用硬链接
补出 `/boot/Image` 和 `/boot/initrd.img`，新装出来的 p2 不会再缺这两个名字。

### 另外两个坑（当时被误当成根因）

1. **env 被反复 `saveenv` 写坏** → 半截默认 `bootcmd=bootp …`，串口上无限 `BOOTP broadcast`。
   用 [mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py) 的 `flash-write --offset 0x3F0000` 整块重写
   64 KiB env 后 CRC 恢复。以后改 env 用 `fw_setenv`（先擦后写），不要反复 `saveenv`。
   ⚠️ NPU 镜像以前**没带 `/etc/fw_env.config`**，`fw_setenv` 直接报
   `Cannot initialize environment`；现在已经带上（[image/overlay/npu/etc/fw_env.config](../image/overlay/npu/etc/fw_env.config)），
   顺带修好了"读不到 `ethaddr` 就不设端口 MAC"的问题（[04](04-switch.md) §4.6）。
2. **x86 的 remove/rescan 风暴** → 每 2 s 拉一次 PERST#，NPU 刚启动就被打断，表现为约 3.2 s
   一轮的"自复位"。停掉后 U-Boot 正常走到 `Marvell>>`。现在 `xgs-ntb-up.sh` 默认只等待。

### mbrfix 的处置

env 里曾经是 `bootcmd=run mbrfix; run bootcmd_emmc3`。`mbrfix` 每步 `saveenv`，本身就是 env 被
写坏的原因之一；它写回的是**原厂那份 MBR**（签名一致），并没有修复任何被破坏的东西，但也没有坏处。
现在 `bootcmd` 已经改成 `run bootcmd_deb10g`，**不要再把 `mbrfix` 加回启动路径**。

### 被推翻的中间结论（保留作教训）

| 当时的结论 | 为什么错 |
|---|---|
| "p2.img 写到整盘，MBR/分区表被毁，p2 内容要重刷" | LBA0 没有 ext4 magic，p1/p2 都能正常挂载（见上面的证据表）；p2 只缺一个 `initrd.img` 文件名 |
| "复位发生在 BL31→BL33 交接，U-Boot 起不来" | 停掉 x86 的 remove/rescan 后 U-Boot 正常到 `Marvell>>`；`l` 是下一条 NOTICE 的首字符 |
| "CP0 MSS CPU 从来没被启动，是 CP 硬件/固件故障" | 同一轮 reset 风暴里 MSS 的打印被打断；没有独立证据表明 MSS 本身坏了 |
| "3.2 s 周期复位是 NPU 自己的看门狗" | 周期与 x86 `xgs-ntb-up.sh` 的 2 s rescan 对齐；停掉后消失 |
| "UART/XMODEM 通道在最后一块被复位，通道不可用" | 4 KiB 载荷的 XMODEM + EOT 实测成功；4 MiB 中断与同一轮 rescan 风暴重叠，不能归因于通道 |
| "ramoops 能留下上一次的 panic" | 每次复位都重跑 `mv_ddr` 训练 + 全内存 scrub，保留区在 Linux 起来前就被清空（[11](11-operations.md) §11.1） |
| "U-Boot 的 `help` 是假的，`mmc`/`ext4ls`/`run` 都不存在" | `bootcmd` 里这些命令一直在正常执行；那次是串口输入被复位风暴打断（[10](10-console.md) §10.5 第 10 条） |

### 操作红线

- **不要把裸文件系统镜像写到整盘**；`require_partition` / `require_whole_disk` 已经在
  [installer/payload/lib.sh](../installer/payload/lib.sh) 里强制这一点。
- **装 rootfs tar 前先确认 `/boot/Image` 和 `/boot/initrd.img` 两个名字都在**（硬链接即可）；
  `bootcmd_deb` 用的是固定文件名，缺一个就"像砖"。
- **不要频繁 `saveenv`**；env 区没有先擦后写，连续写很容易留下半截内容。改 env 用 `fw_setenv`。
- **不要在 NPU 启动窗口里 remove/rescan**。判存在性用
  `[ -e /sys/bus/pci/devices/0000:03:00.0 ]`，不要用 `lspci`；端点抖动时读 config space
  会把 x86 直接搞重启（2026-11-25 实测 4~5 次）。
- 救砖工具与安全模型见 [14](14-rescue.md)；U-Boot 控制脚本见
  [tools/on-x86/npu-uboot.py](../tools/on-x86/npu-uboot.py) 和
  [tools/on-pc/npu-uboot-run.py](../tools/on-pc/npu-uboot-run.py)。
- 救砖工具与安全模型见 [14](14-rescue.md)；U-Boot 控制脚本见
  [tools/on-x86/npu-uboot.py](../tools/on-x86/npu-uboot.py) 和
  [tools/on-pc/npu-uboot-run.py](../tools/on-pc/npu-uboot-run.py)。
