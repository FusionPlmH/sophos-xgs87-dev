# 14 — NPU 跑 Debian：硬件完成度与驱动补齐

> 本文记录把 NPU（Marvell CN9130）从原厂 Buildroot 换成 **Debian 13 (trixie, kernel 6.12.117+deb13-arm64)**
> 之后，逐个子系统把驱动/固件补齐的全过程。所有结论均来自实机验证。
>
> 目标是让这颗 NPU 成为一台可用的路由/交换节点：**8×1G + 1×SFP+ 10G 全部工作**。

---

## 14.1 最终完成度

| 子系统 | 状态 | 说明 |
|---|---|---|
| 交换芯片 88E6193X | ✅ | mainline `mv88e6xxx` DSA，p1–p8 + sfp 全部生成 |
| CPU 口 10G（mvpp2 ↔ port0） | ✅ | `end0`，10Gbps/Full inband |
| **SFP+ 10G（port 9）** | ✅ | **10000baseSR/Full，实链路，DHCP + WAN 通** |
| 8× RJ45 1G | ✅ | 每口独立 PHY（`mv88e6xxx-0:01..08`）|
| SFP 模块识别 | ✅ | `sfp` hwmon + `ethtool -m` 读 DDM |
| eMMC | ✅ | `sdhci-xenon`，p2 = Debian |
| **SPI NOR / MTD** | ✅ | 自建 `spi-orion.ko`，`/proc/mtd` 出现 |
| **U-Boot 环境读写** | ✅ | `fw_printenv` / `fw_setenv` 可用 |
| RTC | ✅ | `armada38x-rtc f2284000.rtc` |
| 温度监控 | ✅ | SFP 模块 + 8 个 PHY（`hwmon0..8`）|
| 看门狗 | ✅ | SBSA Generic Watchdog，`/dev/watchdog` |
| I2C | ✅ | `cp0_i2c1`，SFP cage EEPROM |
| 加密引擎 EIP197 | ⚠️ **不启用** | 见 14.4；结论是**不需要** |
| USB / SATA | — | 板上未引出，不追 |

---

## 14.2 SFP+ 10G：根因与修复

### 症状

SFP 模块被识别，但端口创建失败：

```
sfp (uninitialized): switched to inband/10gbase-r link mode
sfp (uninitialized): validation of 10gbase-r with support
    00,00000000,00000000,00006280 and advertisement
    00,00000000,00000000,00002280 failed: -EINVAL
sfp (uninitialized): failed to connect to PHY: -EINVAL
error -22 setting up PHY for tree 0, switch 0, port 9
```

### 根因（与内核版本、`reset-gpios` 全都无关）

掩码 `0x6280` 解出来是 `TP|MII|FIBRE|Pause|Asym_Pause` —— **一个速率位都没有**。
这是「一个能力为空的 PHY」的指纹。链条是：

1. DTS 的 `port@9` **缺 `managed = "in-band-status"`**，phylink 推断出
   `cfg_link_an_mode = MLO_AN_PHY`（以为是接 PHY 的口）。
2. `phylink_fwnode_phy_connect()` 用 `fwnode_get_phy_node()` 找 PHY，而它只认
   `phy-handle` / `phy` / `phy-device` 三个属性 —— port@9 一个都没有 → 返回 `-ENODEV`。
3. DSA 的 `dsa_user_phy_setup()` 在 `-ENODEV` 时**回退到交换机内部 MDIO 总线**
   去找地址 `dp->index` = **9** 的 PHY。
4. 88E6193X 的 SerDes 在内部 MDIO 上确实以地址 9/10 出现，但那是**假 PHY**：

   ```
   /sys/bus/mdio_bus/devices/mv88e6xxx-0:09
     DEVTYPE=PHY   phy_id=0x00000393   （无驱动绑定）
   /sys/bus/mdio_bus/devices/mv88e6xxx-0:0a
     DEVTYPE=PHY   phy_id=0x00000393
   ```

   对比真 PHY（地址 8）：`phy_id=0x002b0b9b`，驱动 `Marvell 88E6393 Family`。
5. 假 PHY 没有 abilities → `supported` 掩码为空 → 10GBASE-R 校验 `-EINVAL`。

### 修复：一行 DTS

