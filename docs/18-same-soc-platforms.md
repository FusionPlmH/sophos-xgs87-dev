# 18 同族平台调研：能抄什么、不能抄什么

对 CN913x / Armada-8K 家族的公开源码做了一轮系统调研（4 个方向并行：SolidRun+Armbian+OpenWrt、
MikroTik+QNAP+IEI 等整机厂、Marvell MUSDK+EVK、FreeBSD+主线提交历史）。

本文只记录**能落到本机（Sophos XGS 87：CN9130 + 88E6193X + PCIe EP 到 x86）的结论**，每条都注明置信度和
是否已在本机验证。

---

## 18.1 我们已经领先上游的地方

| 项 | 上游 | 我们 |
|---|---|---|
| SFP+ 速率 | 主线 `cn9130-sophos-xgs107w.dts` 把 port 9 钉死 `phy-mode = "1000base-x"`，作者在 commit 里自己写 *"The SFP cage is untested"* | 实测 **10GBASE-R / 10 Gbps** 跑通（去掉 `phy-mode`、用 `managed = "in-band-status"`） |
| 每口 MAC | 主线 DTS 没有 | `xgs-ports-init.sh` 按 label+0…+8 分配，已验证 |
| SPI NOR env | 主线把 `u-boot-env` 也设成 `read-only` | env 分区可写，`fw_setenv` 可用 |
| 管理口 | 无 | `br-mgmt` + p8，开机持久化 |
| PCIe EP | **上游完全没有** Armada EP glue（见 18.4） | `snps,dw-pcie-ep` 跑通，端点已对 x86 呈现 `1957:0809` |

上游 Sophos DTS 是 **v7.3** 才进主线的（`0f72e965efec`，作者与 openwrt-xgs107 同一人）。值得把它和我们
的 DTS 做一次 diff —— 特别是它给了 `switch@2 { reset-gpios = <&cp0_gpio2 17 GPIO_ACTIVE_LOW>; }`
（我们故意省略，因为重置会清掉 port 9 的 10GBASE-R 配置）。

---

## 18.2 必须知道的两个 mv88e6xxx 事实

### (a) 6.12.117 上 6193X 的 PTP 是"假的"——但不要单独 backport 修复

- 上游 `6b491af01aa5`（v7.3）：*"88E6191X and 88E6193X have no PTP … the whole indirect AVB
  register space reads zero … Tested on an 88E6193X (Sophos XGS 107w)"*。
- 但触发 probe 失败的是 `7e3c18097a70`（**v6.13** 才引入，`linux-6.12.y` **没有**）。
- **结论：我们现在能正常 probe，是因为触发补丁不在 6.12.y。**
  - 千万别只 backport `7e3c18097a70` —— 那会让 6193X **probe 失败**（`unexpected cycle counter period of 0 ps`）。
  - 将来升到 ≥6.13 时，必须同时带上 `6b491af01aa5`。
  - 现状副作用：内核给这颗芯片注册了 PHC，但 AVB 寄存器全读 0 → PTP 时间戳是垃圾。不用 PTP 就无害。

### (b) 两个 TCAM 策略越权修复不在 6.12.y，且影响我们

- `e3624f5eeac4`（`mv88e6xxx_get_rxnfc()`：`if (policy)` → `if (policy && policy->port == port)`）
  和配套的 `242ebf4c5114`（删规则）。
- 原文：*"lets a user on one user port read the MAC address and VID of a policy an admin installed on
  another. ETHTOOL_GRXCLSRULE needs no CAP_NET_ADMIN."*
- 6193X 有 `tcam_ops`，`ETHTOOL_GRXCLSRULE` 路径存在 → **真实可用于本机的安全漏洞**。

---

## 18.3 mvpp2：能动的三个旋钮

| 项 | 说明 |
|---|---|
| `MVPP2_AGGR_TXQ_SIZE` | MikroTik 的 GPL 树里是 **512**，我们（6.12）是 256。一行改动，服务所有口的 TX 聚合队列 |
| ring 大小 | 已是 1024，**不用改内核**，`ethtool -G end0 rx 2048 tx 2048` 即可 |
| `99502c61e80c` | mvpp2 给 XLG PCS 加 `pcs_inband_caps`（10G/5G 无 in-band）；但 `pcs_inband_caps` 机制 v6.14 才进 mvpp2，**6.12 上大概率是空操作**，先不折腾 |
| 无编译的增益 | 6.12.117 已含 `fcbfb54a0269`（parser TCAM 溢出）、`14cb1e7702e5`（page_pool 越界）、`8a63baadf084`（CN9130 专属 flow-control NULL 解引用）——这些我们都已经有了 |

