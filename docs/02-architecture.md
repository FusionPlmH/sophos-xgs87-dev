# 02 · 架构设计

> 🏷 **状态（2026-11-23 复核）**：✅ **架构已复核**。已推翻两条旧结论：①NTB 不需要换内核（外挂模块即可）②交换芯片**有** mainline 驱动（DSA 已跑起 9 个 netdev，本机面板只用 p1–p4 + sfp）。SFP 实测 10G。

## 2.1 为什么是两颗芯片

原厂（Sophos SFOS）把功能切成两层：

| | x86（AMD RX-216TD） | NPU（CN9130） |
|---|---|---|
| 角色 | 控制面 + 应用 | 数据面 |
| 跑什么 | SFOS 主系统、Web 管理、Wi-Fi 驱动、日志、DPI 管理 | **原厂**：极小的 Buildroot，只做包收发和交换机管理<br>**现在**：Debian 13（见 [07](07-npu-system.md)） |
| 网络 | **没有自己的网口** | 4×1G + 1×SFP，全部挂在 88E6193X 上 |
| 与对方 | PCIe 端点 + 串口 | PCIe 端点 + 串口 |

这种"双 SoC + PCIe"做法在高端防火墙里常见：x86 便宜、生态好；NPU 有 10G MAC、
硬件交换、硬件加速，而且转发路径不经过 x86 的通用内核。

## 2.2 通路一：PCIe 端点（原厂方案）

```
x86 内核                                    NPU 内核
┌───────────────┐                          ┌──────────────────────┐
│ mv_pcinet_drv │◄── BAR0/BAR2/BAR4 ──────►│ mv_armada_ep         │
│ mv_nwa_host   │      doorbell/queue      │ mv_pcinet_trgt       │
│ mv_pport      │                          │ mv_nwa_target        │
│ mvmmgmt0      │                          │ mvmgmt0              │
└───────────────┘                          └──────────────────────┘
        │                                            │
   虚拟 netdev Port1..Port8                   交换机 88E6193X
```

- x86 上会出现 `Port1…Port8` 和 `PortF1`，下面是一个多路复用 netdev `mv-pcimux0`，
  外加一条管理链路 `mvmgmt0`。
- NPU 侧对应模块：`mv_nwa_target`, `mv_pcinet_trgt`, `mv_armada_ep`,
  `mv_facility_trgt_dma`, `mv_dmax2_uio`, `musdk_cma`, `mvmdio_uio`（实测 `lsmod`）。
- 这些**都是 Sophos 专有驱动**，只支持 4.14 内核，Debian 用不了。

## 2.3 通路二：NTB（开源方案，推荐）

参考项目 [openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)
用 mainline 的 NTB 在两端建了一条普通以太网：

```
NPU (endpoint)                             x86 (host)
pci-epf-vntb  ── BAR0=control ───────────► ntb_hw_epf
              ── BAR2=doorbell ──────────► ntb_transport
              ── BAR4=memory(1 MiB) ─────► ntb_netdev  → ntb0
```

性能：**本机实测单流 TCP 1.20 Gbit/s、ping RTT 0.6 ms**（改 hrtimer 轮询后，见 [09](09-vntb.md) §9.1）。
参考项目自报的数字是 630 Mbit/s / 1.7 Gbit/s，与本机不同批次测法，不直接可比。

### 三个必须注意的坑

1. **BAR 必须 1 MiB 对齐**：这颗 iATU 忽略目标地址低 20 位。
2. **不能写 `dma-coherent`**：PCIe master 不 snoop CPU cache，会读到脏数据；去掉后走 uncached。
3. **用 MSI，不要 MSI-X**：DesignWare 报 MSI-X 但实际只发 MSI，否则 x86 IOMMU 报 `IO_PAGE_FAULT`。

另外要 `transport_mtu=2048`（默认 64 KiB 帧会让 1 MiB 窗口只有 15 个槽）。

> **更正（2026-11-23）**：本机 Debian 内核确实没有 NTB（`CONFIG_NTB` 未编），但**不需要换内核** ——
> 这套 NTB 全是**外挂模块**（`ntb_core` / `ntb_transport` / `ntb_netdev` / `pci_epf_vntb` / `pcie_dw_plat`），
> 对着现成 headers 编出来 `insmod` 就能跑。构建见 [tools/](../tools/)，四个真实 bug 见 [档案](archive/p8-shared-mgmt.md) §17.6。

