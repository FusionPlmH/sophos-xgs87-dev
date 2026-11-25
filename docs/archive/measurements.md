# 📦 档案：12 · 实测记录（把"推断"变成"测量"）

> 🏷 **状态（2026-11-23 复核）**：✅ **原始实测记录**：数据本身有效，但其中"mainline 支持情况"等结论已被后续工作推翻，以 14/17/20 为准。
>
> ⚠️ **机器别搞混**：§12.1 是 **x86** 视角；§12.2–12.9、12.11–12.14 是 **NPU**（含 U-Boot）；§12.15 之后是资料调研。

本文件记录 2026-11-22 第二轮实测：专门去验证第一版文档里标着"推断/待验证"的条目。
每条都附访问方式（串口 / SSH / U-Boot）和原始数据。

| 条目 | 结论 | 状态 |
|---|---|---|
| NPU console 走 x86 `ttyS2` | 确认 | ✅ 实测 |
| LED 由 PCA9555 驱动（参考项目说法） | **不成立**（本板 rev 07） | ✅ 实测 |
| `mvswitch dev_write` 语义 | Clause-45 间接，device 4 = SerDes/PCS | ✅ 实测 + 上游源码 |
| 交换机型号 | 88E6193（product 0x193，Amethyst/Peridot 寻址） | ✅ 实测 + 上游源码 |
| SFP 口当前模式 | 原厂默认 **1000BASE-X**；改成 10GBASE-R 后 **10 Gbps 链路成功** | ✅ 实测（见 12.11） |
| SFP 是否支持 2.5G/10G | **10GBASE-SR 模块 + 10G 对端 = 10 Gbps UP**；2.5G 未测 | ✅ 10G 实测 |
| CPU 口速率 | 交换机 port 0 ↔ NPU Comphy-4 SFI0，**10 Gbps UP** | ✅ 实测 |
| 原厂交换机初始化序列 | 从 U-Boot env 的 `sw_init_p0..p3` 完整挖出并复现 | ✅ 实测（见 12.12） |
| x86 能否复位 NPU | 反向确认：**x86 重启会复位 NPU 与交换机** | ✅ 实测 |
| NTB: 1 MiB BAR 对齐 / dma-coherent | 已由 vNTB 实机跑通：1 MiB 对齐必需，`dma-coherent` 必须去掉 | ✅ 见 docs/17 |
| NTB: MSI vs MSI-X | 设备同时提供 MSI 和 MSI-X（16 向量），实际必须用 MSI | ✅ 见 docs/17 §17.6 |
| 端口 5-8 是否引出 | PHY 存在但面板只有 4 个座；p5–p8 是 XGS 107 才有 | ✅ 用户确认 |

---

## 12.1 PCIe 端点（x86 视角，`lspci -vvv -s 03:00.0`）

```
03:00.0 Ethernet controller: Marvell Technology Group Ltd. Device [11ab:7080]
        Region 0: Memory at … [size=1M]
        Region 2: Memory at … [size=16M]
        Region 4: Memory at … [size=16M]
        Capabilities: [40] Power Management version 3
        Capabilities: [50] MSI: Enable- Count=1/32 Maskable+ 64bit+
        Capabilities: [70] Express (v2) Endpoint, IntMsgNum 0
        Capabilities: [b0] MSI-X: Enable- Count=16 Masked-
                Vector table: BAR=0 offset=00001000
                PBA: BAR=0 offset=00001800
        Capabilities: [178 v1] Single Root I/O Virtualization (SR-IOV)
                Initial VFs: 6, Total VFs: 6, VF offset: 2, VF Device ID: 7081
        LnkSta: Speed 8GT/s, Width x2 (downgraded from x4)
```

**结论**：设备**同时**实现 MSI 和 MSI-X；MSI-X 有 16 个向量，表在 BAR0 偏移 0x1000。
"只发 MSI"这个行为需要驱动实际下发中断才能确认（当前没驱动）。

