# 05 运维

## 账号 / 地址

| | 值 |
|---|---|
| 两个系统 | `admin` / `P@ssw0rd`（`sudo` 要密码，root 默认锁着） |
| p3 原厂 | `root` / `openwrt123` |
| NPU LAN | `10.234.56.1/24`（`br-lan`，VLAN 200） |
| x86 LAN | `10.234.56.2/24`（`eth0.200`） |
| NPU 控制台 | x86 的 `/dev/ttyS2`，**115200** |
| x86 控制台 | PC 的 COM5 → x86 `/dev/ttyS0`，115200 |

## 服务清单

装的是这些，`systemctl --failed` 必须是空的。

**两边都装**（`systemd/common/`）：`xgs87-growroot`（首次开机扩根，成功后留
`/var/lib/xgs87/grown`）。

**x86**（`systemd/x86/`）

| unit | 干什么 |
|---|---|
| `xgs-ntb` | 装 `ntb_hw_epf` + `ntb_transport`，等 `eth0` 出现交给 networkd |
| `xgs-ntb-watch` | 只**看**链路状态，不自己 remove/rescan（循环 rescan 会把 NPU 复位） |

**NPU**（`systemd/npu/`，脚本都在 `/usr/local/sbin/`）

| unit | 干什么 |
|---|---|
| `xgs-vntb` | configfs 建 `pci_epf_vntb`（`1957:0809`）→ 启 EPC → 装 `ntb_transport`+`ntb_netdev` |
| `xgs-ports-up` | 等 DSA 建出面板口 → 推 MAC（`ethaddr` +0..+5）→ `up` 让 PHY 协商 |
| `xgs-net-up` | 按 `/etc/xgs87/net.conf` 把口分进 `br-wan`(`p2`)/`br-lan`(`p1`)，两条 VLAN |
| `xgs-dhcp` | 只在 `net.conf` 里标了 `dhcp` 的桥上跑 `dhcpcd`（默认只有 `br-wan`） |
| `xgs-nat` | LAN → WAN 转发 + masquerade |
| `xgs-netconsole` | 把内核 console 推给 x86 和 PC（崩了取证用） |

## 控制台

```sh
# x86 上开 NPU 串口（同一时刻只能有一个读者！）
picocom -b 115200 /dev/ttyS2
timeout 5 cat /dev/ttyS2                     # 只看一眼

# 不带交互地敲 U-Boot / shell 命令
. installer/payload/serial.sh                # serial_run / serial_uboot / serial_read_until
```

坑：

- **两个读者会把字节流切成乱码**。看到乱码先 `pgrep -af ttyS2`。
- 登录要状态机，不能靠固定 `sleep`：等 `login:` 发用户名、等 `Password:` 发密码。
- 115200 是硬上限，别想提速（见 [01](01-hardware.md)）。
- PC 想直接接到 NPU 的 UART 上：x86 上跑 `installer/payload/relay.py`（见 [06](06-rescue.md)）。

## 开机自检

```sh
systemctl --failed --no-legend                     # 必须空
ip -br a                                           # x86: eth0 + eth0.100 + eth0.200
df -h /                                            # x86 ~15 GB；NPU 1524 MiB
sudo dmesg | grep -iE 'EXT4-fs error|I/O error'    # 必须空
ssh admin@10.234.56.1 'uptime'                     # x86 → NPU 那一跳
```

`xgs-ntb` 正常时是 `active (exited)`（`RemainAfterExit=yes`），不是 `running`。

## 已知故障 → 怎么办

| 现象 | 原因 / 处理 |
|---|---|
| x86 上 `eth0` 不存在，dmesg 刷 `endpoint unreachable, dropping doorbell` | BIOS 没在 POST 枚举到 endpoint。**重启一次 x86**（NPU 保持开机）。刷屏会冲掉串口控制台，先 `dmesg -n 1` |
| NPU 重启/重装后 vNTB 回不来 | 同上：重启 x86。想不重启就复位 NPU 见 [06](06-rescue.md) 的 secondary bus reset |
| `bootcmd_emmc3` 起 p3 → `No working init found` | p3 是只读的原厂系统，没有可用 init。别用这个 bootcmd |
| U-Boot 里 `ping`/`tftpboot` 不动 | 已知：U-Boot 的网络完全不通（ARP 都收不到）。只能走串口/急救 |
| `/dev/mmcblk0` 不存在（急救系统里） | eMMC 归 `sdhci-xenon-driver`（`xenon-sdhci`），不是 `sdhci-of-dwcmshc`。见 [06](06-rescue.md) |
| NPU 上没有 `p1..p8`，只有 `eth0` | DSA 模块没起来：MDIO 那层必须先于 `mvmdio`；`bridge` 要 `llc`+`stp`；`dsa_core` 要 `selftests`+`hsr` |
| 串口一片安静，`cat /dev/ttyS2` 什么都不给 | 有没有别的读者占着；NPU 是不是真的在跑（看 `xgs-ntb` 的 journal） |
| `ssh` 报 `Host key verification failed` | 换过系统，`known_hosts` 里的旧指纹还在：删掉那一行 |

## 还没做的

- 面板 LED 极性、`p5`–`p8` 的用途没验过。
- `br-wan` 的上游 DHCP 只在插了面板 2/WAN 时成立，没插时是 IPv4LL，两台都没有默认路由。
- x86 侧没有温度/风扇监控单元。
