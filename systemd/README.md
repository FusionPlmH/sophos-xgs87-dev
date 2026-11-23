# systemd/ — 两台机器各自的 unit 和脚本

> 这里按**装到哪台机器上**分目录。装错机器的直接表现写在最后。

```
systemd/common/ 两台都装（首启扩分区）
systemd/npu/    装到 NPU（Debian 13 arm64，数据面）
systemd/x86/    装到 x86（Debian 13 amd64，通用计算）
```

脚本一律装到 `/usr/local/sbin/`，unit 装到 `/etc/systemd/system/`。
`image/setup.sh` 构建镜像时已经把这些都装好并 `enable` 了；下面各节的手工步骤只给
"不用镜像、自己装" 的场合。

## 两台都装（`common/`）

| unit | 脚本 | 干什么 |
|---|---|---|
| `xgs87-growroot.service` | `xgs87-growroot.sh` | 首次开机 `growpart` + `resize2fs` 把 root 分区扩到盘尾，成功后留 `/var/lib/xgs87/grown`。镜像按最小尺寸发布，填满盘就靠它 |

```sh
sudo install -m755 systemd/common/*.sh      /usr/local/sbin/
sudo install -m644 systemd/common/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable xgs87-growroot
```

`image/setup.sh` 另外做了几件"减负"的事，不在这个目录里：

- `/etc/systemd/journald.conf.d/xgs87.conf`：`SystemMaxUse=64M`、`SystemKeepFree=256M`。
  journal 是唯一的现场取证材料（见 [20](../docs/20-lan-over-vntb.md) §20.8），不能关，
  但要封顶 —— 真机上一度攒到 248 MB。
- `systemctl mask getty@tty1.service man-db.timer dpkg-db-backup.timer e2scrub_all.timer
  xfs_scrub_all.timer`：没有显示器/键盘、没有 man 页、没有 LVM/XFS，dpkg 的每日备份
  只是 eMMC 磨损。`fstrim.timer` 和 `apt-daily*` 保留。
- `image/overlay/common/etc/systemd/system/ssh.service.d/10-xgs87-hostkeys.conf`：
  镜像里刻意不带 `/etc/ssh/ssh_host_*`（否则每块盘同一身份），而 Debian 13 的
  `ssh.service` 只有 `ExecStartPre=sshd -t`、**自己不会生成**，所以 drop-in 里
  先 `ssh-keygen -A` 再 `sshd -t`。没有这个，装完机就没有 SSH。

## NPU 侧（`npu/`）

| unit | 脚本 | 干什么 |
|---|---|---|
| `xgs-ports-up.service` | `xgs-ports-init.sh` | 等 DSA 把 `p1–p8`/`sfp` 建出来 → 按 U-Boot env 的 `ethaddr` 推 9 个 MAC → 全部 `up` 让 PHY 协商 |
| `xgs-vntb.service` | `xgs-vntb.sh` | configfs 建 `pci_epf_vntb`（VID `1957:0809`）、`start` EPC、再装 `ntb_transport` + `ntb_netdev` |
| `xgs-net-up.service` | `xgs-net-up.sh` | 按 **`/etc/xgs87/net.conf`** 把面板口分成两个桥：`br-wan`（`p2` = 面板 `2/WAN`）+ `eth0.100`，`br-lan`（`p1` = 面板 `1/LAN`）+ `eth0.200`。两个桥各用一条 VLAN（100/200），谁都不用默认 VLAN 1 |
| `xgs-dhcp.service` | `xgs-dhcp.sh` | 在 `net.conf` 里选 `dhcp` 的桥上跑**一个** `dhcpcd`。默认只有 `br-wan` 是 `dhcp`；`br-lan` 默认 `static`（`10.234.56.1/24`，**不跑 DHCP 服务**）。也可以 `none` |
| `xgs-netconsole.service` | —（`modprobe netconsole`） | 把内核 console 推给 x86 和操作者的 PC，两个目标都走 `br-lan`。**这是崩溃取证的主要手段**，见 [docs/20](../docs/20-lan-over-vntb.md) §20.8 |

启动顺序由 `After=`/`Wants=` 串好，一次性 `enable --now` 全部即可：

```sh
sudo install -m755 systemd/npu/*.sh      /usr/local/sbin/
sudo install -m644 systemd/npu/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xgs-ports-up xgs-vntb xgs-net-up xgs-dhcp xgs-netconsole
```

### `/etc/xgs87/net.conf`

