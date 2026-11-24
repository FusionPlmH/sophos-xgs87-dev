# 06 · 交换机与端口（**全部在 NPU 上**）

> 🏷 **状态（2026-11-23 复核）**：✅ **大部分实测**（9 口 + SFP 10G + DSA 已在现机复核）；⚠️ **LED 极性未逐一验证** —— `gpio:3:x` 的编号沿用原厂记录。
>
> ⚠️ **本文所有命令都在 NPU 上执行**（`image/` 系统：`ssh admin@10.234.56.1`；p3 原厂：`root@…`）。
> x86 没有交换机、看不到 `p1…p8`。

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

> **原厂 4.14 内核里没有 mv88e6xxx 驱动**（`kallsyms` 无符号、`/lib/modules` 无模块、
> config 里也没有 `CONFIG_MV88E6XXX`）。在原厂系统里这个节点只是"占位"，
> 交换机实际由 U-Boot `mvswitch` + 用户态 CPSS 控制。
>
> **现在的 Debian 13 不一样**：`mv88e6xxx` + DSA 是正常加载的（发行版模块；自编 TCAM 补丁可选），
> 内核会重新配置端口；U-Boot 的 `mvswitch` 只负责让 SFP 在 boot 早期先 link。
> 本文的 `mvswitch` 记录仍然有效，但它描述的是**原厂/U-Boot 阶段**。

## 6.2 端口映射

来自 `/opt/sophos/plt/AMDA0200-0001R00.txt`（原厂机型定义，实测一致）：

| 面板 | 交换机口 | 类型 | 原厂网卡 | 现在 DSA | init_speed | PHY LED ctl |
|---|---|---|---|---|---|---|
| 1 / LAN | 1 | RJ45 内置 PHY | eth0 | p1 | 1G | 0xe3 |
| 2 / WAN | 2 | RJ45 | eth1 | p2 | 1G | 0xe3 |
| 3 / DMZ | 3 | RJ45 | eth2 | p3 | 1G | 0xe3 |
| 4 | 4 | RJ45 | eth3 | p4 | 1G | 0xe3 |
| F1 | 9 | SFP (SFF-8431) | eth4 | sfp | 1G（模块可 10G） | 0xe1 |
| CPU | 0 | 10GBase-KR | bp0 port0 | end0 | 10G | — |

背板定义：`npu0.bp0.port0=0:0`（CN9130）、`npu0.bp0.port1=1:0`（交换机 port 0）。

### 指示灯（PCA9555 @ i2c-0 0x20）—— ⚠️ 本机实测不适用

原厂 platform 文件里定义的映射（**rev 1.40 板子的假设**）：

| 面板 | 声称 green | 声称 amber |
|---|---|---|
| 1 | `gpio:3:0` | `gpio:3:1` |
| 2 | `gpio:3:2` | `gpio:3:3` |
| 3 | `gpio:3:4` | `gpio:3:5` |
| 4 | `gpio:3:6` | `gpio:3:7` |

**本机（rev 07）实测推翻了它**：把 PCA9555 的 16 个输出整体拉低 / 拉高，
面板 LED 状态**没有任何变化**，只有插了网线的口（LAN1/LAN4）亮 —— 说明这些灯是
**PHY 直接驱动**的，与 PCA9555 无关。详见 [12-measurements.md](12-measurements.md) §12.7。