```dts
port@9 {
	reg = <9>;
	label = "sfp";
	phy-mode = "10gbase-r";
	managed = "in-band-status";   /* ← 关键：让 phylink 走 inband，不去找 PHY */
	sfp = <&sfp>;
};
```

> 上游 `cn9130-sophos-xgs107w.dts` 本来就有这一行（port@9 = `1000base-x` + `managed`）。
> 本地改写 DTS 时漏掉了，是这次踩坑的唯一原因。

### 验证

```
dmesg:  mv88e6085 ...:02 sfp: configuring for inband/10gbase-r link mode
        mv88e6085 ...:02 sfp: Link is Up - 10Gbps/Full - flow control off

ethtool sfp:
  Supported link modes:   10000baseSR/Full
  Speed: 10000Mb/s    Duplex: Full    Link detected: yes

ethtool -m sfp:
  Vendor: Hisense LTF8502-BC+   10G Base-SR   850nm
  Receiver signal average optical power: 0.5548 mW / -2.56 dBm   ← 对端真的有光
  Laser output power: 0.6015 mW / -2.21 dBm
```

收光 -2.56 dBm 证明是真实对端而非自环。随后 `dhcpcd sfp` 从家用路由器拿到
`192.168.0.54/24`，ping 网关 0% 丢包 0.55 ms，ping WAN 0% 丢包 55 ms。

---

## 14.3 SPI NOR / MTD / U-Boot 环境

### 症状

`/proc/mtd` 为空，`fw_printenv` 不可用 —— **其实 SPI 控制器根本没被驱动**。

### 根因

Debian 的 arm64 内核**没有编 `CONFIG_SPI_ORION`**（CP115 的 SPI 控制器驱动，
`compatible = "marvell,armada-380-spi"`）。配置里只有 `CONFIG_SPI_ARMADA_3700`
—— 那是另一颗 SoC（Armada 3700 / ESPRESSObin）。所以 DTS 里 `&cp0_spi0` 再
`okay` 也没有驱动去 probe。

### 修复：外部编译 `spi-orion.ko`

```bash
# WSL 的 Debian 13 arm64 chroot 里
apt-get install linux-headers-6.12.117+deb13-arm64 build-essential
cp <linux-source-6.12.117>/drivers/spi/spi-orion.c  $B/
echo 'obj-m := spi-orion.o' > $B/Makefile
make -C /usr/src/linux-headers-6.12.117+deb13-arm64 M=$B modules
```

装到 `/lib/modules/6.12.117+deb13-arm64/extra/`，`depmod -a`，并在
`/etc/modules-load.d/xgs87-hardware.conf` 里登记，开机自动加载。

### 结果

```
mtd0: 003f0000 00001000 "u-boot"
mtd1: 00010000 00001000 "u-boot-env"
```

`/etc/fw_env.config`：

```
/dev/mtd1 0x0000 0x10000 0x1000 1
```

之后 `fw_printenv` 直接可读 —— 这解锁了**从 Linux 改写 U-Boot 变量**的能力
（不必再抢串口进 U-Boot 控制台）。

### 顺带读到原厂的性能调优

```
bootargs_emmc3=... root=/dev/mmcblk0p3 pci=pcie_bus_safe cpuidle.off=1 \
               isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3
```

**原厂把 CPU 1–3 整个隔离出来专供数据面**（`isolcpus` + `nohz_full` + `rcu_nocbs`），
并关掉 cpuidle 省电以降低唤醒延迟。这是"这台机器怎么做高性能转发"的官方答案：
数据面在固定核上跑，控制面挤在 CPU0。

---

## 14.4 加密引擎 EIP197：查清了，但**不需要**

### 硬件在，驱动也认出来了

```
crypto-safexcel f2800000.crypto: EIP197:241(0,1,4,4)-HIA:230(2,6,6),PE:133/332(alg:7ffdf000)/143/0/0
crypto-safexcel f2800000.crypto: TRC init: 15360d,80a (48r,256h)
```

DTS：`marvell,armada-cp110-crypto` + `inside-secure,safexcel-eip197b`；
另有 `trng@760000`（`safexcel-eip76`）由 `omap_rng` 驱动，正常。

### 问题一：缺固件（已解决）

驱动要 `ifpp.bin` + `ipue.bin`。Debian 不打包（`apt` 里搜不到任何相关包）。