## 12.2 NPU 侧 iATU 原始值（`devmem 0xf2600000 + 0x900..`）

```
0x900 = 0x80000000   0x904 = 0x00000000   0x908 = 0xC0000000
0x90c = 0x00000000   0x910 = 0x0000FFFF   0x914 = 0x6BA00000
0x918 = 0x00000000   0x91c = 0x00000000   0x920..0x940 = 0
```

EP 头：`0x000 = 0x708011AB`（VID 11AB / DID 7080）、`0x004 = 0x00100006`（Memory + Bus Master 已使能）、
`0x008 = 0x02000000`（class 0200 = Ethernet）。

> 解释限制：0x900 处是 viewport（bit31=1 → inbound，region 0），但后续寄存器的
> 具体字段布局随 DWC 版本不同而不同，**没有该版本手册就不硬解**。
> 可以确定的是：存在一个已使能的入站窗口，目标是 `0x6BA00000`（与内核日志
> `BAR0 address @ ffff80006ba00000` 一致）。
> "1 MiB 对齐"和"dma-coherent"两条后来由 vNTB 实机验证（见 [档案](../archive/p8-shared-mgmt.md) §17.6）；
> 这一段保留的是原厂 EP 状态下的原始读数。

## 12.3 交换机 ID 与寻址（U-Boot）

```
Marvell>> mvswitch 2 info
Switch    : SOHO
Series    : Amethyst
Product # : 193
Revision  : 0
```

上游源码（Marvell U-Boot `cmd/mvebu/mv88e6xxx-util.c`，见 SolidRun 的
`1141-cmd-marvell-add-mv88e6xxx-switch-util.patch`）里的产品号表：

```c
#define PORT_SWITCH_ID_PROD_NUM_6190  0x190
#define PORT_SWITCH_ID_PROD_NUM_6193  0x193
...
REG_PORT_BASE_LEGACY  0x10   /* 6141/6341 用 */
REG_PORT_BASE_PERIDOT 0     /* 6190/6193/6290/6390/6390X 用 */
```

**结论**：product 0x193 = **88E6193**，属于 Amethyst 系列，端口寻址用 Peridot 方式
（port 号直接就是 SMI device address，从 0 开始）。

## 12.4 `mvswitch dev_write` 到底是什么

上游实现（`mv88e6xxx_write_dev_register`）做的是 **Clause-45 间接访问**：

```
SMI_DATA = reg ;  SMI_CMD = OP_45_WRITE_ADDR | (port << 5) | devic
SMI_DATA = val ;  SMI_CMD = OP_45_WRITE_DATA | (port << 5) | devic
```

即 `dev_write <port> <dev> <reg> <val>` = 对 **(SMI device = port, device = dev, register = reg)** 写 16 位值。
不是"往端口寄存器 X 写"。

实测（`mvswitch 2 dev_read <port> 4 f002` / `2000`）：

| port | dev 4 / reg 0xF002 | dev 4 / reg 0x2000 |
|---|---|---|
| 0（10G CPU 口） | 0x004D | 0x1140 |
| 1（内置 PHY） | **0xFFFF** | **0xFFFF** |
| 5 | 0xFFFF | — |
| 8 | 0xFFFF | — |
| 9（SFP） | 0x004D | 0x1140 |

配合 U-Boot env 里的 `dev_write 0 4 f002 804d` / `0 4 2000 9140`：

- **device 4 = 两个 SerDes 口（port 0 与 port 9）的 PCS/SerDes 寄存器块**；
  port 1-8 是内置 PHY，没有这块（读回 0xFFFF）。
- 写进去的值会"自清最高位"：0x804D→0x004D、0x9140→0x1140，行为与 MDIO 的
  BMCR（bit15 = reset，自清）完全一致。
- 0x1140 = 自协商使能 + 全双工 + 1G。

**所以**：SFP 口和 10G CPU 口共用同一套 SerDes 配置路径，但当前都被配成 **1G**。

