# 17 x86 与 NPU 共享一个管理口（p8）—— **已退役，历史档案**

> 🏷 **状态（2026-11-25 复核）**：⚠️ **已退役，当前系统里不存在这套配置**。下面记录的是把
> p8 做成共享管理口那一版（`br-mgmt` + `192.168.100.0/24`）；2026-11-24 之后管理并进了
> WAN（`br-wan`，VLAN 100，DHCP），面板 `1/LAN` 是独立的静态 LAN 段（`10.234.56.0/24`），
> `br-mgmt` 已经删掉。**而且本机 XGS 87 的面板只引出 p1–p4 + sfp，p5–p8 根本没接线**
> （docs/06），所以 p8 这个方案在这台机器上无法复现。
> 留在文档里只是因为硬件事实和踩过的坑仍然有效：PCIe 链路、四个真实 bug 的修法、
> x86 侧模块构建。现在的网络形态看 [20](20-lan-over-vntb.md)，安装步骤看 [21](21-reproduce.md)。

目标：前面板 **p8** 同时作为 NPU（Debian）和 x86（Debian）的管理口——两台机器在同一个二层、
各拿一个地址，机箱上只占一个口。

> **本文是方案推演 + 实施结果**：17.1–17.5 是当时的计划（保留下来是因为里面有硬件事实），
> 17.6 是实际跑通后的结论。现在的网络形态与安装步骤请直接看
> [20](20-lan-over-vntb.md) 和 [systemd/README.md](../systemd/README.md)。

---

## 17.1 现状（2026-11-23 实测）

| 项 | 事实 |
|---|---|
| 本机运行的 DT | **没有任何 PCIe 节点**——NPU 侧 Linux 完全没碰 PCIe（`lspci` 空、`/proc/iomem` 无 pci 段） |
| 原厂 DT | `pcie-ep@600000`：`marvell,armada-pcie-ep` + `snps,dw-pcie`，`reg-names="core","lm","shadow_core"`，`status="okay"`；同地址的 RC 节点是 `disabled` → **NPU = Endpoint，x86 = Root Complex** |
| 原厂另有 `pci-ep-uio` 节点 | `bar0` / `bar2` / `bar4` / `host-map` → Sophos 走的是 **UIO + MUSDK**，不是 NTB |
| **x86 侧已经看得到 NPU** | `03:00.0 [11ab:7080]`，BAR0 = **1 MiB**、BAR2 = 16 MiB、BAR4 = 16 MiB，Gen3 **x2**（cap 为 x4），有 MSI + MSI-X(16)，`NoSnoop+` → **链路和 iATU 是 U-Boot/ATF 配好的，Linux 不碰也在** |
| x86 硬件 | AMD Embedded R-Series **RX-216TD**，Debian **6.12.94+deb13-amd64**，自带 14.7 GB eMMC（UEFI 启动，AMI BIOS 1906） |
| NPU 内核配置 | `CONFIG_PCI_ENDPOINT=y`，但 `PCI_ENDPOINT_CONFIGFS` / `CONFIG_NTB` / `PCI_EPF_NTB` 全是 **not set** |
| 主线支持 | 有 `pcie-designware-ep.c` 框架和 `pci-layerscape-ep.c` 等胶水，**没有** `marvell,armada-pcie-ep`；通用 EP 可走 `pcie-designware-plat.c`（`snps,dw-pcie-ep`） |
| 现用地址 | NPU `192.168.100.1/24`（`br-mgmt`）、x86 `192.168.100.2/24`；p1/p4/sfp 有载波，p2/p3/p5–p8 都是 admin-up 但 NO-CARRIER。**p1 上原来那个 `192.168.1.1/24` 已经清掉**（早期手测遗留） |

结论：**数据通路必须自己建**。x86 没有独立网口，NTB 是唯一开源可行方式。

---

## 17.2 阶段 1：p8 先当 NPU 的管理口（不动内核，零风险）

p8 在 DSA 起来后是 `LOWERLAYERDOWN`（admin up、无载波），说明 `xgs-ports-up.service`
已经把它拉起来了，只差一个二层归属和 IP。

下面的 networkd 写法是当时的计划；**实际落地用的是脚本**
（当时的 `systemd/npu/xgs-mgmt-bridge.sh`，已删除），
因为它还要顺手处理 vNTB 的 VLAN 和 `br-mgmt` 的 MAC 继承：