| 来源 | `ifpp.bin` | `ipue.bin` |
|---|---|---|
| `maxlinear/eip197-firmware`（GitHub） | 13300 B | 6664 B |
| **原厂 rootfs `/usr/lib/firmware/inside-secure/eip197b/`** | **12272 B** | **4080 B** |

两者 SHA256 不同 —— **不是同一个 build**。已采用原厂那份（也就是这颗芯片出厂配套的）。

### 问题二：时钟被关（已解决）

```
f2440000-eip197  enable_cnt=0  HW_enable=N  deviceless     ← 被 clk_disable_unused() 关掉
f2440000-eip150  enable_cnt=1  HW_enable=Y  f2760000.trng  ← TRNG 占着所以活着
```

root cause：`drivers/clk/mvebu/cp110-system-controller.c` 里

```c
#define CP110_GATE_EIP197   26
static unsigned long gate_flags(const u8 bit_idx)
{
	switch (bit_idx) {
	case CP110_GATE_PCIE_X1_0: ... return CLK_IGNORE_UNUSED;  /* 只有 PCIe 有保护 */
	default: return 0;
	}
}
```

EIP197 没有 `CLK_IGNORE_UNUSED`，又没有任何驱动去 `clk_prepare_enable()` 它
（**safexcel 驱动完全不碰时钟**），于是开机 `late_initcall` 就被门控关掉，PE 自然起不来。

修法：`clkfix.ko`（本仓库源码，`files/clkfix.c`）——不绑定设备，只在模块 init 时
`of_find_compatible_node()` 找到 crypto 节点，`of_clk_get_by_name("core"/"reg")`
并 `clk_prepare_enable()`。加载后：

```
f2440000-eip197  1  1  0  500000000  ...  Y  crypto@800000  core
```

### 问题三：IFPP 微码仍起不来（未解决，但**不需要解决**）

即便固件对、时钟在，仍然：

```
crypto-safexcel f2800000.crypto: FW(1) for PE 0 failed to start
```

即 `poll_fw_ready(FPP)` 等不到 `UENG_INIT_STATUS`。这是 EIP197 PE 编程在
CN9130 上的适配问题，不是配置错误。

**关键证据：原厂自己也没用内核 safexcel。** 原厂 rootfs 里是：

```
/usr/bin/musdk_sam_ipsec   musdk_sam_ssltls   musdk_sam_kat   musdk_sam_single
lib/modules/.../extra/mv_sam_uio.ko
DT: uio_sam@800000 { compatible = "marvell,uio-sam"; eip_access = <&crypto>; }
```

即 **MUSDK SAM 走用户态 UIO 直接驱动加密单元**，完全绕过内核 crypto API。
（原厂内核是 4.14.207 OCTEONTX2 BSP。）

### 为什么可以不去追：实测软件加密已经够快

```
openssl speed -evp aes-256-gcm   (单核, ARMv8 Crypto Extensions)
  8192 B : 999,961 KB/s  ≈ 8.0 Gbps
 16384 B : 1,060,716 KB/s ≈ 8.5 Gbps

openssl speed -evp aes-128-gcm
 16384 B : 1,246,391 KB/s ≈ 10.0 Gbps
```

**单核 AES-256-GCM 就有 8.5 Gbps**，而整机 L3 转发上限只有 2–4 Gbps
（`mv88e6xxx` 没有路由硬件卸载，每个包都要 CPU 处理）。
加密永远不会是先到的瓶颈 —— 硬件卸载对这台机器**没有收益**。

> 结论：EIP197 保持不启用。若将来真要用，正确路径是复刻原厂的 MUSDK SAM
> （用户态数据面），而不是修内核 safexcel。

---

## 14.5 厂家 BSP vs 上游：逐子系统补丁对比

对 `MarvellEmbeddedProcessors/linux-marvell` 分支 `linux-6.12.x-release`
（tag `linux-6.12.x-release-v26.10`）做 `git log v6.12.51..HEAD`：

**厂家独有提交：1467 个**，但分布极度倾斜：