## 12.5 端口状态寄存器（PORT_STATUS = reg 0x00）

上游头文件里的位定义：

```
bit11 LINK, bit10 DUPLEX, bit13 HD_FLOW,
bits[9:8] SPEED (0=10M,1=100M,2=1000M,3=2500M/10G),
bits[3:0] CMODE (8=100BASE-X, 9=1000BASE-X, A=SGMII, B=2500BASE-X)
```

实测：

| port | 面板 | PORT_STATUS | 解码 |
|---|---|---|---|
| 0 | CPU | 0x0F4D | LINK=1, DUPLEX=1, speed=3(10G), CMODE=0xD |
| 1 | 1/LAN | 0x1E4F | LINK=1, DUPLEX=1, speed=2(**1G**), CMODE=0xF(内置 PHY) |
| 4 | 4 | 0x1E0F | LINK=1, DUPLEX=1, speed=2(**1G**), CMODE=0xF |
| 9 | F1 SFP | 0x0249 | **LINK=0**, CMODE=0x9(**1000BASE-X**) |

PCS 控制（reg 0x01）：port 0 = 0x3，port 9 = 0x3 → `PORT_PCS_CTRL_UNFORCED`（自协商）。
端口控制（reg 0x04）：port 0 = 0x7F，port 9 = 0x7F（forwarding + 允许未知单播/组播）。

## 12.6 SFP 现场状态

```
i2cdetect -y 1        → 全空（0x50/0x51 都没有器件）   ← 没插模块
gpioget 1 1 2 3 7     → 1 1 1 1
  1:1 rx_los=1   1:2 tx_fault=1   1:3 present=1(低有效=不在位)   1:7 tx_disable=1
```

**结论**：没装模块，座子和 GPIO 都能读；端口当前是 1000BASE-X。
要确认 2.5G/10G 能力，必须插一个对应速率的模块再读 PORT_STATUS 的速度位。

## 12.7 LED：PCA9555 **不是**面板灯的驱动（推翻参考项目假设）

实验设计：NPU 上把 PCA9555（`/dev/gpiochip3`，i2c-0 0x20）16 个输出**全部拉低**保持，
再看面板；然后**全部拉高**保持，再看面板。

| 状态 | 观察结果（用户目视） |
|---|---|
| 全部拉低 | 只有 **LAN1、LAN4** 亮（正好是插了网线、link up 的两个口） |
| 全部拉高 | **完全一样** |
| 松开（默认） | 一样 |

补充验证：unbind `pca953x` 后直接读芯片，输出锁存器 = 0xFF（说明我们的写入确实到了芯片）。

**结论**：在 **rev 07** 这块板子上，前面板 LED 跟随 **PHY 的 link 状态**，与 PCA9555 输出无关。
参考项目 `openwrt-sophos-xgs107` 里"每个脚一个 gpio-leds、2N-2 绿 / 2N-1 琥珀"的映射
是基于 **rev 1.40** 的板子，**不能直接套用**。

> 影响：不要照抄那个 LED 节点；要么用 PHY 自带的 LED 控制
> （platform 文件里的 `MVL6193LEDcontrol=0xe3`），要么重新测绘 PCA9555 到底接了什么。

## 12.8 x86 能否复位 NPU

已查：

```
/sys/kernel/debug/gpio → gpiochip0: GPIOs 512-703 (AMD0030:00, 192 线)
                         全部 "∅ ... unused"，没有任何线被驱动/ACPI 占用
ACPI 设备列表 → 没有 Sophos 专有 HID（只有 AMD0010/0020/0030、BCM2F25、BCM4752、TPM 等）
i2c 总线 → i2c-0/1 是 Synopsys DesignWare，i2c-2/3/4 是 PIIX4 SMBus，未见 CPLD
```

**结论**：x86 上**没有**通过 ACPI/GPIO 暴露的 NPU 复位线。剩下两种可能：

