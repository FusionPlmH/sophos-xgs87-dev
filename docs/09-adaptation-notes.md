# 09 · 改造笔记：要做什么、缺什么

目标：把 XGS 87 变成能自由跑的机器。两条路线：

- **A. NPU 跑 OpenWrt 当路由**（推荐，和两个参考项目一致）
- **B. 保留原厂 NPU 固件，x86 换成自己的系统**（最省事，但网络还是原厂那套）

## 9.1 现状盘点

| 能力 | 状态 | 说明 |
|---|---|---|
| 串口控制台 | ✅ | 两个系统都能进 |
| NPU root shell | ✅ | 已设密码（原厂为空密码） |
| SFP 口 10 Gbps | ✅ 链路 / ⛔ 转发 | 10GBASE-SR 实测量到 10 Gbps UP；转发需 DSA 驱动 |
| 整机存储备份 | ✅ | eMMC 7.28 GiB + mtd0/1，SHA256 校验通过 |
| 交换机初始化 | ✅ | 原厂 `sw_init_2` 序列（U-Boot env）已完整复现，见 [12.12](12-measurements.md#1212) |
| NPU 网络（eth0） | ✅ | CPU 口 10 Gbps，配好 IP 就能用（ping/SSH/93 MB/s 实测） |
| SFP 口 10 Gbps 链路 | ✅ | 10GBASE-SR 模块实测 `Link: UP, Speed: 10 Gbps`，见 [12.11](12-measurements.md#1211) |
| SFP 口 10 Gbps 转发 | ❌ | 需 mainline `mv88e6xxx` DSA 驱动（厂商 4.14 内核无交换机驱动） |
| 完整存储备份 | ✅ | eMMC 7.28 GiB 整盘 + boot0/1 + mtd0/1，SHA256 全部校验通过 |
| PCIe 链路 | ✅ | 端点一直在线 |
| x86 网络 | ❌ | 需要 NTB 或网关方案 |
| 交换机 mainline 驱动 | ❌ | 内核无 DSA/mv88e6xxx |
| NTB 支持 | ❌ | 原厂内核无 CONFIG_NTB |
| NPU 复位控制（从 x86） | ❓ | 路径未确认 |
| MCP2210 驱动 | ❌ | 未写 |

## 9.2 路线 A：NPU 跑 OpenWrt

### 内核 / DT

本机内核 config 可以直接对比：

```
CONFIG_MVPP2=y            ← eth0 有
CONFIG_MVPP2X=m           ← 多口驱动（模块）
CONFIG_MV88E6XXX 缺失     ← 必须加
CONFIG_NET_DSA 缺失
CONFIG_NTB 缺失
```

需要：

1. **`CONFIG_NET_DSA` + `CONFIG_MV88E6XXX`**（或者 Marvell 的 out-of-tree mvsw）。
2. DT 里把 `switch@2` 换成标准 DSA：

   ```dts
   mdio {
       switch0: switch@2 {
           compatible = "marvell,mv88e6193x";   // 或 6393x，视 mainline 支持
           reg = <2>;
           ports {
               port@0 { reg = <0>; label = "cpu"; ethernet = <&eth0>; phy-mode = "10gbase-r"; };
               port@1 { reg = <1>; label = "lan1"; phy-handle = <&phy1>; };
               port@2 { reg = <2>; label = "lan2"; };
               port@3 { reg = <3>; label = "lan3"; };
               port@4 { reg = <4>; label = "lan4"; };
               port@9 { reg = <9>; label = "sfp"; phy-mode = "1000base-x"; };
           };
       };
   };
   ```

   > mainline 里 88E6193X 属于 6393X 家族，可能要用 `marvell,mv88e6393x` 的 ID 表；
   > 需要试。

3. **U-Boot**：可以直接用原厂的（它是 2019.10，能 `ext4load` + `booti`，够用）。
   只要改 `bootcmd` 指向 OpenWrt 槽位。也可以在 U-Boot 里用 `sw_init` 先把交换机点亮，
   Linux 起来后 DSA 重新初始化。

### 端口 / LED / SFP

- LED 走 PCA9555（i2c-0 0x20，`gpio-leds` + `netdev` trigger）。
- SFP：`i2c-1` 0x50/0x51 + `gpio:1:1/2/3/7`。
- MAC：VPD 基址 + 7。

### 装到哪里

- p1（500 MB）最合适；p2/p3 保留原厂。
- 如果要做 A/B 升级，可以 p1/p2 轮换。

## 9.3 路线 B：只换 x86

- 保持 NPU 原厂固件（它有 `mvmgmt0` + 数据面）。
- x86 装 Debian/OpenWrt，通过 **NTB** 或 **把 NPU 当网关** 上网。
- 优点：风险最低，随时能回退。
- 缺点：还是被 Sophos 的 NPU 固件绑着，没有交换机的控制权。

## 9.4 路线 C：x86 当应用服务器，NPU 当路由（两者都换系统）

这是我们认为最实用的组合，见 [10-ideas.md](10-ideas.md)。

## 9.5 已知缺口 / 需要做的事

### 高优先级

- [ ] **确认 88E6193X 在 mainline `mv88e6xxx` 的支持**（读 datasheet / 试 6393X ID）
- [ ] **写 OpenWrt 的 DTS**（基于 `reference/npu-device-tree.dts`）
- [ ] **编译带 DSA 的内核**，验证 4 个口 + SFP
- [ ] **NPU 复位控制**：从 x86 能不能复位 NPU？找 CPLD/GPIO（原厂 x86 驱动里应该有）
- [ ] **NTB 三件套**：1 MiB BAR 对齐、去 `dma-coherent`、MSI 优先

### 中优先级

- [ ] SFP 口速率上限（**已测得当前是 1000BASE-X**，2.5G/10G 需模块才能测）
- [ ] LED：**已证伪**"PCA9555 驱动面板灯"（rev 07 实测无影响），需要重新测绘
      或用 PHY 自带 LED 控制
- [ ] MCP2210 读写 SPI NOR 的工具（救砖用）
- [ ] `dev_write … 4 f002/2000` 的字段含义（已确认是 SerDes/PCS 块，细节需 datasheet）

### 低优先级

- [ ] 端口 5-8 在本机型是否引出（PHY 存在，面板只有 4 座；需看 PCB）
- [ ] 温度/功耗监控（NPU thermal zone、x86 k10temp）
- [ ] x86 的 i2c-dev / gpio 暴露

> 本轮实测的完整数据见 [12-measurements.md](12-measurements.md)。

## 9.6 和参考项目的差异对照

| 项目 | 参考项目做法 | 本机需要改的 |
|---|---|---|
| x86 系统盘 | 64 GB SATA + MBR | **16 GB eMMC + GPT/EFI**（`x86-mbr.py` 不适用） |
| 面板口数量 | 8 + SFP | **4 + SFP**（DTS 要删 port 5-8） |
| Wi-Fi | QCA988x | 无（不用配 ath10k） |
| partno | AMDA0200-0004 | **AMDA0200-0001**（platform 文件不同） |
| 交换机 | 同款 88E6193X | 相同，可直接复用其 DT 片段 |

## 9.7 风险控制

1. **先备份 SPI NOR**（U-Boot 是唯一的启动路径）。
2. 改 `bootcmd` 前先确认另一个槽能启动。
3. 串口永远留着，别把 console 关了。
4. 每次改固件都记录 `md5sum`。