| 子系统 | 厂家补丁数 | 对我们的意义 |
|---|---|---|
| `drivers/net/ethernet/marvell/octeontx2` | **657** | ❌ CN10K/CN20K，不是 CN9130 |
| `drivers/net/dsa/mv88e6xxx` | **0** | 与上游逐字节相同 |
| `drivers/net/phy` | **0** | — |
| `drivers/net/sfp.c` | **0** | — |
| `drivers/phy/marvell`（comphy/SerDes） | **0** | — |
| `drivers/mmc/host/sdhci-xenon` | **0** | — |
| `drivers/crypto/inside-secure` | **0** | 我们不用的那块 |
| `net/core` / `net/ipv4` / `net/netfilter` | **0** | 转发路径无优化 |
| `drivers/net/ethernet/marvell/mvpp2` | **3** | ✅ 唯一有价值 |
| `arch/arm64/boot/dts/marvell` | 8 | 厂家自家 DB 板 |
| `drivers/i2c/busses/i2c-octeon-core.c` | 14 | 10-bit 寻址等 |
| `drivers/spi/spi-cadence-xspi.c` | 44 | CN20K xSPI |

### 唯一值得 cherry-pick 的 3 个 mvpp2 补丁

| commit | 内容 |
|---|---|
| `e609976de1f5` | `net: mvpp2: Add MUSDK support` —— 端口可在 MUSDK 模式下交给用户态，内核仍管 phylink/GOP |
| `88f8fd51d7dd` | `net: mvpp2: add MUSDK UIO registration in the in-tree driver` —— 直接注册 UIO 暴露 PPv2 内存，去掉 `mv_pp_uio` 外部模块依赖 |
| `0c0750ebbe4d` | `net: mvpp2: Add override_percpu_pools module parameter` —— MUSDK 模式下强制共享 BM pool |

**但要注意**：MUSDK/VPP 只能看到 **PP2 的一个 10G CPU 口（`end0`）**，看不到
8 个 RJ45 和 SFP —— 那些在 88E6193X 后面。所以 VPP 方案要把交换机当哑交换机、
所有流量挤进 10G 单链路、全部在软件里转发，**反而不如现在的硬件 DSA 交换**。

### 结论

**继续用 Debian 的 6.12.117，不换 BSP。** 理由：

1. BSP 基线是 **6.12.51**，比 Debian 落后 66 个 stable 版本（安全/bugfix 全缺）。
2. 对这块硬件的驱动补丁是 **0**（mv88e6xxx / phy / sfp / comphy / mmc 全是 0）。
3. 唯一增量（MUSDK）是可选特性，且对本机的交换架构不划算。
4. 厂家对 **CN9K 的真正增值不在内核**，而在 `MarvellEmbeddedProcessors/packages`
   的 `ubuntu-24.04-cn9k` 仓库：`cpt-firmware-cn9k`、`dpdk-24.11-cn9k`、
   `vpp-24.02.0-cn9k`、`openssl-engine-cn9k` —— 全是 MUSDK/DPDK 用户态栈。

---

## 14.6 10G SFP 与铜口 1G 能否共存？——能，实测无误

有人担心"SFP 跑 10G 会把铜口压到 100M"。**实测证伪。**

同一台设备、同一批对端，只切换 SFP 状态（`ip link set sfp down/up`）：

| 状态 | SFP | p1 (→PC) | p4 (→路由器) |
|---|---|---|---|
| A: SFP UP | **10000 Mb/s** | 1000/Full | 1000/Full |
| B: SFP DOWN | down | 1000/Full | 1000/Full |
| C: SFP UP | **10000 Mb/s** | 1000/Full | 1000/Full |

三次一致，**没有任何耦合**。88E6193X 的 8 个 10/100/1000 PHY 与 3 条
SerDes（port 0 / 9 / 10）互不影响。本机 port 0（CPU 口）从开机起就是
10GBASE-R，SFP 是 74 秒后才起来的，时间线上也不成立。

### 之前看到 100Mbps 的两个真实原因

1. **DSA 端口不 `ip link set pN up` 就不会拉起 PHY** —— p4 从来没被 up 过，
   所以一直是 `down`，看起来像"没协商"。
2. `ethtool` 的 `Link partner advertised link modes` 是多行输出，
   用 `grep -A1` 会截断掉 `1000baseT/Full` 那一行，造成误判。

### 修复：开机自动 up 全部端口

```ini
# /etc/systemd/system/xgs-ports-up.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8; do ip link set p$i up; done'
```

之后插线即按最高速率协商（p1/p4 实测 1000/Full，SFP 同时 10000/Full）。

---

## 14.7 原厂的 CPU 隔离参数：对内核转发**有害**，已回退