1. **MCP2210**（USB-SPI，`04d8:00de`）的 9 个 GPIO 之一；
2. PCB 上的硬连线/CPLD，Linux 不可见。

要确定只能：读 MCP2210 的 GPIO 配置（需要它的 HID 命令集），或者拿表量板子。
**本轮未做**（写错 GPIO 有风险，且在没确认引脚含义前不应盲试）。

## 12.9 端口 5-8

- 交换芯片的 8 个内置 PHY 都存在（port 1-8 的 BMSR 都能读，值相同 0x7949）。
- 但 dev-4 寄存器只有 port 0/9 有 → 5-8 确实是内置 PHY 口。
- 面板只有 4 个 RJ45 座；实测 **LAN1→port 1**、**LAN4→port 4**。
- 因此 5-8 在 4 口机型上**没有引出到面板**（要百分百确认需看 PCB 走线）。

## 12.10 复现命令清单

```sh
# NPU（Linux）
gpioget 3 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15     # PCA9555 状态
i2cdetect -y 0 ; i2cdetect -y 1                      # LED 扩展器 / SFP
gpioget 1 1 2 3 7                                    # SFP 的 rx_los/tx_fault/present/tx_disable
devmem 0xf2600000 32                                 # EP VID/DID
devmem 0xf2600908 32                                 # iATU ctrl2

# NPU（U-Boot）
mvswitch 2 info
mvswitch 2 read  <port> 0                            # PORT_STATUS
mvswitch 2 read  <port> 1                            # PCS control
mvswitch 2 dev_read <port> 4 0x2000                  # SerDes/PCS（仅 port 0/9 有）
mvswitch 2 link <port>

# x86（Debian）
lspci -vvv -s 03:00.0
cat /sys/kernel/debug/gpio | head -60
```

---

## 12.11 SFP+ 口 10 Gbps 实测（成功）

现场条件：SFP 笼里插 **10GBASE-SR** 模块（EEPROM byte0=`0x03`, byte3=`0x10`），另一端接家用路由器的 10G SFP+ 口。

**结论：链路能起，速率 10 Gbps 全双工。**

### 步骤（U-Boot 或 Linux 均可）

```sh
# U-Boot
mvswitch 2 write      9 0 0xd            # PORT_STATUS.CMODE = 0xD（10GBASE-R 编码）
mvswitch 2 dev_write  9 4 f002 0x804d    # SerDes/PCS 配置
mvswitch 2 dev_write  9 4 2000 0x9140    # PCS BMCR：reset + AN enable
mvswitch 2 link 9                        # 约 3 秒后

# Linux 等价（用原厂 xgs-mdio，Amethyst Clause-45）
xgs-mdio -a 0 2 9.0 0xd
xgs-mdio -d 9 0 2 4.0xf002 0x804d
xgs-mdio -d 9 0 2 4.0x2000 0x9140
```

实测输出：

```
Port: 0x9, Link: UP, Duplex: FULL, Speed: 10 Gbps
Read - switch port: 0x9, reg: 0x0, val: 0xF4D      # bit11 LINK=1, speed=3, CMODE=0xD
```

### CMODE 能不能写，取决于端口当前状态

| 端口当前 CMODE | 写 0xD 的结果 |
|---|---|
| `0x9`（芯片刚硬复位，1000BASE-X） | **生效**，读回 `0x34D`→链路起来后 `0xF4D` |
| `0xF`（`switch init`/原厂 init 之后，MAC 模式） | 写入瞬间读回 `0xD`，再读又变回 `0xF`（被硬件忽略） |

所以「先硬复位交换芯片，再写 CMODE」是唯一可靠的顺序。

### CPU 口本来就是 10G

- 交换机 port 0：CMODE `0xD`，`init_speed=10G`（平台库），对端是 NPU 的 Comphy-4 SFI0 10.3125 Gbps。
- Linux 里 `mvpp2` 打印：`mvpp2 f2000000.ethernet eth0: configuring for inband/10gbase-kr link mode` → `Link is Up - 10Gbps/Full - flow control off`。
- 打开 port 0 的 PCS（`dev_write 0 4 f002 804d` + `2000 9140`）后，port 0 立刻变 `0x0F4D`。