---

## 18.4 PCIe 端点模式的真相（对 docs/17 的补强）

1. **主线没有 Armada EP glue**：`PCIE_ARMADA_8K` 只 `select PCIE_DW_HOST`，`pcie-armada8k.c` 在
   `armada8k_pcie_host_init()` 里硬写 `PCIE_DEVICE_TYPE_RC`。其他 12 个 DW SoC 都有 `_EP` 兄弟驱动，
   **Armada-8K 是唯一缺口**。FreeBSD 同样只有 RC（`pci_dw_mv.c`）且**没有 PCI endpoint 框架**。
   → 我们走 `snps,dw-pcie-ep` 不是将就，而是唯一正路。
2. **厂商绑定与真实窗口**：`marvell,armada8k-pcie-ep`，`reg-names = "core","shadow_core","lm"`，
   偏移分别是 `+0x0`(0x4000) / `+0x4000`(0x1000) / `+0x8000`(0x80000)。
3. **`dbi2` 必须在 +0x4000**：主线 `dw_pcie_ep_set_bar()` 把 BAR **尺寸**写进 `dbi2`，而
   `dw_pcie_get_resources()` 在没有 `dbi2` 时的 fallback 是 **`dbi_base + 0x1000`** —— 在本 SoC 上是错的
   窗口（会写到 shadow 之外的地方）。我们的 DT 已正确给出 `dbi2 = <0 0xf2604000 0 0x1000>`。
4. **ATF 里 EP 模式是空实现**：`PCI_EP_SUPPORT := 0`，且 `ble_plat_pcie_ep_setup()` 在主线 TF-A 里
   **只有声明没有定义**。也就是说，我们能以 EP 身份起来，靠的是 U-Boot/厂商固件留下的控制器状态。
5. **`addr_space` 依赖 TF-A 的 IO 窗口**：`iob_memory_map_cp0[]` 里有一条
   `{0x8_0000_0000, 0x1_0000_0000, PEX0_TID}`（4 GB）。我们 DT 的 `addr_space = <0x80 0x0 …>` 就落在里面。
   **换 ATF 前必须确认这条还在**，否则 EP 的 DMA 直接死。

---

## 18.5 EIP197：为什么主线路线注定平庸

调研把结论钉死了 —— 不是调优问题，是**结构不兼容**：

| 事实 | 出处 |
|---|---|
| 主线 safexcel 最多 **4** 个 ring（`EIP197_MAX_RINGS 4`），硬件是 8；`EIP197_MAX_RING_AIC 14` 说明 AIC 远不止 4 | `drivers/crypto/inside-secure/safexcel.h` |
| 主线**没有** `rings=` 模块参数；BSP 有，`rings=0,0` 是 SAM 接管的前提 | BSP `safexcel.c` |
| `mv_sam_uio.ko` 把 `of_device_get_match_data()` 的返回值**强转成枚举**；主线返回的是 `struct safexcel_ops *` → 必得 `unknown HW type` → 0 个 UIO 设备 | `musdk-marvell/modules/sam/mv_sam_uio.c` |
| SAM 用 `HIA_CDR_BASE_ADDR_LO == 0` 判断 ring 空闲，所以 safexcel **必须**先以 `rings=0` 加载 | 同上 |
| SAM 默认 8 ring、16 包 / 100 µs 合并 | `src/drivers/sam/sam.h` |
| DT 里 `crypto@800000` 已经有 `ring0..ring3` 四个中断名 | `armada-cp11x.dtsi` |

→ **要用好 EIP197，得移植 BSP 版 safexcel（`rings=` + 枚举 match data），再接 `mv_sam_uio`。**
   这解释了为什么我们在 AF_ALG 上测到的 4.4 Gbps 天花板和"每字节 CPU 不比软件省"——那是 4 个内核 ring
   走 crypto API 的结果，不是引擎的上限。

---

## 18.6 CPU 频率：1.6 GHz 是 SAR strap，不是 Linux 限制

- AP807 上电默认跑 **ARO**（环形振荡器）；ATF 的 `CLOCKSPRESET` 才会切到 PLL 并设频：
  `PLL_FREQ_2200 0x2AC57001`、`PLL_FREQ_2500 0x2B063001`（`ap807_clocks_init.c`）。
- SAR 解码：`0x0`=2000 MHz、`0x6`=2200、`0xD`=**1600**（`ap806-system-controller.c`）—— 我们落在 0xD。
- **不存在任何 CN9130 OPP 表**：`armada-8k-cpufreq` 在 probe 时用 `clk_get_rate()/{1,2,3,4}` 现算 OPP。
  所以"在 DTS 里加 opp-hz"是错的方向。
