# 06 · 交换机与端口

## 6.1 芯片

```
Marvell>> mvswitch 2 info
Switch    : SOHO
Series    : Amethyst
Product # : 193          → 88E6193X
Revision  : 0
```

| 项目 | 值 |
|---|---|
| 型号 | **88E6193X**（SOHO/Amethyst 系列） |
| MDIO | `mdio@12a200`（`marvell,orion-mdio`），地址 **2** |
| 端口数 | 11（port 0-10），本机用 0、1-4、9 |
| 内置 PHY | port 1-8 各一个（MVL6193），本机只用到 1-4 |
| CPU 口 | port 0 ← 10GBase-KR → CN9130 `mvpp2` eth0 |
| SFP | port 9 |

设备树节点（`reference/npu-device-tree.dts`）：

```dts
mdio@12a200 {
    compatible = "marvell,orion-mdio";
    reg = <0x12a200 0x10>;
    switch@2 {
        compatible = "marvell,mv88e6xxx";
        cpu-port  = <0>;        // CPU 口是 port 0
        phy-addr  = <2>;        // MDIO 地址
        port-mask = <0x7ff>;    // 11 个口
        status    = "okay";
    };
};
```

> **内核里没有 mv88e6xxx 驱动**（`kallsyms` 无符号、`/lib/modules` 无模块、
> config 里也没有 `CONFIG_MV88E6XXX`）。所以这个节点只是个"占位"，
> 交换机实际由 U-Boot `mvswitch` + 用户态 CPSS 控制。

## 6.2 端口映射

来自 `/opt/sophos/plt/AMDA0200-0001R00.txt`（原厂机型定义，实测一致）：

| 面板 | 交换机口 | 类型 | Linux 网卡（原厂） | init_speed | PHY LED ctl |
|---|---|---|---|---|---|
| 1 / LAN | 1 | RJ45 内置 PHY | eth0 | 1G | 0xe3 |
| 2 / WAN | 2 | RJ45 | eth1 | 1G | 0xe3 |
| 3 / DMZ | 3 | RJ45 | eth2 | 1G | 0xe3 |
| 4 | 4 | RJ45 | eth3 | 1G | 0xe3 |
| F1 | 9 | SFP (SFF-8431) | eth4 | 1G | 0xe1 |
| CPU | 0 | 10GBase-KR | bp0 port0 | 10G | — |

背板定义：`npu0.bp0.port0=0:0`（CN9130）、`npu0.bp0.port1=1:0`（交换机 port 0）。

### 指示灯（PCA9555 @ i2c-0 0x20）

| 面板 | green（速率） | amber（link/act 推测） |
|---|---|---|
| 1 | `gpio:3:0` | `gpio:3:1` |
| 2 | `gpio:3:2` | `gpio:3:3` |
| 3 | `gpio:3:4` | `gpio:3:5` |
| 4 | `gpio:3:6` | `gpio:3:7` |

（`gpio:3:N` = 第 4 个 gpiochip 的第 N 脚；极性原厂按低有效用，未逐一验证。）

### SFP（F1）

| 信号 | 位置 |
|---|---|
| EEPROM | `i2c-1` 0x50 |
| 诊断 | `i2c-1` 0x51 |
| TX_FAULT | `gpio:1:2` |
| RX_LOS | `gpio:1:1` |
| TX_DISABLE | `gpio:1:7` |
| PRESENT | `-gpio:1:3`（负号=低有效） |

## 6.3 MDIO 上的其它器件

| 地址 | 器件 |
|---|---|
| i2c-0 0x20 | PCA9555（LED 扩展，`pca953x` 已绑定） |
| i2c-0 0x57 | EEPROM |
| i2c-0 0x64 | 未知（原厂可能用于 VPD/加密芯片） |
| i2c-1 0x20 | DT 里还有一个 pca953x，但**探测失败**（`-5`），实物不存在 |

## 6.4 `mvswitch` 命令（U-Boot）

```
mvswitch <mii_add> info                                 # 芯片信息
mvswitch <mii_add> read   <port> <reg>                  # 读端口寄存器
mvswitch <mii_add> write  <port> <reg> <val>            # 写端口寄存器
mvswitch <mii_add> phy_read  <port> <page> <reg>        # 读内置 PHY
mvswitch <mii_add> phy_write <port> <page> <reg> <val>  # 写内置 PHY
mvswitch <mii_add> dev_read  <port> <device> <reg>      # 读内部 device 寄存器
mvswitch <mii_add> dev_write <port> <device> <reg> <val>
mvswitch <mii_add> link  <port>                         # 链路状态/速率
```