```ini
# /etc/systemd/network/10-br-mgmt.netdev
[NetDev]
Name=br-mgmt
Kind=bridge

# /etc/systemd/network/10-br-mgmt.network
[Match]
Name=br-mgmt
[Network]
Address=192.168.100.1/24

# /etc/systemd/network/20-p8.network
[Match]
Name=p8
[Network]
Bridge=br-mgmt
```

注意事项：

- **不要把 `end0` 放进桥**：`end0` 是 DSA 的 conduit，桥接它等于绕开硬件转发。
- **不要一开始就把 p1 也放进 `br-mgmt`**：那会把 p1 和 p8 变成一台交换机。
  拿根网线插 p8、`ssh 192.168.100.1` 验证通过后，再决定是否并更多口。
- `p8` 必须在 DSA 端口就绪后才存在，networkd 会自动重试；用脚本时是显式等 60 s。
- 没有 DHCP 服务器时用静态地址（现在就是）；有上游 DHCP 就把 `Address=` 换成 `DHCP=yes`。

> 那块 `192.168.1.1/24` 曾经挂在 p1 上（早期手测），**已经清掉**。

---

## 17.3 阶段 2：NTB 链路（当时以为要重编两个内核，实际只装模块）

物理速率：Gen3 x2 ≈ 2.0 GB/s 理论；参考 xgs107 的实测 0.63 / 1.7 Gbps（受 `transport_mtu` 影响），
做管理口绰绰有余。

### NPU 侧（自编内核 + DT）

```
CONFIG_PCI_ENDPOINT=y
CONFIG_PCI_ENDPOINT_CONFIGFS=y
CONFIG_PCI_EPF_NTB=m
CONFIG_NTB=m
CONFIG_NTB_TRANSPORT=m
CONFIG_NTB_NETDEV=m
CONFIG_PCIE_DW=y
CONFIG_PCIE_DW_EP=y
CONFIG_PCI_DW_PLAT=y
```

DT 草案（把原厂的 reg 换成 `dw-pcie-ep` 绑定的名字，**顺序和用途待实测确认**）：

```dts
pcie_ep0: pcie-ep@600000 {
	compatible = "snps,dw-pcie-ep";
	reg = <0x0 0xf2600000 0x0 0x4000>,	/* dbi        ← 原厂 "core"        */
	      <0x0 0xf2604000 0x0 0x1000>,	/* atu        ← 原厂 "shadow_core" */
	      <0x0 0xf2608000 0x0 0x80000>;	/* addr_space ← 原厂 "lm"          */
	reg-names = "dbi", "atu", "addr_space";
	num-lanes = <2>;
	status = "okay";
};
```

三个已知坑（来自 openwrt-sophos-xgs107 的实践）：

1. **BAR 必须 1 MiB 对齐**：这颗 iATU 忽略目标地址低 20 位 → 补丁 `951-PCI-dwc-plat-ep-1M-BAR-align.patch`
2. **不能写 `dma-coherent`**：本机 `NoSnoop+`，EP 不 snoop CPU cache，写了会读到脏数据
3. **用 MSI，不要 MSI-X**：DesignWare 报 MSI-X 但实际只发 MSI，否则 x86 IOMMU 报 `IO_PAGE_FAULT`

加载时给 `ntb_transport` 传 `transport_mtu=2048`（默认 64 KiB 帧会让 1 MiB 窗口只剩 15 个槽）。

### x86 侧（Debian 6.12.94，装模块即可）

```
CONFIG_NTB=m
CONFIG_NTB_TRANSPORT=m
CONFIG_NTB_NETDEV=m
CONFIG_NTB_HW_EPF=m
```

外加 `953-ntb-hw-epf-prefer-msi.patch`。

### 合流

NPU 把 `ntb0` 加进 `br-mgmt`，x86 在 `ntb0` 上静态地址（如 `192.168.100.2/24`）或 DHCP →
**两台机器就在 p8 这同一个二层里**。

---

## 17.4 前置条件与风险

- **x86 目前的可控通道**：它没有网口（`x86-info.txt` 是本地采集的）。改内核前必须先能登进去：
  显示器 + USB 键盘，或者 BIOS 的 Console Redirection 引到串口。
