# 19 后续改动方案：换模块 vs 重编内核

> 🏷 **状态（2026-11-23 复核）**：✅ **结论已复核**：mvpp2/mv88e6xxx 确实都是模块、确实不用重编内核；风扇一节已更正为"有风扇但软件不可控"。

## 19.1 关键结论：这次不需要重编内核

原以为 TCAM 修复和 `MVPP2_AGGR_TXQ_SIZE` 都要重编内核，查了 Debian 的实际配置后发现**都是模块**：

| 目标改动 | 源码位置 | Debian 配置 | 实际需要的动作 |
|---|---|---|---|
| mv88e6xxx TCAM 越权修复（`e3624f5eeac4` + `242ebf4c5114`） | `drivers/net/dsa/mv88e6xxx/` | `CONFIG_NET_DSA_MV88E6XXX=m` | 重建 **`mv88e6xxx.ko`** |
| `MVPP2_AGGR_TXQ_SIZE` 256 → 512 | `drivers/net/ethernet/marvell/mvpp2/mvpp2.h` | `CONFIG_MVPP2=m` | 重建 **`mvpp2.ko`** |
| cpufreq（OPP）+ thermal 降频 | `drivers/cpufreq/armada-8k-cpufreq.c`、`drivers/clk/mvebu/ap-cpu-clk.c` | 两个都**没编** | 新建两个模块（`ap-cpu-clk` 目前段错误，待修） |
| safexcel 8 ring / MUSDK SAM | `drivers/crypto/inside-secure/` | `=m` | 大工程，见 docs/18 §18.5 |

顺带确认：`CONFIG_ARMADA_THERMAL=m`、`CONFIG_CPU_THERMAL=y`、`CONFIG_THERMAL_GOV_STEP_WISE=y`
—— 也就是说**热管理的框架是齐的**，缺的只有"能降频的 cooling device"。

## 19.2 风险：换模块可能失联

`mv88e6xxx.ko` 和 `mvpp2.ko` 是 DSA 的底座：

```
cp0_eth0 (mvpp2) ──► 88E6193X (mv88e6xxx) ──► p1…p8 / sfp
```

任何一个换错 → 交换机 probe 失败 → `end0`/`p1…p8` 全消失 → **SSH 立刻断**，
而 **NPU 没有可用串口**（COM5 是 x86 的 ttyS0），只能断电重启赌一把。

所以顺序必须是：**先有串口，再动模块。**

## 19.3 串口：动手前的唯一前置条件

现状证据：

| 事实 | 出处 |
|---|---|
| COM5 = x86 的 `ttyS0`（I/O 0x3f8，`console=ttyS0,115200n8`） | x86 dmesg |
| NPU 的 console 是它自己的 `serial0`（`stdout-path`、`bootargs console=ttyS0`） | 原厂 DTB / U-Boot env |
| 两边不是同一根线（否则两个 TX 会互相打架，我们看到的输出不会这么干净） | 实测 |
| x86 的 ttyS1/ttyS2/ttyS3 都探测过，全静默 | 实测 |

可选方案：

- **A（推荐）**：机箱内找 CN9130 小板上的 UART 排针，接一个 3.3 V USB-TTL（只接 GND/TX/RX，**不要接 VCC**），
  插到电脑上就是一条独立的 NPU 控制台。
- **B**：确认面板上那个 RJ45 console 是否有跳线/复用开关可以切到 NPU。

在拿到串口之前，**任何会改变网络模块的操作都不做**。

## 19.4 不需要串口、现在就能做的

| 项 | 命令 | 风险 |
|---|---|---|
| mvpp2 ring 加大 | `ethtool -G end0 rx 2048 tx 2048` | 无（可回退） |
| 复测吞吐验证 ring 效果 | `iperf3` 4 流 | 无 |
| 打通 NTB（另一个方向，不碰交换机） | 见 docs/17 + U 盘 `ntb-x86/` | 无（只影响新增的 ntb0） |
| 整理 PCIe EP 的上游补丁 | 文档工作 | 无 |

## 19.5 串口就位后的执行顺序

```sh
# 1. 备份原厂模块（在设备上）
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/dsa/mv88e6xxx.ko /root/backup/
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/marvell/mvpp2/mvpp2.ko /root/backup/

# 2. 用新模块覆盖 + depmod
# 3. 重启（不要热换：DSA 卸载/重装会让已创建的 netdev 处于不一致状态）
reboot

# 4. 起来后验证
ip -br link            # p1…p8、end0 都在
ethtool -i end0 | grep version
ip -d link show end0 | grep -o 'tx-queue-len [0-9]*'
```

失败时（串口可用）：

```sh
cp /root/backup/mv88e6xxx.ko /lib/modules/$(uname -r)/kernel/drivers/net/dsa/
cp /root/backup/mvpp2.ko    /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/marvell/mvpp2/
depmod -a && reboot
```

## 19.6 关于风扇（同日结论）

**先说结论：这台机器是有风扇的**（整机一颗，上电就转，不存在"fanless"版本）。
下面的表格讲的是**为什么软件控制不了它**，不是"没有风扇"。早前文档里写成"无风扇/被动散热"是错的，已更正。

| 侧 | 能力 | 原厂是否使用 |
|---|---|---|
| NPU | 有 3 个 PWM 控制器：AP GPIO（20 路）、CP0 GPIO1（32 路）、CP0 GPIO2（31 路） | **没有**：原厂 DTB 里没有任何 `fan`/`pwm` 节点，rootfs 里也没有 `fancontrol`/`pwmfan`/相关 unit，只有 `xgs-cpss-temperature`、`xgs-dimm-temperature`、`xgs-phy-temperature` 三个测温小工具 |
| x86 | 无：没有 SuperIO 风扇控制器（`nct6775`/`it87` 加载后不产生 hwmon），ACPI 里没有风扇设备，**连 thermal zone 都没有** | 不适用 |

结论：**软件层面两边都没在控风扇。** 风扇要么是**定速常转**，要么由**板载硬件温控**（模拟电路/热敏电阻）自行调节。
要接管它，必须先量出风扇 PWM/TACH 接在哪根 MPP 上（需要原理图或逐个试），**在没有串口兜底前不建议试**。