### 已验证到什么程度

- ✅ 物理/PCS 层：SFP 10G 链路、CPU 10G 链路都实测 UP。
- ✅ 数据面：LAN1（1G）↔ 交换机 ↔ CPU 口（10G）↔ `eth0` 全程可用 —— ping、SSH、**93 MB/s** 的整盘 dump 都跑在这条路上。
- ⛔ **SFP 10G 同时转发**：做不到，见下面的实测。

### 重要：把 port 9 切成 10GBASE-R 会让**整个交换机停止转发**

在原厂 `sw_init` 配好的、本来完全正常的二层状态里，只做这一步：

```sh
xgs-mdio -a 0 2 9.0 0xd            # port 9: 1000BASE-X → 10GBASE-R
xgs-mdio -d 9 0 2 4.0xf002 0x804d
xgs-mdio -d 9 0 2 4.0x2000 0x9140
```

结果：

| 观察项 | 结果 |
|---|---|
| port 9 PORT_STATUS | `0x0e49` → **`0x0f4d`**（LINK=1, speed=3, CMODE=0xD）→ 10 Gbps 链路成功 |
| port 0（CPU）PORT_STATUS | `0x0f4d`（仍然 10 Gbps UP） |
| port 9 `PORT_CONTROL(0x04)` | `0x007f`（Forwarding，没被改） |
| **LAN1 ↔ PC 的 ping / SSH** | **全部中断** |
| SFP 侧 DHCP（对端为家用路由器） | 拿不到租约 |

把 port 9 写回 `0x9` + 同样的 PCS 初始化后，**ping / SSH 立刻恢复**。
说明 88E6193X 在 10GBASE-R 模式下不是"链路上、转发照旧"：厂商配置里这个
端口 MAC 的速率/流控/SerDes 参数没有按 10G 设置，整块芯片的转发随之失效。

结论：**10G SFP 不是靠写几个寄存器就能用的**，必须由 mainline `mv88e6xxx`
DSA 驱动按 phylink 流程把端口带起来（见 12.15）。在那之前，SFP 口按原厂 1 Gbps 用是稳定的。

---

## 12.12 原厂交换机初始化序列（U-Boot env 里挖出来的）

`fw_printenv` 里有完整配方，这是**整台机器网络能不能通的根**：

```
sw_init_p0=gpio clear C17; sleep 2; gpio set C17; sleep 2
sw_init_p1=for i in '0 1 2 3 4 5 6 7 8 9' ; do mvswitch 2 write $i 4 0x7f ; done
sw_init_p2=for i in '0 9'; do mvswitch 2 dev_write $i 4 f002 804d ; mvswitch 2 dev_write $i 4 2000 9140 ; done
sw_init_p3=for i in '1 2 3 4 5 6 7 8' ; do mvswitch 2 phy_write $i 0 0 9140 ; done
sw_init_2=run sw_init_p0; run sw_init_p1; run sw_init_p2; run sw_init_p3
```

含义：

| 变量 | 作用 |
|---|---|
| `sw_init_p0` | 交换芯片**硬复位**（`C17` = CP GPIO2 pin17 = 全局 gpio 81，Linux 里是 `gpioset 2 17=…`），低电平保持 2 s |
| `sw_init_p1` | 每个端口 `PORT_CONTROL(0x04)=0x7f` → PortState=Forwarding |
| `sw_init_p2` | 两个 SerDes 口（0 和 9）的 PCS 初始化 |
| `sw_init_p3` | 铜口内置 PHY 复位（page0 reg0 = 0x9140） |

### 三个致命坑（都实测踩过）

