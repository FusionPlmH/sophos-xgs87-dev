# 08 · 网络：面板口、VLAN、WAN/LAN 与 NAT

> 🏷 **状态（2026-11-25 复核）**：✅ 现机就在这套配置上跑 —— `eth0.100`（WAN）+ `eth0.200`（LAN）
> 两条 VLAN 走同一条 vNTB，`br-wan` / `br-lan` 在交换芯片上是两个真的广播域。
> ⚠️ 面板 `2/WAN` 目前没插线，所以 `br-wan` 退到 IPv4LL `169.254.38.2`、两台都没有默认路由。
> 🚫 这套网络**不能当正式路由器用**：LAN 段没有 DHCP 服务、没有防火墙策略，只有 NAT（§10.5）。

**一句话**：x86 自己没有网口，它靠 vNTB 借 NPU 的面板口上网；一条 PCIe 链路要同时装下
"上游 WAN"和"下游 LAN"，所以用两条 802.1Q VLAN 把它们分开。

```
        x86                                    NPU
  eth0.100 ─ DHCP ◄────────────┐    ┌─ br-wan ─ eth0.100 + p2 ──► 上游 / WAN / 管理
                               │    │
  eth0  ═══════════════════════╪════╪══════════════════════════ eth0   (无地址，必须 up)
                               │    │
  eth0.200 ─ 10.234.56.2/24 ───┘    └─ br-lan ─ eth0.200 + p1 ──► 下游设备（10.234.56.1）
```

链路的建立、排障和自愈在 [09](09-vntb.md)；两台机器各自的系统在 [06](06-x86-system.md) /
[07](07-npu-system.md)。

## 8.1 当前网络


| 位置 | 地址 | 说明 |
|---|---|---|
| NPU | `br-wan` 上的 DHCP 租约 | 面板 `2/WAN` 插上游才拿到；管理走这条地址 |
| x86 | `eth0.100` 的 DHCP 租约（MAC `02:58:47:53:00:11`） | 同一段上游，默认路由从这里来 |
| x86 ↔ NPU（LAN） | `10.234.56.2` ↔ `10.234.56.1` | VLAN 200 走 vNTB |
| 面板 1/LAN | `br-lan` 静态 `10.234.56.1/24` | 插笔记本（自己配 `10.234.56.x`）可同时访问 `.1` / `.2` |

## 8.2 为什么必须用 VLAN

x86 和 NPU 之间**只有** PCIe vNTB 这一个 netdev（`eth0` / `pci-vntb 0001:10:00.0`）。
一个 netdev 只能属于一个桥，所以「WAN」和「LAN」必须靠 802.1Q 分开：

```
        x86                                    NPU
  eth0.100 ─ DHCP ◄────────────┐    ┌─ br-wan ─ eth0.100 + p2 ──► 上游 / WAN / 管理
                               │    │
  eth0  ═══════════════════════╪════╪══════════════════════════ eth0   (无地址)
                               │    │
  eth0.200 ─ 10.234.56.2/24 ───┘    └─ br-lan ─ eth0.200 + p1 ──► 下游设备（10.234.56.1）
```

| 段 | VLAN | NPU 侧 | x86 侧 | 谁能访问 |
|---|---|---|---|---|
| WAN / 管理 | 100 | `br-wan` = `p2` + `eth0.100`，**DHCP**（自己拿上游地址） | `eth0.100`，systemd-networkd DHCP，默认路由也从这里来 | 插上面板 `2/WAN` 的上游 → NPU 和 x86 各拿一个租约 |
| LAN | 200 | `br-lan` = `p1` + `eth0.200`，**静态 `10.234.56.1/24`，不跑 DHCP 服务** | `eth0.200` 静态 `10.234.56.2/24` | 面板 `1/LAN` 插笔记本（自己配 `10.234.56.x`）→ `.1` / `.2` |

`p3` / `p4` 现在**不并入任何桥**（原来 `p4` 走家里内网，退掉了）。这台机器的面板只引出
`p1`–`p4` + `sfp`，`p5`–`p8` 虽然 DSA 会建出 netdev，但面板上没有座，别往桥里加。
想让别的面板口也能当调试口，把它加到 `net.conf` 的 `LAN_PORTS` 就行。

交换机上两段用**不同的硬件 VLAN**：`br-wan` 用 VLAN 100，`br-lan` 用 VLAN 200
（`vlan_filtering 1` + `vlan_default_pvid 0`，桥自己的端口也要 `self` 加进去）。
两个桥都用默认 VLAN 1 的话，交换芯片里的广播域其实是同一个 —— 面板上的 WAN 和 LAN 会互通。

## 8.3 哪个口是 LAN / 哪个是 WAN

面板丝印和 DSA 端口号的对应：`1/LAN` = `p1`，**`2/WAN` = `p2`**，3 = `p3`，4 = `p4`，SFP = `sfp`。

全部由 `/etc/xgs87/net.conf` 决定（NPU 侧读它，`xgs-net-up.sh` 用 `.` 加载，所以是 shell 语法）：

