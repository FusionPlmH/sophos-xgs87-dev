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

**Debian 正常时（实测 `/proc/cmdline`；当前 p2 待重刷，芯片上暂时从 p3 启动）**：

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

> 2026-11-25 救砖后，芯片上的 `bootcmd` 暂时是 `run mbrfix; run bootcmd_emmc3`
> （从完好的 p3 原厂槽启动）。等 p2 重刷完成，再改回 `run bootcmd_deb10g`。
> `/boot/Image` 和 `/boot/initrd.img` 是固定文件名；安装 tar 时必须补齐这两个
> （见 [07](07-storage.md) §7.4）。

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
AMI UEFI (BIOS 1906) → Boot0000 shimx64.efi → grub → Debian (6.12.118+deb13-amd64)
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

## 3.6 2026-11-24/25 砖机事件：真实根因与恢复

> 这一节**取代** 2026-11-24 深夜到 11-25 凌晨的几条中间结论。那些结论（"BL31→BL33 复位"、
> "CP0 MSS 起不来"、"SPI/UART 通道坏了"、"3.2 s 硬件定时复位"）都是在 x86 侧
> remove/rescan 风暴里观察到的**表象**，不是 NPU 的硬件故障。

### 真实时间线

1. **p2 的 MBR 被覆盖**：`p2.img` 是 `mkfs.ext4` 出来的裸文件系统（没有分区表），却被
   `dd if=p2.img of=/dev/mmcblk0`（整盘）写进去。LBA 0 变成 ext4 超级块，U-Boot 报
   `** No partition table - mmc 0 **`，所有 `ext4load` 失败。
2. **env 被反复 `saveenv` 写坏**：U-Boot 的 env 区没有先擦后写，连续多次 `saveenv`
   留下半截默认 `bootcmd=bootp …`，串口上表现为无限 `BOOTP broadcast`。
   用 [mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py) 的 `flash-write --offset 0x3F0000`
   整块重写 64 KiB env 后，CRC 恢复。
3. **x86 自己制造了复位循环**：原版 `xgs-ntb-up.sh` 每 2 s 做一次
   `remove` + `rescan`。每次 rescan 都会重新拉 PERST#，NPU 刚启动到一半就被打断，
   于是表现为约 3.2 s 一轮的"自复位"。`l` 不是 U-Boot 的第一个字节，而是下一条
   `NOTICE` 的首字符被 UART 重配吃掉；停掉 rescan 后 U-Boot 能正常走到 `Marvell>>`。
4. **MBR 已修回**：U-Boot 执行 env 里的 `mbrfix`，把原厂 512 字节 MBR
   （4 个分区、磁盘签名 `0xFAE598E3`）写回 LBA 0；从芯片读回
   `step=12`（`part start mmc 0 2` 成功）、`pstart=0xFA800`（= 1026048，与原厂 MBR
   里 p2 的起始 LBA 一致）。
   ⚠️ **确认 `step=12` 后要把 `bootcmd` 改回 `run bootcmd_emmc3`（或 `run bootcmd_deb10g`）**，
   不要把 `mbrfix` 留在每次启动的路径里：它每步都 `saveenv`，连续写会再次把 env 写坏。
5. **flash 侧全部是好的**：`mtd0` 与参考逐字节一致（SHA-256
   `fe13a2a3…`），env CRC 正常，MCP2210 读到 SR=0。**不要再刷 SPI NOR。**

> ⚠️ **"MBR 到底有没有坏"有两种现场记录，别拿单条日志当判决**。更早的 `REPORT.md`（同一台机器、
> 11-24）认为 `No partition table - mmc 0` 只是瞬态、MBR 从未丢过，依据是内核日志里
> `mmcblk0: p1 p2 p3 p4` 和 p3 正常挂载 —— 但这**不构成反证**：只要那份日志来自 `mbrfix`
> 成功之后的某次启动，两种说法都成立。`mbrfix` 的 `step=12` / `pstart=0xfa800` 也分辨不了，
> 把同一份 MBR 再写一遍同样会得到这两个值。唯一能分辨的是 p2 现在能不能挂上，
> 检查命令与判断标准见 [09](09-remaining-work.md) §9.2 第 0 步；**在跑那个只读检查之前
> 不要重刷 p2**（重刷是破坏性操作）。

### 当前状态（2026-11-25）

- U-Boot 2019.10 能正常跑到 `Marvell>>`；env 里的 `bootcmd` 已恢复为原厂
  `run bootcmd_emmc3`（从 p3 启动）。
- p2 的分区表项已经回来，但 p2 **自己的 ext4 超级块不在原位**（当初那句 dd 把
  p2.img 的前 1023 MiB 写到了 LBA 0）。恢复方法是把 `p2.img` 重刷到
  **`/dev/mmcblk0p2`（分区节点）**，不是整盘；命令见 [09](09-remaining-work.md) §9.2。
- p3 原厂系统完好，可作为回滚/对照。
- x86 的 `xgs-ntb-up.sh` 默认只等待 vNTB 设备、**不 remove/rescan**；watcher 默认也
  不自动重置。NPU 起来后要手动 `sudo xgs-ntb-up.sh --force-rescan`，或把
  `/etc/default/xgs-ntb-watch` 里的 `AUTO_RECOVER=1` 打开（5 分钟后只试一次）。

### 被推翻的中间结论（保留作教训）

| 当时的结论 | 为什么错 |
|---|---|
| "复位发生在 BL31→BL33 交接，U-Boot 起不来" | 停掉 x86 的 remove/rescan 后 U-Boot 正常到 `Marvell>>`；`l` 是下一条 NOTICE 的首字符 |
| "CP0 MSS CPU 从来没被启动，是 CP 硬件/固件故障" | 同一轮 reset 风暴里 MSS 的打印被打断；没有独立证据表明 MSS 本身坏了 |
| "3.2 s 周期复位是 NPU 自己的看门狗" | 周期与 x86 `xgs-ntb-up.sh` 的 2 s rescan 对齐；停掉后消失 |
| "UART/XMODEM 通道在最后一块被复位，通道不可用" | 4 KiB 载荷的 XMODEM + EOT 实测成功；4 MiB 中断与同一轮 rescan 风暴重叠，不能归因于通道 |
| "ramoops 能留下上一次的 panic" | 每次复位都重跑 `mv_ddr` 训练 + 全内存 scrub，保留区在 Linux 起来前就被清空（[20](20-lan-over-vntb.md) §20.8） |

### 操作红线

- **不要把裸文件系统镜像写到整盘**；`require_partition` / `require_whole_disk` 已经在
  [installer/payload/lib.sh](../installer/payload/lib.sh) 里强制这一点。
- **不要频繁 `saveenv`**；env 区没有先擦后写，连续写很容易留下半截内容。
- **不要在 NPU 启动窗口里 remove/rescan**。判存在性用
  `[ -e /sys/bus/pci/devices/0000:03:00.0 ]`，不要用 `lspci`；端点抖动时读 config space
  会把 x86 直接搞重启（2026-11-25 实测 4~5 次）。
- 救砖工具与安全模型见 [23](23-mcp2210-spi-nor.md)；U-Boot 控制脚本见
  [tools/on-x86/npu-uboot.py](../tools/on-x86/npu-uboot.py) 和
  [tools/on-pc/npu-uboot-run.py](../tools/on-pc/npu-uboot-run.py)。