> 参考项目的 `gpio-leds` 节点在我们的机器上不成立（那套映射是另一个机型的）；用 PHY 的 LED 控制寄存器
> （`MVL6193LEDcontrol=0xe3`）或者重新测绘。

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
mvswitch 2 read 0 0 → 0x0F4D   # CPU 口: LINK, DUPLEX, speed=3(10G), CMODE=0xD
mvswitch 2 read 1 0 → 0x1E4F   # LAN1:  LINK, DUPLEX, speed=2(1G),  CMODE=0xF(内置PHY)
mvswitch 2 read 4 0 → 0x1E0F   # LAN4:  LINK, DUPLEX, speed=2(1G),  CMODE=0xF
mvswitch 2 read 9 0 → 0x0249   # SFP:   LINK=0, CMODE=0x9(1000BASE-X)
mvswitch 2 read 1 4 → 0x7F     # Port Control: bits[1:0]=0b11 = Forwarding
mvswitch 2 read 9 4 → 0x7F
mvswitch 2 phy_read 1 0 0 → 0x1140     # BMCR: AN enable + full + 1G
mvswitch 2 phy_read 1 0 1 → 0x7949     # BMSR: link bit = 0（当时线没插好）
mvswitch 2 phy_write 1 0 0 0x2100 → 读回 0x2100   # 强制 100M 全双工，写入有效
```

位定义（来自上游 U-Boot 源码 `mv88e6xxx-util.h`）：
`bit11=LINK, bit10=DUPLEX, bits[9:8]=SPEED(0=10M,1=100M,2=1G,3=2.5G/10G), bits[3:0]=CMODE`。

### `dev_write` 的真实语义（已由上游源码 + 实测确认）

`mvswitch <mii> dev_write <port> <dev> <reg> <val>` **不是**"写端口寄存器"，
而是 **Clause-45 间接访问**：

```
SMI_DATA = reg ; SMI_CMD = OP_45_WRITE_ADDR | (port << 5) | dev
SMI_DATA = val ; SMI_CMD = OP_45_WRITE_DATA | (port << 5) | dev
```

所以 U-Boot env 里的 `dev_write 0 4 f002 804d` = 对 **(port 0, device 4, register 0xF002)** 写 0x804D。

实测这两个寄存器：

| port | dev4/0xF002 | dev4/0x2000 | 说明 |
|---|---|---|---|
| 0（10G CPU） | 0x004D | 0x1140 | 有 SerDes/PCS 块 |
| 9（SFP） | 0x004D | 0x1140 | 同一块 |
| 1-8 | 0xFFFF | 0xFFFF | 内置 PHY，没有这块 |

写入值会自清 bit15（0x804D→0x004D，0x9140→0x1140），和 MDIO BMCR 行为一致。
**结论：device 4 = 两个 SerDes 口（0 与 9）的 PCS/SerDes；当前都配成自协商 1G。**

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

> **踩坑记录 1**：插网线一定要插到底（听到"咔"）。我们一开始查了半天 PHY 寄存器，
> 结果是网线没插紧 —— BMSR 的 link 位一直为 0。判断顺序应该是：
> 先看 `mvswitch 2 link N`，再看 PHY BMSR，最后才怀疑配置。

> **踩坑记录 2（本轮最费时的坑）**：**复位脉宽必须 ≥2 s**。
> Linux 里用 `gpioset 2 17=0` 会立刻退出、释放引脚，脉宽≈0，芯片停在半初始化状态：
> `PORT_CONTROL(0x04)` 读回 `0x7c`（PortState=0 **Disabled**）。
> 此时所有 `link` 都显示 UP、`eth0` 甚至能 10Gbps/Full，但**一帧都不转发**。必须用
> `gpioset -m time -s 2 2 17=0`，或者在 U-Boot 里 `gpio clear C17; sleep 2; gpio set C17`。

> **踩坑记录 3**：Marvell U-Boot 自带的 `switch init` **不等价于**原厂的 `sw_init_2`。
> `switch init` 之后 port 9 的 CMODE 变成 `0xF`（MAC 模式，CMODE 写不动了），
> 铜口 PHY 也不复位 —— 网络是坏的。要用 6.4 里这套原厂序列。

这套序列就是原厂 U-Boot 环境变量 `sw_init_p0..p3` / `sw_init_2` 的内容，
`fw_printenv` 可直接看到（详见 [12-measurements.md](12-measurements.md#1212)）。

### Linux 侧等价做法（原厂 `xgs-mdio`，无需 U-Boot）

原厂 Buildroot 里有 Sophos 自己的工具 `xgs-mdio`（现在的 Debian 可以装标准 `mdio-tools`，
镜像默认没带；调试时 `apt install mdio-tools` 即可），支持 Amethyst Clause-45：

```sh
xgs-mdio -a 0 2 <port>.<reg>            # 交换机端口寄存器（读）
xgs-mdio -a 0 2 <port>.<reg> <val>      # 写
xgs-mdio -d <port> 0 2 <dev>.<reg>      # dev 空间（dev 4 = SerDes/PCS）
xgs-mdio -y <port> ...                  # 内置 PHY（Clause-22 风格）
```

例：把 SFP 口（port 9）切到 10GBASE-R 并起链路 ——

```sh
xgs-mdio -a 0 2 9.0 0xd
xgs-mdio -d 9 0 2 4.0xf002 0x804d
xgs-mdio -d 9 0 2 4.0x2000 0x9140
xgs-mdio -a 0 2 9.0        # → 0xf4d（LINK=1, 10 Gbps, CMODE=0xD）
```

注意 CMODE 只在端口处于 `0x9`（刚硬复位）时可写；`0xF` 状态下写了会被硬件还原（详见 12.11）。

## 6.5 Linux 侧怎么用这些口（三条路）

### A. 内核 DSA（推荐，**现在用的就是这个**）

- 需要 `CONFIG_NET_DSA` + `CONFIG_MV88E6XXX`，DT 改写成标准 DSA 结构（`ports { port@N { reg=…; phy-handle=…; } }`）。
- 本机已实测可用：9 个 netdev（`p1`–`p8` + `sfp`），`mv88e6xxx` 用发行版模块；
  两个 TCAM 修复是可选补丁（[net/patches/](../net/patches/)），见 [19](19-module-vs-kernel-rebuild.md)。
- 好处：每个口一个 netdev，可以用 DSA 的 VLAN、bridge、`tc mirred` 镜像。

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
| `eth1addr…eth4addr` | `00:51:82:11:22:01…04`（Marvell 默认占位，未改；**不要当真**） |
| `mvmgmt0` | 原厂把 eth0 的地址复用到管理口，不是另一段 |

本机实际分配（`systemd/npu/xgs-ports-init.sh`）：

```
p1  = 基址+0    p2 = 基址+1    p3 = 基址+2    p4 = 基址+3
sfp = 基址+4    end0 / ethaddr = 基址+5    基址+6 留空
```

> 旧版本脚本按"19 个连续地址、end0=label+9"推，和 VPD 的 `eth.macs=7` 对不上，
> 会把 p1–p4 推到基址以下。已改成上面的 7 地址方案；`PANEL_PORTS` 可覆盖以适配 XGS 107。

## 6.7 未验证 / 待确认

- [x] **SFP 是否支持 2.5G/10G**：10GBASE-SR 模块实测 **10Gbps UP**（[12.11](12-measurements.md#1211)）；
      2.5G/5G 模块没测，但 phylink 走同一条自适应路径
- [ ] LED 到底接在哪（本机实测：与 PCA9555 无关，跟随 PHY link）
- [ ] `dev_write … 4 f002/2000` 这两个寄存器在 PCS 里的具体含义（已知是 SerDes 块，
      写 0x804D/0x9140 分别是 reset+AN，字段级定义需要 datasheet）
- [ ] 端口 5-8 在 4 口机型是否引出（PHY 存在，但面板只有 4 个座；需看 PCB）