### 实测记录

```
mvswitch 2 read 1 4      → 0x7F        # Port Control：bits[1:0]=0b11 = Forwarding
mvswitch 2 read 9 4      → 0x7F
mvswitch 2 read 1 0      → 0x100F      # Port Status: bit12=duplex, bit11=link(0)
mvswitch 2 phy_read 1 0 0 → 0x1140     # BMCR: AN enable + full + 1G
mvswitch 2 phy_read 1 0 1 → 0x7949     # BMSR: link bit = 0
mvswitch 2 phy_write 1 0 0 0x2100 → 读回 0x2100   # 强制 100M 全双工，写入有效
```

### 让面板口亮起来的完整流程（实测）

```
# 1. 复位交换机（GPIO CP2 pin17）
gpio clear C17; sleep 2; gpio set C17; sleep 2

# 2. 所有端口置为 forwarding（逐口写，不要用 for 循环）
mvswitch 2 write 0 4 0x7f
mvswitch 2 write 1 4 0x7f
… (1..9)

# 3. CPU 口额外配置
mvswitch 2 dev_write 0 4 f002 804d
mvswitch 2 dev_write 0 4 2000 9140

# 4. PHY 使能自协商（1..4 是实际用到的 4 个口）
mvswitch 2 phy_write 1 0 0 0x9140
mvswitch 2 phy_write 2 0 0 0x9140
mvswitch 2 phy_write 3 0 0 0x9140
mvswitch 2 phy_write 4 0 0 0x9140

# 5. 验证
mvswitch 2 link 1     → Link: UP, Duplex: FULL, Speed: 1000 Mbps
```

> **踩坑记录**：插网线一定要插到底（听到"咔"）。我们一开始查了半天 PHY 寄存器，
> 结果是网线没插紧 —— BMSR 的 link 位一直为 0。判断顺序应该是：
> 先看 `mvswitch 2 link N`，再看 PHY BMSR，最后才怀疑配置。

## 6.5 Linux 侧怎么用这些口（三条路）

### A. 内核 DSA（推荐，做 OpenWrt 时）

- 需要 `CONFIG_NET_DSA` + `CONFIG_MV88E6XXX`，DT 改写成标准 DSA 结构（`ports { port@N { reg=…; phy-handle=…; } }`）。
- 好处：每个口一个 `lan1..lan4` / `sfp`，走 `swconfig`/DSA 的 VLAN、bridge。
- 需要确认 88E6193X 在 mainline `mv88e6xxx` 里的支持程度（6393X 系列有支持，
  6193 是它的裁剪版，可能要用 6393X 的 ID 表）。

### B. U-Boot 配好 + Linux 只当"一个网口"

- 面板口之间硬件转发，CPU 口就是一个普通 1G/10G 上联。
- Linux 只看得到 eth0（实际上所有口都在一个平面里）。
- 最简单，适合"当傻瓜交换机 + 一个路由器口"。

### C. 用户态 CPSS（原厂做法）

- `/usr/marvell/cpss_agent` + `umsd_*.cfg`，能做完整的 VLAN/ACL/镜像。
- 但闭源、只支持原厂内核，不推荐在新系统上走这条。

## 6.6 MAC 地址

| 来源 | 值 |
|---|---|
| VPD 基址 | `7C:5A:1C:XX:XX:XX`（`eth.macs=7` → 连续 7 个） |
| U-Boot `ethaddr` | VPD 基址 + 5（实测值已脱敏） |
| `eth1addr…eth4addr` | `00:51:82:11:22:01…04`（Marvell 默认占位，未改） |
| `mvmgmt0` | 另一段地址（原厂生成） |

> 刷机规划：面板口建议按 `基址+N` 分配，管理口单独一段，别把 `00:51:82:11:22:0x` 当真。

## 6.7 未验证 / 待确认

- [ ] SFP 口是 1G 还是支持 2.5G/10G（88E6193X 的 port 9 能力待查 datasheet）
- [ ] LED 极性（green/amber 哪个是高有效）
- [ ] `dev_write … 4 f002/2000` 这两个寄存器到底写了什么（需要 datasheet 或反汇编）
- [ ] 端口 5-8 在 4 口机型上是引到哪的（可能未引出）