原厂 bootargs 带 `cpuidle.off=1 isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3`。
在 NPU 上用 netns + veth 构造 `发起 → NPU 转发 → 接收` 路径实测（关掉全部
offload，避免 GSO/GRO 放大）：

| 配置 | TCP 4 流 | 加 NAT + conntrack | 64B ping RTT |
|---|---|---|---|
| **基线（默认，全部 4 核）** | **4.74 – 4.81 Gbps** | **3.48 – 3.81 Gbps** | 18 µs / 25 µs |
| 原厂隔离参数 | 1.67 Gbps | 1.29 Gbps | 18 µs |
| 原厂隔离 + 绑核 1-3 | 1.60 Gbps | 1.11 Gbps | 17 µs |

**隔离让转发吞吐掉了约 65%。** 原因很清楚：原厂是把 CPU 1-3 留给**用户态
MUSDK 数据面**独占的，控制面挤在 CPU0；而我们的转发完全由内核在
softirq 里做，需要全部 4 个核参与。隔离反而把它们从调度器里摘走了。

结论：**保持 Debian 默认 bootargs**（已回退）。除非将来真的上 VPP/MUSDK
用户态数据面，才需要那套参数。

> 测量口径说明：veth 没有网卡 DMA/中断开销，所以这些数字是**软件转发路径
> 的上界**。真实链路的天花板由端口速率决定（铜口 1G / SFP 10G）。

---

## 14.8 与 Sophos 官方标称的对比

厂商数字是**整机**（x86 跑防火墙逻辑 + NPU 做快通道卸载），我们是**全部
在 NPU 的 4×A72 上软件完成**，不是同一赛道，但可以做量级对照：

| 指标 | Sophos XGS 87(w) 标称 | 本研究实测 / 推算 | 判定 |
|---|---|---|---|
| Firewall throughput | 3,700 Mbps | **3,480 – 4,810 Mbps** | ✅ 持平或更高* |
| Firewall latency (64B UDP) | 6 µs | 18 – 25 µs** | ⚠️ 口径不同，不可比 |
| IPsec VPN | 750 Mbps | 单核 AES-256-GCM 8.5 Gbps → 实作预计 **1.5 – 3 Gbps** | ✅ 更高 |
| IPS throughput | 1,015 Mbps | 无对应软件 | ❌ 不具备 |
| Threat Protection | 240 Mbps | 无对应软件 | ❌ 不具备 |
| Concurrent connections | 1,600,000 | conntrack 约 300–400 B/条 → 需 ~600 MB（本机 1.9 GB）| ⚠️ 可行但吃紧 |
| TLS inspection | 375 Mbps | 无对应软件 | ❌ 不具备 |
| SFP 端口速率 | 1G（上游 DTS `1000base-x`） | **10G 实测链路** | ✅ 超出 |

\* 软件转发上界；真实链路受端口速率限制（铜口 1G × 8，SFP 10G）。
\** veth 往返含 2 次软件收包，非端口到端口延迟。

**一句话**：做纯路由器/防火墙（L3 转发 + NAT + IPsec），这台 Debian
**不输反超**；做 UTM（IPS/威胁防护/TLS 解密），需要另装 Suricata 一类
软件，那部分本机没有对应能力。

---

## 14.9 复现清单

```bash
# 1. DTB：port@9 必须带 managed = "in-band-status"
#    见 files/cn9130-sophos-xgs87w-sfp10g.dts

# 2. EIP197 固件（可选，见 14.4）
mkdir -p /lib/firmware/inside-secure/eip197b
# 从原厂 rootfs 取 ifpp.bin / ipue.bin

# 3. 自建模块
#    clkfix.ko      保持 EIP197 时钟开启
#    spi-orion.ko   驱动 SPI NOR，暴露 /proc/mtd
cp *.ko /lib/modules/$(uname -r)/extra/ && depmod -a
cat > /etc/modules-load.d/xgs87-hardware.conf <<EOF
spi-orion
clkfix
EOF

# 4. U-Boot 环境访问
cat > /etc/fw_env.config <<EOF
/dev/mtd1 0x0000 0x10000 0x1000 1
EOF
fw_printenv

# 5. 拉起 SFP+ 10G
ip link set sfp up
ethtool sfp | grep -E 'Speed|Link detected'
```
