# 09 · 改造笔记：要做什么、缺什么

> 🏷 **状态（2026-11-23）**：⚠️ 活文档 —— 每次实机验证后更新。
> 这是**唯一**的"待办 + 缺口"清单；每条都能对应到一份带证据的文档。

## 9.0 路线已经定了：两边都是 Debian

```
x86   Debian 13.6 / 6.12.94    通用计算、控制面
NPU   Debian 13.6 / 6.12.117   网络数据面（DSA + 10G 已跑通）
```

- **OpenWrt 不装了**：NPU 上原来那个 OpenWrt 已经删掉，x86 也只装 Debian。
  早期设想（"NPU 跑 OpenWrt 当路由、x86 装 OpenWrt"）**作废**，文中如遇一律以此处为准。
- 原厂 Buildroot 4.14 也已替换，只作为档案留在 [04](04-npu-system.md)。
- 两个参考项目（[openwrt-sophos-xgs107](https://github.com/nicologiuliani6/openwrt-sophos-xgs107)、
  [os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu)）现在的用途只剩两个：
  **查硬件事实**（端口映射、LED 表、MDIO 地址）和**取 DTS 片段**，不再作为系统方案。

### 为什么最终是 Debian 而不是 OpenWrt

| | Debian 13（已选） | OpenWrt（未走） |
|---|---|---|
| 交换机 / 10G | ✅ 自编 `mv88e6xxx` + `mvpp2`，9 口全在跑 | 有现成 kmod，但版本被发行版绑死 |
| 软件生态 | apt 全量（k3s、Docker、Python、编译工具链） | opkg，装通用软件麻烦 |
| x86 侧需求 | x86 要当通用服务器，本来就该是 Debian | OpenWrt x86 只能当路由 |
| 与 x86 统一 | 同一套 apt / systemd / 内核维护方式 | 两套系统两套维护方式 |
| 代价 | 自己出 DTB、自己编模块（已完成，见 [14](14-npu-debian-hardware.md)、[20](20-lan-over-vntb.md)） | 上手便宜，但长期被框架限制 |

结论：**代价已经付完了**，没有回 OpenWrt 的理由。

## 9.1 已经做完的（不用再惦记）

| 能力 | 证据文档 |
|---|---|
| 两端 Debian 自启、eMMC 整盘备份（7.28 GiB，SHA256 校验） | [07](07-storage.md)、[12](12-measurements.md) |
| 88E6193X DSA 九个 netdev（`p1–p8` + `sfp`），TCAM 两个上游修复已打 | [06](06-switch-and-ports.md)、[20](20-lan-over-vntb.md) §20.9 |
| SFP+ 实测 10000 Mb/s | [14](14-npu-debian-hardware.md) |
| `mvpp2` 自编译（`AGGR_TXQ_SIZE=512`） | [20](20-lan-over-vntb.md) §20.9 |
| SPI NOR / MTD / `fw_printenv` | [14](14-npu-debian-hardware.md) |
| EIP197 激活（能用，但比 CPU 慢，默认不启用） | [16](16-eip197-activated.md) |
| thermal 6 zone + 9 hwmon、PWM、GPIO | [01](01-hardware.md) |
| x86 ↔ NPU vNTB（1.2 Gbit/s，RTT 0.6 ms） | [17](17-x86-npu-shared-mgmt.md)、[20](20-lan-over-vntb.md) |
| 一条链路同时跑管理段 + 家里 LAN（VLAN 100 / 31），x86 拿到 DHCP | [20](20-lan-over-vntb.md) |
| 掉链 / 关机不再 oops（peer_db 校验、spad 守卫、关机道别） | [20](20-lan-over-vntb.md) §20.7 |
| 崩溃取证：netconsole 双目标（NPU → x86 + PC） | [20](20-lan-over-vntb.md) §20.8 |

## 9.2 还没做完的

### 高优先级（有明显用户价值）

| # | 事项 | 现状 / 卡在哪 |
|---|---|---|
| 1 | **`cpufreq` 不可用** | `/sys/devices/system/cpu/cpu0/cpufreq` 根本不存在；`ap-cpu-clk` 模块段错误未修。修好才能降频省电 / 看真实频率。线索见 [15](15-performance.md) |
| 2 | **x86 断 PCIe 链路 → NPU 整机复位** | 软件手段已穷尽（停 EP、关 panic、看门狗确认 inactive 都试过），判定是 SoC/ATF 对 `PERST#` 的反应。**要改 ATF 才有意义**，见 [20](20-lan-over-vntb.md) §20.8 |
| 3 | **掉链时 `ntb_transport` 的 lockup** | 现在靠 NPU 自身复位兜底。`ramoops` 这条路已证伪（每次复位都重跑 DDR scrub，保留区必被清空），改用 **netconsole 双目标**（NPU → x86 管理 VLAN + PC 的 `br-lan`），死前最后几行已经能落在磁盘上 —— 判据见 [20](20-lan-over-vntb.md) §20.8，只差一次复现 |
| 4 | **风扇不可控** | 整机一颗风扇，上电即转，温控曲线在硬件里；x86 无 SuperIO/ACPI 风扇，NPU DT 无 `fan`/`pwm` 节点。想做软件调速得先把 PWM 通道跟风扇对上（[19](19-module-vs-kernel-rebuild.md) §19.6） |

### 中优先级（想用某个功能时才需要）

| # | 事项 | 现状 |
|---|---|---|
| 5 | **LED 极性 / 映射未逐一验证** | 面板灯走 PHY 的 LED 控制寄存器；`PCA9555` 驱动面板灯已被证伪。要逐个口试（[06](06-switch-and-ports.md)、[12](12-measurements.md)） |
| 6 | **交换机 port 5–8 是否引到面板** | PHY 存在、面板只有 4 座，需要看 PCB 或实测 |
| 7 | **MCP2210 SPI NOR 读写工具** | x86 侧那颗 MCP2210（USB→SPI）驱动没写；救砖时才有用 |
| 8 | **x86 的 i2c-dev / GPIO 暴露** | 目前没开，接外设时再弄 |
| 9 | **`dev_write … 4 f002/2000` 的字段含义** | 已确认是 SerDes/PCS 块，细节要 datasheet |
| 10 | **EIP197 是否值得启用** | 正确性过了但比 CPU 慢；只有大包量场景才需要重测（[16](16-eip197-activated.md)） |

### 低优先级 / 也许永远不做

- **x86 装 `systemd-timesyncd`**：实测 x86 时钟比墙钟慢 1 小时且 `NTP service: n/a`，
  排障时两边日志时间对不上（NPU 有 timesyncd，是对的）。5 分钟的事。
- **NPU 单独重启后，x86 侧自愈脚本拉不回来**：`xgs-ntb-watch` 会每 ~68 s 重跑
  `xgs-ntb-up.sh`（remove+rescan），但实测 4 次都没成功，最后靠重启 x86 才恢复。
  需要查清是"主机侧重枚举不重握手"还是"NPU 侧 EPF 没重新发 LINK_UP"。
- 内置（`=y`）而不是模块化 `mv88e6xxx` / `mvpp2`：现在模块换起来方便，没必要。
- 原厂 CPSS / `mvpp2x` 多口驱动：只支持 4.14，且我们已经有 DSA。
- 自研交换机驱动：上游 `mv88e6xxx` 已经够用。
- Wi-Fi：本机（XGS 87 非无线版）没有无线模块。

## 9.3 事实证明"不用做"的（曾经的担忧）

| 曾经的担心 | 实测结论 |
|---|---|
| "NTB 必须换内核" | ❌ 不成立 —— Debian 内核开 `CONFIG_NTB` 就能用，我们跑的是 vNTB |
| "交换芯片没有 mainline 驱动" | ❌ 不成立 —— 88E6193X 在主line `mv88e6xxx` 里，`6b491af01aa5` 修了探测 |
| "SFP 口只能 1G" | ❌ 不成立 —— DTS 改 `10gbase-r` 后实测 10G |
| "NPU 是无风扇设计" | ❌ 不成立 —— 有风扇，只是软件不可控 |
| "NPU 是 Buildroot 空密码" | ❌ 不成立 —— 现在跑 Debian，root 有密码 |

## 9.4 如果要重做一遍（换机 / 重刷的最小路径）

1. **备份**：eMMC 整盘 + `mtd0`(U-Boot) + `mtd1`(env)，SHA256 存档（[07](07-storage.md)）。
2. **改 U-Boot env**：`bootcmd` → `bootcmd_deb`（`ext4load` Image + dtb + initrd → `booti`），
   注意 `bootcmd_deb10g` 先用 `mvswitch` 把 port 9 配成 10G（[03](03-boot-chain.md)）。
3. **DTB**：`board/cn9130-sophos-xgs87w-sfp10g.dts`（本仓库，含 `ramoops`）。
4. **模块**：`tools/build/build-npu-net.sh`、`tools/build/build-npu-vntb.sh`、`tools/build/build-x86-vntb.sh`。
5. **网络**：`systemd/npu/` 装到 NPU、`systemd/x86/` 装到 x86（见 [systemd/README.md](../systemd/README.md)、[20](20-lan-over-vntb.md)）。
6. **别做的事**：`mtd0` 永不写；不要在 x86 上手工 `rmmod ntb_hw_epf`（会把自己搞崩）。

> 完整的实测数据见 [12-measurements.md](12-measurements.md)；
> 每篇文档开头都有状态标记（✅ 实测 / 📦 原厂档案 / 💡 设想 / ⚠️ 未验证）。