## 2.4 通路三：串口（永远可用）

x86 `/dev/ttyS2` ↔ NPU `ttyS0`，线上 115200 8N1。当前 Debian 的 host 侧也设 115200；
只有老 `image/` 内核是 2x 分频，才需要 host 57600（见 [10](10-console.md) §10.3）。

- 用途：救砖、看 boot log、进 U-Boot、在 NPU 没网时下命令。
- 带宽：~11.5 KB/s，只适合控制，不适合传数据。
- 复用了这个通道就等于拿到"带外管理"：x86 可以当 NPU 的 BMC。

## 2.5 交换机数据面

```
  面板 RJ45×4 ── 内置 PHY ─┐
                            ├── 88E6193X ── port0 ── 10GBase-KR ── CN9130 mvpp2 (eth0)
  SFP F1 ── 10GBASE-R ─────┘                     (Comphy lane 4, SFI0)  ← 实测 10G
```

- **转发不经过任何 CPU**：面板口之间由交换芯片硬件转发。
- CPU 口只处理上联流量（路由/防火墙/管理）。
- 原厂 x86 看到的那些口是 NPU 通过 PCIe 转发的"虚拟端口"；真正做交换的是 88E6193X。
- 10G 的 CPU 链路意味着 x86↔NPU 的瓶颈在 PCIe（Gen3 ×2 ≈ 2 GB/s 理论）而不是网络。

## 2.6 启动与复位时序

```
上电
 ├─ x86:  AMI UEFI → shim → grub → Debian
 └─ NPU:  BootROM 2.03 → CP-0 IOROM 1.07
          ├─ mv_ddr 初始化（2 GiB）
          ├─ TF-A BL1/BL2/BL31（Marvell 10.22.06）
          │    └─ Comphy: lane0/1 = PCIe(EP), lane4 = SFI0 10G
          ├─ U-Boot 2019.10（SPI NOR）
          │    └─ 读 env，autoboot 3 s
          └─ bootcmd: ext4load mmc 0:2 /boot/Image + dtb + initrd → booti
               （2026-11-25 实测：p2 正常启动，`bootcmd=run bootcmd_deb10g`）
               └─ 原厂：Linux 4.14.207 → /etc/init.d/S91xgsstartup
                  现在：Debian 13 / 6.12.117 → systemd（xgs-ports-up → xgs-vntb → …）
```

两边的启动是**各自独立**的：NPU 上电就自己跑，不需要 x86 做任何事。

> 注意：PCIe 端点在 U-Boot 阶段就配置成 endpoint 并发起 link，所以 x86 永远能在
> `lspci` 里看到 `03:00.0`，即使 NPU 的 Linux 没起来。

## 2.7 电源与散热

- 单路 DC 输入（整机一颗电源，**x86 和 NPU 共用**，所以断电两台一起下）。
- 空闲温度：x86 `k10temp` 约 40-50 ℃，NPU 6 个 thermal zone 约 49-55 ℃（不同时段/负载）。
- 满负载（4 核 A72 + 交换）预计 60-70 ℃，可接受。

## 2.8 关键设计约束（做方案时先看这里）

1. **x86 没有网口**，要联网必须经过 NPU —— 要么 NTB/PCIe 隧道，要么把 NPU 当网关。
2. **面板口只能由 NPU 驱动**，x86 无法直接收发包（除非 NTB 转发）。
3. ~~交换芯片没有 mainline 驱动~~ **已解决**：Debian 自带 `mv88e6xxx` + DSA，9 个 netdev（p1–p8 + sfp）
   全部出现；本机面板只引出了 p1–p4 + sfp，面板口之间由硬件转发。TCAM 越权补丁要自己编，
   见 [15](15-modules-and-kernel.md) §15.5。
4. **x86 只有 2 核 4 GB**，适合轻量服务，不适合重计算。
5. **串口是唯一可靠的带外通道**，设计升级/回滚流程时一定要留着它。