- `ap-dclk`(1.2 GHz) 是 DDR/HCLK，**不是** CPU 时钟；CPU 是 `pll-cluster-0/1`。
- **QNAP TS-435XeU 是 CN9130 @ 2.2 GHz 量产机** → 硅片和电压没问题，2.2 GHz 可行。

**但我们不做**：改 ATF 要刷 SPI NOR 里的固件，而 NPU **没有可用串口**（COM5 是 x86 的），刷坏就报废。
收益 1.6→2.2 GHz（+37%），风险是不可恢复。除非先解决串口访问。

### cpufreq / thermal 现状（本机实测）

```
thermal zones: ap-ic, ap-cpu0..3, cp0-ic      （6 个，来自 armada-ap80x.dtsi，一直就有）
温度: AP 50.9-51.7 °C, CP0 54.2 °C
cooling devices: 无
/sys/devices/system/cpu/cpufreq/: 空
```

Debian 的 arm64 内核**没编** `CONFIG_ARM_ARMADA_8K_CPUFREQ` 和 `CONFIG_ARMADA_AP_CPU_CLK`，
所以 85/95 °C 的降频 trip 没有 cooling device 可绑（只剩 100 °C critical 关机）。

尝试 out-of-tree 补这两个模块：`armada-8k-cpufreq.ko` 编译通过；`ap-cpu-clk.ko` 需要
`of_get_cpu_hwid()`（未导出，已用本地等价函数替换）编译通过，但 **insmod 段错误**。
→ 暂缓。真要做得重编内核（或至少修 `ap-cpu-clk` 的 syscon 父时钟路径）。

---

## 18.7 不适用（省得再走一遍）

| 方向 | 结论 |
|---|---|
| **FreeBSD on NPU** | 死路：`mvpp2` 在 `freebsd-src` 里**根本不存在**，无 comphy 驱动、无 mv88e6xxx、无 PCI endpoint 框架。10G CPU 口都起不来 |
| **MikroTik CCR2004 GPL** | 只有 2022 年的 5.6.3 树；`CONFIG_NET_DSA=n`（交换是闭源）、无板级 DTS、`sfp_helper.h` 缺失 → 只有常量可抄（见 18.3） |
| **QNAP TS-435XeU** | GPL 是 399 MB tarball，镜像 7 KB/s，未取到；硬件 2.2 GHz 这一条已够用（见 18.6） |
| **IEI M901/M902、Kontron、Advantech、Portwell** | 无公开 BSP（需会员门户） |
| **Armbian** | 零 CN913x 支持 |
| **风扇/PWM 控制**（CN9132 CEX-7 的 `pwm-fan` 示例） | XGS 87 **无风扇**，不适用 |
| **U-Boot `10gbase-r` 补丁**（SolidRun，2 行） | 只有要在 SFP+ 上 netboot 才需要 |
| **SPI MISO sample delay quirk**（SolidRun CN9132） | 我们 SPI NOR 读得正常，不需要；将来若出现随机位翻转可回来看 |
| **ATF I²C 复活补丁**（SDA stuck high） | 我们的 SFP EEPROM 在 cp0_i2c1 上；真卡死时值得抄 |

---

## 18.8 行动优先级

| 优先级 | 动作 | 需要 |
|---|---|---|
| **P0** | 打 `e3624f5eeac4` + `242ebf4c5114`（TCAM 越权） | 重编内核或打补丁重建 mv88e6xxx.ko |
| **P0** | 完成 NTB：x86 侧 `ntb_hw_epf` 等 4 个模块（Debian 没编，需 out-of-tree 构建 + U 盘拷入） | Debian amd64 headers |
| **P1** | `MVPP2_AGGR_TXQ_SIZE 256 → 512` 实验 | 重编 mvpp2（内核内建，需重编内核） |
| **P1** | `ethtool -G end0 rx 2048 tx 2048` + 复测吞吐 | 无 |
| **P2** | 移植 BSP safexcel（`rings=` + 枚举）→ `mv_sam_uio` 8 ring | 大工程 |
| **P2** | 修 `ap-cpu-clk` 段错误 → cpufreq + thermal 降频 | 中等 |
| **P3** | ATF 2.2 GHz | 需要 NPU 串口兜底，否则不做 |
| **P3** | 把 PCIe EP 节点整理成上游可提交的补丁（上游 DTS 明确写 "the PCIe link to the x86 host … not described"） | 文档工作 |