- **EP 的 BAR 现在是固件配的**：改成 NTB 后要由 Linux EP 驱动重配 iATU；如果 U-Boot 有锁定或 ATF 干预，需要实测。
- **回退**：全程不碰 eMMC 上的原厂分区（NPU 的 `mmcblk0-full.img` 已备份），DTB / 内核都可回退。

---

## 17.5 如果只是想把 x86 管起来（不做 NTB）

- **USB 网卡**：x86 有 XHCI，前面板 USB 插个 USB-Ethernet 就有独立管理口——不占交换机口、不改内核。
  `x86-info.txt` 里已经有 `MCP2210 USB-SPI` 在用，说明这条路径是通的。
- **串口**：AMI BIOS 1906 支持 Console Redirection，可把 x86 控制台引到 COM。

---

## 17.6 结果：已打通（2026-11-23）

```
x86 : eth0 UP 192.168.100.2/24   carrier=1
NPU : br-mgmt 192.168.100.1/24   (p8 + eth0 同在桥里)
ping 192.168.100.1 -> 0% loss, rtt 1.7-11 ms
```

两侧都是 oneshot systemd 服务，重启自动恢复：
`xgs-vntb.service`（NPU，见 [xgs-vntb.sh](../systemd/npu/xgs-vntb.sh)）、`xgs-ntb.service`（x86，见 [xgs-ntb-up.sh](../systemd/x86/xgs-ntb-up.sh)）。

### 真正踩到的四个坑（按发现顺序）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | configfs 里 `controllers/` 和 `functions/` 都是空的 | Debian 内核 `CONFIG_PCI_ENDPOINT=y` 但 **`PCI_ENDPOINT_CONFIGFS=n`**，`pci-epc-core`/`pci-epf-core` 里的 cfs 钩子被编成空函数 | 我们自己的 `pcie_dw_plat.ko` 和 `pci_epf_vntb.ko` 在初始化时**自己调** `pci_ep_cfs_add_epc_group()` / `pci_ep_cfs_add_epf_group()`，两个文件都要 `-DCONFIG_PCI_ENDPOINT_CONFIGFS=1` 才能拿到真原型 |
| 2 | 端点 `ctrl=BAR0, db=BAR1, mw=BAR2`，主机按 `ctrl=0, db=2, mw=4` 找 | 这颗 PCIe EP **只实现偶数 BAR**（1/3/5 读回全 0，写了也被丢弃），而 `pci_epc_get_next_free_bar()` 是按 0,1,2 顺序发号 | `pci_epc_features.bar[1/3/5].type = BAR_RESERVED` |
| 3 | 两侧都在 peer spad 读写时 oops（x86: `…d00210`，NPU: `0x83601028` 越过 DRAM 末端） | `.align = SZ_1M` 让 vNTB 把 **`ctrl_size` 也 ALIGN 到 1 MiB**，`spad_offset` 变成 1 MiB，布局 2 MiB 而 BAR 只有 1 MiB | **align 只约束"缓冲区放哪"，不约束内部布局**：`ctrl_size`/`spad_size` 用 `roundup_pow_of_two()`，对齐交给 `pci_epf_alloc_space()` |
| 4 | 主机 MSI-X 空向量表 → `IO_PAGE_FAULT address=0x0` | DW 核宣称 MSI-X 但只发 MSI | 端点 `.msix_capable = false`；主机 `ntb_hw_epf` 改为先申请 MSI |

另外两个操作层面的坑：

- 端点改写 header 后，**主机必须 `remove` + `rescan`**，只 `rescan` 不会重读已存在设备的 ID（`/sys/.../vendor` 是枚举时缓存的）。
- 主机模块必须用**与内核同版本**的源码编（6.12.94），用 6.12.117 的源码会引用 `.94` 还没有的 `ntb_get_dma_dev`。

### 还留下的问题

- **RTT 偏高（1.7–11 ms）**：`pci-epf-vntb` 靠轮询控制区收主机门铃，`msecs_to_jiffies(1)` 在 HZ=250 下是 4 ms。
  要更快得改成高精度定时器或让内核 HZ=1000。
- 单次吞吐未测（x86 上没有 iperf3）；xgs107 参考值是 630 Mbit/s / 1.7 Gbit/s。
- **软重启仍然会卡在 shutdown**（`br-mgmt` + DSA 摘端口的嫌疑最大），目前只能断电。这跟 NTB 无关，单独处理。

