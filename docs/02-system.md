# 02 系统

## NPU 的 eMMC 分区

| 分区 | 大小 | 是什么 | 能不能写 |
|---|---|---|---|
| `p1` | 500 MiB | 原厂 Marvell rootfs | **永远不写** |
| `p2` | 1524 MiB | **我们的 Debian 13** | 唯一写入目标 |
| `p3` | 1524 MiB | 原厂 Sophos 系统（Buildroot，只读起） | **永远不写**，救生艇 |
| `p4` | 100 MiB | VPD：序列号、MAC | **永远不写** |

p3 不是"备用槽"，是**退路**：p2 坏了要能从一个没被我们碰过的系统里出来。所以任何
"A/B 轮换"、"把 p2 克隆到 p3"的想法都不要做。

## 启动链

```
NPU： SPI NOR → TF-A BL31 → U-Boot 2019.10 →（env 在 SPI）→ bootcmd
x86： BIOS → GRUB（ESP）→ Debian
```

NPU 的 U-Boot 关键 env（`fw_printenv` 可读）：

```sh
bootcmd=run bootcmd_deb10g
bootcmd_deb10g=mvswitch 2 write 9 0 0xd; mvswitch 2 dev_write 9 4 f002 0x804d;
               mvswitch 2 dev_write 9 4 2000 0x9140; run bootcmd_deb
bootcmd_deb=ext4load mmc 0:2 ${kernel_addr_r} /boot/Image;
            ext4load mmc 0:2 ${fdt_addr_r} /boot/cn9130-sophos-xgs87w-sfp10g.dtb;
            ext4load mmc 0:2 ${ramdisk_addr_r} /boot/initrd.img;
            setenv bootargs ${bootargs_deb};
            booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
bootargs_deb=console=ttyS0,115200n8 earlycon=uart8250,mmio32,0xf0512000 \
             root=/dev/mmcblk0p2 rootwait rw
```

- `/boot/Image`、`/boot/initrd.img`、`/boot/cn9130-sophos-xgs87w-sfp10g.dtb` 三个名字是**写死的**，
  换内核时必须同时更新（`image/setup.sh` 会自动补齐前两个）。
- `bootcmd_emmc1/2/3` 是原厂留下的"从 p1/p2/p3 起"的入口，它们都 `run fdt_set_partno`
  （`fdt set /usfp_rh assembly_partno …`）。**`bootcmd_emmc3` 会在 p3 上 panic
  `No working init found`**；p3 只读、没有可用的 init，别指望它自己起。
- 想手动起 p2：`run bootcmd_deb10g`；想回出厂：`setenv bootcmd 'run bootcmd_emmc1'; saveenv`
  （p1 原厂 Marvell，能起）。

## 两个系统的 Debian

| | x86 | NPU |
|---|---|---|
| 版本 | Debian 13（trixie），内核 `6.12.117+deb13-amd64` | Debian 13，内核 `6.12.117+deb13-arm64` |
| 根 | 自己的 eMMC p2，`growroot` 扩到盘尾 | eMMC `p2`（1524 MiB），**不扩** |
| 账号 | `admin` / `P@ssw0rd`（`sudo` 要密码） | 同左 |
| 模块 | `ntb_hw_epf` + `ntb_transport`（DKMS，源码在 `kernel/x86/`） | `ntb_core` `ntb_transport` `ntb_netdev` `pci_epf_vntb` `pci_ep_cfs` `pcie_dw_plat` `clkfix`（`kernel/npu/`，装在 `updates/`） |
| 额外 | — | `mv88e6xxx`/`dsa_core`/`tag_dsa`/`bridge` 用来带面板口 |

镜像里刻意**不带** ssh host key，`image/setup.sh` 在首次启动前 `ssh-keygen -A`（Debian 13 的
`ssh.service` 自己不会生成，少了它装完就连不上）。

## 网络

x86 ↔ NPU 只有一条 10 Gb/s 的 vNTB，上面跑两条 VLAN，两边各是一座桥：

```
x86 eth0.100  ── DHCP ─────────────→  NPU br-wan（p2 + eth0.100）
x86 eth0.200  ── 10.234.56.2/24 ──→  NPU br-lan（p1 + eth0.200）
```

| 段 | VLAN | 谁 | 地址 | 说明 |
|---|---|---|---|---|
| WAN / 管理 | 100 | NPU `br-wan` | **DHCP**（插了上游才有） | x86 的默认路由也从这来 |
| LAN | 200 | NPU `br-lan` | 静态 `10.234.56.1/24`，**不跑 DHCP 服务** | 面板 1 插笔记本（自己配 `10.234.56.x`）能同时摸 `.1` 和 `.2` |
| LAN | 200 | x86 `eth0.200` | 静态 `10.234.56.2/24` | systemd-networkd |

配置在 NPU 的 `/etc/xgs87/net.conf`，由 `xgs-net-up.sh` 读：`WAN_PORTS`/`LAN_PORTS`、
`*_MODE`（dhcp/static）、`*_VID`、`LAN_ADDR`。

## vNTB（PCIe 上的虚拟网口）

- NPU 侧：`configfs` 建 `pci_epf_vntb`（`1957:0809`），`db_count=4`、`spad_count=128`、
  `mw1=0x100000`、`vbus_number=0x10`，然后 `echo 1 > controllers/f2600000.pcie/start`；
  再装 `ntb_transport` + `ntb_netdev` → 出现 `eth0`。整套在 `systemd/npu/xgs-vntb.sh`。
- x86 侧：`xgs-ntb.service` 装 `ntb_hw_epf`，等 `eth0` 出现后交给 networkd；
  `xgs-ntb-watch.service` 只**看**链路，不会自己 remove/rescan（循环 rescan 会把 NPU 复位）。
- **NPU 一重启，x86 的 vNTB 不会自己回来**：要重启一次 x86，让 BIOS 在 POST 重新训练链路。
  或者走 06 里的 secondary bus reset。
- 内核模块和补丁都在仓库里：`ntb/`（`pci-epf-vntb`、`ntb_hw_epf`、`pcie_dw_plat`、`pci_ep_cfs`）
  和 `kernel/{x86,npu}/`，不需要外部源码树。

## netconsole

NPU 把内核 console 推到 x86 和 PC（`xgs-netconsole.service`），崩了以后能取证；
journal 有上限（`SystemMaxUse=64M`）。