1. **hush 的 for 循环是坏的**：`for i in '0 1 2 …'` 会把整串当成**一个单词**，循环体只跑一次、参数错乱。
   → 必须逐口显式写：`mvswitch 2 write 0 4 0x7f`、`mvswitch 2 write 1 4 0x7f` …
2. **复位脉宽必须 ≥2 s**：Linux 里 `gpioset 2 17=0` 会立刻退出释放引脚（脉宽≈0），芯片停在半初始化状态。
3. **半初始化 = 链路 UP 但不转发**：`PORT_CONTROL(0x04)` 读回 `0x7c`（PortState=0 Disabled）。此时 `link` 全绿、`eth0` 甚至能 10Gbps/Full，但**一帧都不通** —— 这是本轮最费时间的坑。
4. 硬复位后铜口 PHY 需要 `phy_write <port> 0 0 0x9140` 才会重新协商，否则 PORT_STATUS 一直是 `0x100F`。

### 复现结果

按上面 4 步逐条执行后（U-Boot）：

```
Port: 0x0, Link: UP, Duplex: FULL, Speed: 10 Gbps      ← CPU 口
Port: 0x1, Link: UP, Duplex: FULL, Speed: 1000 Mbps    ← LAN1（接路由器/PC）
Port: 0x9, Link: UP, Duplex: FULL, Speed: 1000 Mbps    ← SFP（原厂 1G 模式）
```

随后 `boot` 进 Linux、`ifconfig eth0 192.168.1.1 netmask 255.255.255.0 up`，
PC 侧 `ping 192.168.1.1` 与 SSH 全部正常。

> 注意：`switch init`（Marvell U-Boot 自带命令）与 `sw_init_2`（原厂 env）**不等价**。
> `switch init` 之后 port 9 会变成 CMODE `0xF` + 铜口 PHY 不动，网络是坏的。

---

## 12.13 完整存储备份（已完成，SHA256 全部校验通过）

NPU 侧 `mount -o remount,ro /`，通过 SSH（1 GbE，**93 MB/s**）流式导出到 PC：

| 文件 | 大小 (bytes) | sha256（前后一致） |
|---|---|---|
| `mmcblk0-full.img` | 7 818 182 656 | `3e8cd812…29b04e8f` |
| `mmcblk0boot0.bin` | 4 194 304 | `bb9f8df6…0de3d3af` |
| `mmcblk0boot1.bin` | 4 194 304 | `bb9f8df6…0de3d3af`（与 boot0 全同，即全 0） |
| `mtd0-uboot.bin` | 4 128 768 | `fe13a2a3…031c2473`（与早前 dump 逐字节一致） |
| `mtd1-uboot-env.bin` | 65 536 | `6cb5a3b3…5c83669b` |

镜像里的分区表（MBR）：

| 分区 | 起始 LBA | 扇区数 | 大小 | 用途 |
|---|---|---|---|---|
| p1 | 2048 | 1 024 000 | 500 MiB | 最老的 Sophos 槽（原厂冷备） |
| p2 | 1 026 048 | 3 121 152 | 1524 MiB | **现在跑 Debian 13（root=）** |
| p3 | 4 147 200 | 3 121 152 | 1524 MiB | 原厂系统（`bootcmd_emmc3` 可回滚） |
| p4 | 7 268 352 | 204 800 | 100 MiB | `/persistent` (VPD) |

恢复：

```sh
# 整盘（NPU Linux 或 U-Boot 环境里）
dd if=mmcblk0-full.img of=/dev/mmcblk0 bs=1M conv=fsync
# 单分区，例如 p3
dd if=mmcblk0-full.img of=/dev/mmcblk0p3 bs=1M skip=4050 count=3048 conv=fsync
```

`mmcblk0-full.img` 等文件**不入 git**（原厂固件版权 + 体积），只留在本地 PC。

---

## 12.14 平台数据库：原厂对这块板的权威描述

`/opt/sophos/plt/AMDA0200-0002R03.txt`（"Desktop XGS 87w"，rev 03 及以后）：