WAN / LAN 怎么分全在这个文件里（镜像里由 `image/overlay/npu` 带进去，`kernel/npu/install.sh`
只在文件不存在时放一份，不会覆盖你调好的）。`xgs-net-up.sh` 用 `.` 读它，所以是 **shell 语法**：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WAN_PORTS` | `p2` | 面板 `2/WAN`。留空等于不要 WAN 桥 |
| `WAN_MODE` | `dhcp` | `dhcp` / `static`（配 `WAN_ADDR`，可多个，空格分隔） / `none` |
| `LAN_PORTS` | `p1` | 面板 `1/LAN`（`p3`/`p4`/`p8` 默认不并入任何桥） |
| `LAN_MODE` | `static` | `static` 用 `LAN_ADDR`；`dhcp` 表示这个桥上跑 dhcpcd（本机不提供 DHCP 服务） |
| `LAN_ADDR` | `10.234.56.1/24` | LAN 上 NPU 自己的地址 |
| `LAN_VID` / `WAN_VID` | `200` / `100` | 两条 vNTB VLAN，x86 侧 `xgs-ntb-up.sh` 建同名设备 |

两个桥都用 `vlan_filtering` 且各占一个 VID（100 / 200）：共用默认 VLAN 1 的话，
交换芯片里的广播域其实只有一个，面板上的 WAN 和 LAN 会互通。

改完重启两个单元即可：`sudo systemctl restart xgs-net-up xgs-dhcp`。

前置条件（都在仓库别处）：

- 模块：`pci_ep_cfs` / `pcie_dw_plat` / `pci_epf_vntb` / `ntb_*` 在
  `/lib/modules/$(uname -r)/extra/`，由 `tools/build/build-npu-vntb.sh` 产出，**不压缩**。
- `spi-orion` + `clkfix` 自动加载（`/etc/modules-load.d/xgs87-hardware.conf`），
  `fw_printenv` 才能读到 `ethaddr`。
- 交换机是 DSA 的 `p*`/`sfp` netdev，需要 `mv88e6xxx`（`tools/build/build-npu-net.sh`）。

## x86 侧（`x86/`）

| unit | 脚本 | 干什么 |
|---|---|---|
| `xgs-ntb.service` | `xgs-ntb-up.sh` | 装 `ntb_hw_epf`+`ntb_transport`+`ntb_netdev`，等 `03:00.0` 枚举出来（必要时 remove/rescan），建 `eth0.100`（WAN）/`eth0.200`（LAN）并**把 MAC 钉死** |
| `xgs-ntb-watch.service` | `xgs-ntb-watch.sh` | 每 15 s 查 `carrier` + `ping 10.234.56.1`（NPU 的 `br-lan`，不依赖上游），连续 1 min 不正常就重跑 `xgs-ntb-up.sh` |
| `xgs-ntb-stop.service` | `xgs-ntb-stop.sh` | 关机前把 `ntb_hw_epf` 卸掉 → 它往端点控制区写 `COMMAND_LINK_DOWN`，NPU 才不会拿着悬空指针 |
| `xgs-npu-console.service` | —（`cat /dev/ttyS2`） | **可选**：把 NPU 控制台连续录到 `/var/log/npu-console.log`。它会**独占** ttyS2，交互式调试前要先停 |
| `100-wan.network` | — | 装到 `/etc/systemd/network/`，`eth0.100` 上跑 DHCP —— 上游给的租约，x86 的默认路由也从这里来 |
| `200-lan.network` | — | `eth0.200` 静态 `10.234.56.2/24`（NPU 是 `.1`）。LAN 上没有 DHCP 服务，所以固定写死；不配网关，默认路由交给 `eth0.100` |
| `xgs-netconsole.service` | —（`nc -u -l -k 6666`） | 收 NPU 推来的内核 console，落到 `/var/log/npu-netconsole.log` |

```sh
sudo install -m755 systemd/x86/*.sh      /usr/local/sbin/
sudo install -m644 systemd/x86/*.service /etc/systemd/system/
sudo install -m644 systemd/x86/*.network /etc/systemd/network/
sudo systemctl daemon-reload
sudo systemctl enable --now xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole systemd-networkd
```

前置条件：`ntb.ko`/`ntb_hw_epf.ko`/`ntb_transport.ko`/`ntb_netdev.ko`
（`tools/build/build-x86-vntb.sh` 产出，Debian 不自带 NTB 栈）。

⚠️ **不要手工 `rmmod ntb_hw_epf`**：x86 自己在用这条链路，卸它会把整机带崩。
要卸就交给 `xgs-ntb-stop.service` 在关机时做。

## 装错机器的症状

| 装错方向 | 现象 |
|---|---|
| NPU 脚本装到 x86 | `xgs-ports-init.sh` 等不到 `p8`/`sfp` 直接退出；`xgs-vntb.sh` 找不到 `/sys/class/pci_epc/f2600000.pcie` |
| x86 脚本装到 NPU | `xgs-ntb-up.sh` 找不到 `/sys/bus/ntb/devices/0000:03:00.0`（NPU 是 EP 不是 host），且会用掉 `eth0` 这个名字 |
| 两个都装 | 最惨：两边都去建 `eth0.100`，互相抢 |

## 名称对照（设备上装好的实际名字）

| 仓库路径 | 设备上的路径 |
|---|---|
| `systemd/x86/xgs-ntb.service` | `/etc/systemd/system/xgs-ntb.service` |
| `systemd/x86/xgs-ntb-up.sh` | `/usr/local/sbin/xgs-ntb-up.sh` |
| `systemd/npu/xgs-vntb.sh` | `/usr/local/sbin/xgs-vntb.sh` |

x86 上还有一个历史遗留的 `/usr/local/sbin/npuc`，功能和
[tools/on-x86/npu-console.sh](../tools/on-x86/npu-console.sh) 重复（少了 login 分支），
以仓库里的版本为准。
