# 12 · 实测记录（把"推断"变成"测量"）

本文件记录 2026-11-22 第二轮实测：专门去验证第一版文档里标着"推断/待验证"的条目。
每条都附访问方式（串口 / SSH / U-Boot）和原始数据。

| 条目 | 结论 | 状态 |
|---|---|---|
| NPU console 走 x86 `ttyS2` | 确认 | ✅ 实测 |
| LED 由 PCA9555 驱动（参考项目说法） | **不成立**（本板 rev 07） | ✅ 实测 |
| `mvswitch dev_write` 语义 | Clause-45 间接，device 4 = SerDes/PCS | ✅ 实测 + 上游源码 |
| 交换机型号 | 88E6193（product 0x193，Amethyst/Peridot 寻址） | ✅ 实测 + 上游源码 |
| SFP 口当前模式 | **1000BASE-X**，无模块，链路 down | ✅ 实测 |
| SFP 是否支持 2.5G/10G | 未测（需要模块） | ⛔ 无模块 |
| x86 能否复位 NPU | 没有 ACPI 描述的 GPIO；候选只剩 MCP2210/硬连 | ⚠️ 部分 |
| NTB: 1 MiB BAR 对齐 / dma-coherent | 需要驱动才能验证 | ⛔ 需移植内核 |
| NTB: MSI vs MSI-X | 设备同时提供 MSI 和 MSI-X（16 向量） | ✅ 能力实测 |
| 端口 5-8 是否引出 | PHY 存在但无链路；面板只有 4 个座 | ⚠️ 部分 |

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
> "1 MiB 对齐"和"dma-coherent"两条**必须等移植内核实测**，这里不下结论。

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

> 影响：OpenWrt 移植时不要照抄那个 LED 节点；要么用 PHY 自带的 LED 控制
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