```
npu0.device1=88E6193X
npu0.device1.mdio=mdio22:0:2          # 交换机在 MDIO addr 2
npu0.eth4.port=1:9                    # SFP = 交换机 port 9
npu0.eth4.init_speed=1G               # ← 原厂只把 SFP 当 1G 口！
npu0.bp0.init_speed=10G               # CPU 背板 10G
npu0.bp0.port0=0:0 / port1=1:0        # 背板两端
npu0.phy4.pin.tx_disable=gpio:1:7     # SFP 控制脚
npu0.phy4.pin.rx_los=gpio:1:1
npu0.phy4.pin.tx_fault=gpio:1:2
npu0.phy4.pin.present=-gpio:1:3       # 低有效
npu0.phy4.MVL6193LEDcontrol=0xe1      # RJ45 的是 0xe3
npu0.eth0..3.port=1:1 .. 1:4          # 面板 1-4 = 交换机 port 1-4
npu0.sff.event=phys:1:4
```

**重要推论**：10 Gbps SFP **不是原厂支持的配置**（`init_speed=1G`），是我们额外做出来的；
但硬件（SerDes + 模块 + 交换机 PCS）确实支持，见 12.11。

---

## 12.15 同平台参考项目（重要情报）

<https://github.com/nicologiuliani6/openwrt-sophos-xgs107> —— **XGS 87/107 桌面机，同一块 PCB（丝印 1.40）**：

| 项目事实 | 对我们的意义 |
|---|---|
| 目标板 `sophos,xgs107w-npu`，DTS `cn9130-sophos-xgs107w`，`kmod-dsa-mv88e6xxx` | 直接给出这块板的 mainline 设备树方向 |
| mainline 6.x 内核，用 `mv88e6xxx` DSA 驱动交换机 | **替代** U-Boot 寄存器初始化，二层才可控（含 SerDes/10G） |
| CPU 口在 DTS 里是 `10gbase-r`（我们是 `10gbase-kr`） | 说明 CPU 链路可以不用 in-band AN |
| NPU↔x86 用 PCIe NTB（`pci-epf-vntb` + `ntb_netdev`），不用 Sophos 私有数据面 | 摆脱 `usfp`/host 握手依赖 |
| SFP 笼在他们那边**未测**（"untested (no module)"） | 我们的 10G 结论是新的、可反馈上游 |
| 他们的 U-Boot env 里也有 `sw_init_p0..p3`（与本机一致） | 交叉验证：原厂初始化流程确认无误 |
| 备份/恢复文档：`bootcmd_emmc3` 永远能回原厂槽 p3；SPI U-Boot 永不写 | 刷机风险可控 |

我们的适配路线因此非常明确：**不自研交换机驱动，直接用 mainline 内核 + 这块板的 DTS**。
（这条路线已经走完了 —— 只不过落地系统是 Debian 而不是 OpenWrt，见 [16](../16-remaining-work.md)。）

---

## 12.16 10G SFP 的 mainline 支持情况（查源码得出结论）

### 这块板的 DTS 已经进 mainline 了

`arch/arm64/boot/dts/marvell/cn9130-sophos-xgs107w.dts`（compatible `sophos,xgs107w-npu`），内容与参考仓库一致，关键片段：

```dts
&cp0_eth0 {                                   /* CPU 口 → 交换机 port 0 */
	phy-mode = "10gbase-r";
	phys = <&cp0_comphy4 0>;
	managed = "in-band-status";
};

&cp0_mdio {
	switch@2 {
		compatible = "marvell,mv88e6190";
		reg = <2>;
		reset-gpios = <&cp0_gpio2 17 GPIO_ACTIVE_LOW>;   /* 就是我们实测的 C17 */
		port@0 { ethernet = <&cp0_eth0>; phy-mode = "10gbase-r"; managed = "in-band-status"; };
		port@1..8 { label = "p1".."p8"; };               /* 内置 PHY */
		port@9 {                                         /* SFP 笼 F1 */
			phy-mode = "1000base-x";                     /* ← 只声明到 1G */
			managed = "in-band-status";
			sfp = <&sfp>;
		};
	};
};
```

