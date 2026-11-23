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

**现在（Debian，实测 `/proc/cmdline`）**：

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

### 现在（Debian，实测 `fw_printenv`）

```
bootcmd=run bootcmd_deb10g
bootcmd_deb10g=mvswitch 2 write 9 0 0xd; mvswitch 2 dev_write 9 4 f002 0x804d; mvswitch 2 dev_write 9 4 2000 0x9140; run bootcmd_deb
bootcmd_deb=ext4load mmc 0:2 ${kernel_addr_r} /boot/Image; ext4load mmc 0:2 ${fdt_addr_r} /boot/cn9130-sophos-xgs87w-sfp10g.dtb; ext4load mmc 0:2 ${ramdisk_addr_r} /boot/initrd.img-6.12.117+deb13-arm64; setenv bootargs ${bootargs_deb}; booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
bootargs_deb=console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 root=/dev/mmcblk0p2 rootwait rw
bootdelay=3
partno=AMDA0200-0001
```

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

- 上电后 `Autoboot in 3 seconds - press SPACE to stop...`，3 秒内敲任意键（空格即可）。
- 从 Linux 里：`reboot`，然后立刻在串口上连续发空格（每 150 ms 一个，坚持 8-10 秒）。
  可直接用 `debian-usb` 菜单的 **`u`**（`installer/payload/npu-uboot.sh`），它自己发
  `sudo -S systemctl reboot` + 密码，然后连敲 20 秒空格再交给 picocom；手工的话就是
  `npu-console.sh` 里按住空格。

## 3.5 x86 启动

```
AMI UEFI (BIOS 1906) → Boot0000 shimx64.efi → grub → Debian (6.12.94+deb13-amd64)
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
