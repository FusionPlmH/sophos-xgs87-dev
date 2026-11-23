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

## NPU 侧（`npu/`）

| unit | 脚本 | 干什么 |
|---|---|---|
| `xgs-ports-up.service` | `xgs-ports-init.sh` | 等 DSA 把 `p1–p8`/`sfp` 建出来 → 按 U-Boot env 的 `ethaddr` 推 9 个 MAC → 全部 `up` 让 PHY 协商 |
| `xgs-vntb.service` | `xgs-vntb.sh` | configfs 建 `pci_epf_vntb`（VID `1957:0809`）、`start` EPC、再装 `ntb_transport` + `ntb_netdev` |
| `xgs-mgmt-bridge.service` | `xgs-mgmt-bridge.sh` | `br-mgmt` = `p8` + `eth0.100`，`192.168.100.1/24`；`p8` 是 untagged access 口 |
| `xgs-lan-uplink.service` | `xgs-lan-uplink.sh` | `br-lan` = `p4` + `eth0.31`，**纯 L2 透传**（不配地址、不跑 STP） |
| `xgs-lan-dhcp.service` | —（直接 `dhcpcd`） | NPU 自己在 `br-lan` 上拿一个家里内网的地址 |
| `xgs-netconsole.service` | —（`modprobe netconsole`） | 把内核 console 推给 x86（管理 VLAN）和 PC（`br-lan`）。**这是崩溃取证的主要手段**，见 [docs/20](../docs/20-lan-over-vntb.md) §20.8 |

启动顺序由 `After=`/`Wants=` 串好，一次性 `enable --now` 全部即可：

```sh
sudo install -m755 systemd/npu/*.sh      /usr/local/sbin/
sudo install -m644 systemd/npu/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xgs-ports-up xgs-vntb xgs-mgmt-bridge xgs-lan-uplink xgs-lan-dhcp xgs-netconsole
```

前置条件（都在仓库别处）：

- 模块：`pci_ep_cfs` / `pcie_dw_plat` / `pci_epf_vntb` / `ntb_*` 在
  `/lib/modules/$(uname -r)/extra/`，由 `tools/build/build-npu-vntb.sh` 产出，**不压缩**。
- `spi-orion` + `clkfix` 自动加载（`/etc/modules-load.d/xgs87-hardware.conf`），
  `fw_printenv` 才能读到 `ethaddr`。
- 交换机是 DSA 的 `p*`/`sfp` netdev，需要 `mv88e6xxx`（`tools/build/build-npu-net.sh`）。

## x86 侧（`x86/`）

| unit | 脚本 | 干什么 |
|---|---|---|
| `xgs-ntb.service` | `xgs-ntb-up.sh` | 装 `ntb_hw_epf`+`ntb_transport`+`ntb_netdev`，等 `03:00.0` 枚举出来（必要时 remove/rescan），建 `eth0.100`/`eth0.31` 并**把 MAC 钉死** |
| `xgs-ntb-watch.service` | `xgs-ntb-watch.sh` | 每 15 s 查 `carrier` + `ping 192.168.100.1`，连续 1 min 不正常就重跑 `xgs-ntb-up.sh` |
| `xgs-ntb-stop.service` | `xgs-ntb-stop.sh` | 关机前把 `ntb_hw_epf` 卸掉 → 它往端点控制区写 `COMMAND_LINK_DOWN`，NPU 才不会拿着悬空指针 |
| `xgs-npu-console.service` | —（`cat /dev/ttyS2`） | **可选**：把 NPU 控制台连续录到 `/var/log/npu-console.log`。它会**独占** ttyS2，交互式调试前要先停 |
| `31-house-lan.network` | — | 装到 `/etc/systemd/network/`，给 `eth0.31` 跑 DHCP（家里内网地址） |
| `xgs-netconsole.service` | —（`nc -u -l -k 6666`） | 收 NPU 推来的内核 console，落到 `/var/log/npu-netconsole.log` |

```sh
sudo install -m755 systemd/x86/*.sh      /usr/local/sbin/
sudo install -m644 systemd/x86/*.service /etc/systemd/system/
sudo install -m644 systemd/x86/31-house-lan.network /etc/systemd/network/
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