| 桥 | 默认端口 | VLAN | 默认模式 | 说明 |
|---|---|---|---|---|
| `br-wan` | `p2`（面板 `2/WAN`） | 100 | `dhcp` | 上游；自己拿租约，管理也走这条 |
| `br-lan` | `p1`（面板 `1/LAN`） | 200 | `static` | `10.234.56.1/24`，**不跑 DHCP 服务** |

```sh
# /etc/xgs87/net.conf  —— 取默认值就不用动这个文件
WAN_PORTS="p2"   WAN_MODE="dhcp"    WAN_VID="100"   # static 时配 WAN_ADDR="203.0.113.2/24"
LAN_PORTS="p1"   LAN_MODE="static"  LAN_VID="200"   # LAN_ADDR="10.234.56.1/24"
```

改完 `sudo systemctl restart xgs-net-up xgs-dhcp` 就生效，不用重启。

x86 那一端（`systemd/x86/`）跟着这两条 VLAN 走：`100-wan.network` 在 `eth0.100` 上 DHCP，
`200-lan.network` 在 `eth0.200` 上给静态 `10.234.56.2/24`。

## 8.3.1 LAN 出去要靠 NAT（`xgs-nat.service`）

LAN 段是独立的 `10.234.56.0/24`，上游只认识 `br-wan` 那个 DHCP 地址，所以 LAN 下面的设备
想上网必须做转发 + 源地址伪装：

```
net.ipv4.ip_forward = 1                       # /etc/sysctl.d/60-xgs87-nat.conf
nft add table inet xgs87                      # xgs-nat.sh 建，重复执行就是重建
  chain forward   : br-lan → br-wan accept；br-wan → br-lan 只放 established/related；其余 drop
  chain postrouting: oifname br-wan, ip saddr 10.234.56.0/24 masquerade
```

- 规则全在自己的 `inet xgs87` 表里：`systemctl disable --now xgs-nat && nft delete table inet xgs87`
  就完全回退，不留后遗症。
- 子网的 `10.234.56.0/24` 从 `net.conf` 的 `LAN_ADDR` 推出来，改地址不用改规则。
- **没开 IPv6 转发**：上游目前只发 IPv4 租约，开了也只是徒增暴露面。
- 也没装 DNS 服务：LAN 上的客户端 DNS 要么指上游，要么指公共解析器。

> ⚠️ 这条 NAT 只是"让 LAN 能出去"，没做任何限速/访问控制；要当正式路由用还缺 DHCP 服务
> 和防火墙策略（见 §16.6）。

> ⚠️ 下游设备要自己配 `10.234.56.x/24`，网关 `10.234.56.1`：这里的 LAN 没有 DHCP 服务，
> 插上去不会自动拿到地址。

> ⚠️ 同一个桥里的端口共用一个广播域 —— 以后往 `LAN_PORTS` 里加口，别把它们接到同一台交换机上。

## 8.4 踩到的坑：父设备必须 up

第一版脚本只 `ip link set eth0.100 up`，忘了 `ip link set eth0 up`。结果 VLAN 设备全部
停在 `LOWERLAYERDOWN`，桥和它上面的地址跟着 down：

```
eth0             DOWN
eth0.200@eth0    LOWERLAYERDOWN 10.234.56.2/24
```

VLAN 设备的 carrier 来自父设备，**父设备没有地址也必须 up**。三个脚本现在都显式做了：

| 文件 | 位置 |
|---|---|
| `systemd/npu/xgs-net-up.sh` | `ip link set "$NTB" up`（清地址之后） |
| `systemd/npu/xgs-net-up.sh` | `ip link set "$NTB" up` |
| `systemd/x86/xgs-ntb-up.sh` | `ip addr flush dev eth0` 之后 `ip link set eth0 up` |

## 8.5 这套网络没做什么

| 没做 | 后果 / 什么时候需要 |
|---|---|
| LAN 段没有 DHCP 服务 | 插到 `1/LAN` 的设备要**自己配** `10.234.56.x/24`、网关 `10.234.56.1`。要发给下游就装 `dnsmasq`/`kea` 并加一个 unit |
| 没有防火墙策略 | `xgs-nat.sh` 只放 `br-lan → br-wan` 出去、`br-wan → br-lan` 只回 established；没有按端口/地址的限制，也没有限速 |
| 没开 IPv6 转发 | 上游目前只发 IPv4 租约；开了只是增加暴露面 |
| 没装 DNS 服务 | LAN 客户端 DNS 指上游或公共解析器（NPU 上 `resolv.conf.head` 写的是 `1.1.1.1` / `8.8.8.8`） |
| 面板 `p3`/`p4` 不并入任何桥 | 想加就写进 `/etc/xgs87/net.conf` 的 `LAN_PORTS`/`WAN_PORTS`，然后 restart 两个 unit |

> ⚠️ 同一个桥里的端口共用一个广播域 —— 往 `LAN_PORTS` 里加口时别把两台接到同一台交换机上。
