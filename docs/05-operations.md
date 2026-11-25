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
| `xgs-ntb-watch` | 只**看**链路状态；`AUTO_RECOVER=1` 时每 10 分钟最多动一次手：先 `--force-rescan`（ID 被缓存的情形），仍无端点再 `--retrain`（toggle 根端口的 Link Disable，让 LTSSM 重新训练）。循环 rescan 会把 NPU 复位，所以次数是封顶的 |

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

## ssh（装完就能用，不需要先交换钥匙）

镜像里不带任何私钥，只有 `admin` / `P@ssw0rd` 和 `PasswordAuthentication yes`，再加一份
客户端配置 `image/overlay/common/etc/ssh/ssh_config.d/10-xgs87.conf`：

- `StrictHostKeyChecking accept-new` —— 第一次连不问 yes/no；
- `ControlMaster` + `ControlPersist 12h` —— **密码只输一次**，之后的 `ssh`/`scp`/脚本里的
  `BatchMode` 全部复用那条连接，12 小时内不再问。

```sh
ssh admin@10.234.56.1            # 第一次输一次密码
ssh admin@10.234.56.1 'uptime'   # 复用同一条连接，不再问
```

想彻底免密（给 cron/脚本用，或者不留 master 连接），上来做一次就行：

```sh
ssh-copy-id admin@10.234.56.1   # 从 x86 到 NPU
ssh-copy-id admin@10.234.56.2   # 从 NPU 到 x86
```

脚本要跨机器时别依赖钥匙：`installer/payload/lib.sh` 的 `npu_ssh`（`SSH_ASKPASS` 拿密码，
`npu-sshdd.sh` 同一套）在新装的系统上就成立。

## 控制台的坑

- **两个读者会把串口字节流切成乱码**。看到乱码先 `pgrep -af ttyS2`。
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
| 上电后 x86 完全没网 | 看 `lspci -nn \| grep 1957` —— **分三种，处理完全不同**：<br>① 有 `1957:0809`、`/sys/bus/ntb/devices/*` 也在、就是没有 `eth0` → 端点已枚举且 bind，只是 `ntb_transport`/`ntb_netdev` 没起来（开机时 `xgs-ntb` 等不到设备先失败退出了）。重跑 `xgs-ntb-up.sh`（**不碰 PCIe**，可以反复试；watcher 现在自动做这件事）<br>② 什么都没有，NPU 侧 `cat /sys/class/net/eth0/carrier` 是 0 → **链路没 train**（BIOS 扫总线时 NPU 端点还没武装，NPU 从上电到 vNTB 就绪要 ~12 秒），`rescan` 找不到"电上不存在的功能"：在 **host** 上 `xgs-ntb-up.sh --retrain`（toggle 根端口 Link Disable）<br>③ 有设备但 ID 是 `11ab:7080` → 枚举时读到的还是固件出厂身份，被内核缓存了：`xgs-ntb-up.sh --force-rescan` |
| 现在这套是怎么自愈的 | 2026-11-25 补的：`xgs-ntb-watch` 每轮先看"端点在但没 netdev"（→ 重跑 `xgs-ntb-up.sh`，最便宜），攒够 5 分钟再看 `AUTO_RECOVER=1` 就 `--force-rescan`，还不行再 `--retrain` |
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