### 6193X 在 mainline 里是被支持的

`drivers/net/dsa/mv88e6xxx/chip.c`（mainline）：

```c
static const struct mv88e6xxx_ops mv88e6191x_ops = {
	/* MV88E6XXX_FAMILY_6393 without AVB and PTP: 6191X and 6193X */
	...
	.port_set_cmode = mv88e6393x_port_set_cmode,
	.serdes_get_lane = mv88e6393x_serdes_get_lane,
	.phylink_get_caps = mv88e6393x_phylink_get_caps,
	.pcs_ops = &mv88e6393x_pcs_ops,
};
...
[MV88E6193X] = { ... .ops = &mv88e6191x_ops, },   /* 不再 .ptp_support = true */
```

这张表本来只在参考项目的 `950-net-dsa-mv88e6xxx-6191x-6193x-no-ptp.patch` 里，
**现在已经在 mainline 了**。之前 6193X 会 probe 失败并报
`unexpected cycle counter period of 0 ps` —— 就是它没有 PTP/AVB 单元导致的。

### 0xD 就是 mainline 的 10GBASE-R 编码（我们手写对了，但只对了一半）

`drivers/net/dsa/mv88e6xxx/port.h`：

```c
#define MV88E6XXX_PORT_STS_CMODE_XAUI       0x000c
#define MV88E6XXX_PORT_STS_CMODE_RXAUI      0x000d
#define MV88E6393X_PORT_STS_CMODE_5GBASER   0x000c
#define MV88E6393X_PORT_STS_CMODE_10GBASER  0x000d   /* ← 我们写的 0xD */
#define MV88E6393X_PORT_STS_CMODE_USXGMII   0x000e
```

`port.c`：

```c
case PHY_INTERFACE_MODE_10GBASER:
	cmode = MV88E6393X_PORT_STS_CMODE_10GBASER;   /* 0x0d */
	break;
```

`pcs-639x.c` 里也明确处理 `PHY_INTERFACE_MODE_10GBASER` / `RXAUI` / `XAUI`。

**所以 10 Gbps 是这代芯片被驱动支持的速率**，我们手写 CMODE=0xD 后 PCS 也能锁定
（`0x0F4D` 就是证据）。之所以"链路 UP 但整机不转发"，是因为驱动除了写 CMODE，
还要成对地配置 SerDes lane、端口 MAC 速率和 PCS（`mv88e6393x_port_set_cmode`
→ `mv88e6393x_serdes_power` → `pcs-639x.c`），我们只做了三分之一。

### 结论：要 10G，只需要一处 DTS 改动

把 mainline DTS 里 port@9 的

```dts
phy-mode = "1000base-x";
```

改成

```dts
phy-mode = "10gbase-r";
```

（或者干脆删掉 `phy-mode`/`managed`，让 `sfp` 节点 + phylink 按模块能力自动选，
10GBASE-SR 模块会协商到 10GBASE-R。）

然后由 mainline 的 `mv88e6xxx` + phylink 按正确顺序把 port 9 带起来：
CMODE 写 0xD、SerDes lane 9 上电、PCS 配 10GBASE-R、端口 MAC 速率同步 ——
这才是"链路上 + 能转发"的完整状态。

### 仍未验证的部分（要上机才知道）

- 6193X 的两条 SerDes lane（port 0 和 port 9）能否**同时**跑 10G（共享 PLL/DFE 资源）。
- `managed = "in-band-status"` 对 10GBASE-R（无 AN）是否合适，还是应该交给 phylink 轮询 PCS。
- 88E6193X 的 port 9 在 10G 下的流控/DFE 是否需要额外的微调（mainline 无板级特调）。

这些都要等 NPU 换上带 DSA 驱动的内核后实测 —— 这正是下一步。
