# 19 · 换模块 vs 重编内核（以及风扇到底归谁管）

> 🏷 **状态（2026-11-23 复核）**：✅ **结论已复核**：`mvpp2` / `mv88e6xxx` 都是模块、都不用重编内核；
> 真需要重编内核的情形也验证过一次（`CONFIG_PSTORE_CONSOLE`）。风扇一节已更正为"**有风扇**但软件不可控"。

## 19.1 什么时候只要换模块

原以为 TCAM 修复和 `MVPP2_AGGR_TXQ_SIZE` 都要重编内核，查了 Debian 的实际配置后发现**都是模块**：

| 目标改动 | 源码位置 | Debian 配置 | 实际需要的动作 |
|---|---|---|---|
| mv88e6xxx TCAM 越权修复（`e3624f5eeac4` + `242ebf4c5114`） | `drivers/net/dsa/mv88e6xxx/` | `CONFIG_NET_DSA_MV88E6XXX=m` | 重建 **`mv88e6xxx.ko`** |
| `MVPP2_AGGR_TXQ_SIZE` 256 → 512 | `drivers/net/ethernet/marvell/mvpp2/mvpp2.h` | `CONFIG_MVPP2=m` | 重建 **`mvpp2.ko`** |
| vNTB 全套 | `drivers/ntb/`、`drivers/pci/endpoint/` | 都没编 | 外挂模块（[ntb/](../ntb/)），见 [17](17-x86-npu-shared-mgmt.md) |
| x86 侧 NTB 栈 | 同上（amd64） | 都没编 | 外挂模块，见 [tools/build](../tools/build/) |
| cpufreq（OPP）+ thermal 降频 | `drivers/cpufreq/armada-8k-cpufreq.c`、`drivers/clk/mvebu/ap-cpu-clk.c` | 两个都**没编** | 两个模块都试了：`ap-cpu-clk` 段错误，`armada-8k-cpufreq` 报 `Cannot get clock for CPU 0`，**仍未修** |
| safexcel 8 ring / MUSDK SAM | `drivers/crypto/inside-secure/` | `=m` | 大工程，见 [18](18-same-soc-platforms.md) §18.5 |

顺带确认：`CONFIG_ARMADA_THERMAL=m`、`CONFIG_CPU_THERMAL=y`、`CONFIG_THERMAL_GOV_STEP_WISE=y`
—— **热管理框架齐的**，缺的只有"能降频的 cooling device"。

## 19.2 什么时候必须重编内核

只有**编进 vmlinux 的东西**才需要重编。实际遇到的一次：

| 需求 | 为什么不能靠模块 |
|---|---|
| `CONFIG_PSTORE_CONSOLE` / `PSTORE_PMSG` | 它们是 **pstore 核心的一部分**（`fs/pstore/console.c`、`pmsg.c`），而 Debian 是 `CONFIG_PSTORE=y`（内置）→ 只能重编 `Image` |

这次重编的实测记录（很有参考价值）：

```
# 交叉编译（PC / WSL，不用 qemu）
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image
→ arch/arm64/boot/Image  44 349 952 B（原 Debian Image 37 732 288 B）
```

- **耗时**：整套 `Image` 约 12 分钟（`-j16`），比 build 全部 modules 还快。
- **模块不用重编**：编完 `Module.symvers` 与 Debian 头包里那份 **md5 完全相同**
  （`780c4fc2…`）——因为改了 `CONFIG_PSTORE_*` 并没有动任何导出符号的原型。
  所以 `mv88e6xxx` / `mvpp2` / vNTB 六个模块**一个都没换**，重启后全部正常加载。
- **`vermagic` 必须还是 `6.12.117+deb13-arm64`**：写进 `.config` 的 `CONFIG_LOCALVERSION`，
  不要用源码根的 `localversion` 文件（会和它叠加成两份）。
- 部署：先 `cp -a /boot/Image /boot/Image.pre-pstore`，再覆盖；回滚就是把备份拷回来。

> 结论：**能模块化就别重编内核**；真需要重编时，只要 `.config` 的 ABI 相关项没变，
> 现有模块不用跟着重编。这次的产物已上线，`printk: legacy console [ramoops-1] enabled` 可见；
> 但 ramoops 本身在这块板子上没用（每次复位都 DDR scrub），见 [20 §20.8](20-lan-over-vntb.md)。

⚠️ **反过来的坑更致命**：模块绑死在内核版本上。**已解决（2026-11-23）** ——
所有 out-of-tree 模块都改成了 DKMS 包（[kernel/x86](../kernel/x86/)、[kernel/npu](../kernel/npu/)），
内核升级时 `dkms` 自动重编。实机验证：x86 从 6.12.94 升到 6.12.118，重启后链路自己回来；
NPU 则干脆切回**发行版内核**（自编的 `CONFIG_PSTORE_CONSOLE` 内核已退役，因为 ramoops 本来就没用）。

`mv88e6xxx` / `mvpp2` 也不再替换了：两个补丁（TCAM 越权、`AGGR_TXQ_SIZE 512`）都只是加固/调优，
用发行版原版即可，补丁留在 [net/patches/](../net/patches/) 里备用。

## 19.3 DKMS 是怎么组织的

```
kernel/npu/   ntb_core ntb_transport ntb_netdev pci_ep_cfs pci_epf_vntb
              pcie_dw_plat spi-orion clkfix          → 8 个模块，一个 DKMS 包
kernel/x86/   ntb_core ntb_transport ntb_netdev ntb_hw_epf   → 4 个模块
```

- 源码是**上游文件 + `ntb/*.patch`**，直接放在包里（Debian 的 headers 包不带这些驱动的源码）。
- `DEST_MODULE_LOCATION = /updates/dkms`，所以会**覆盖** `kernel/` 里的同名模块，不用动发行版文件。
- 装法：`kernel/npu/install.sh` / `kernel/x86/install.sh`（会自己装 `dkms` 和对应 headers）。
- 验尸命令：`dkms status`，应为 `xgs87-npu/1.0.0, 6.12.117+deb13-arm64, aarch64: installed`。

## 19.3 风险：换模块可能失联

`mv88e6xxx.ko` 和 `mvpp2.ko` 是 DSA 的底座：

```
end0 (mvpp2) ──► 88E6193S (mv88e6xxx) ──► p1…p8 / sfp
```

任何一个换错 → 交换机 probe 失败 → `end0`/`p1…p8` 全消失 → **SSH 立刻断**。

好在 NPU 的控制台是**从 x86 上取的**（不再需要拆机接排针）：

```sh
# 在 x86 上
sudo /usr/local/sbin/npu-console.sh login       # root / openwrt123
sudo /usr/local/sbin/npu-console.sh 'lsmod | grep mv88e'
```

（host 侧波特率必须是 **57600**；细节见 [08](08-console-access.md)。）

## 19.4 不需要串口、随时能做的

| 项 | 命令（在 NPU 上） | 风险 |
|---|---|---|
| mvpp2 ring 加大 | `ethtool -G end0 rx 2048 tx 2048` | 无（可回退） |
| 复测吞吐验证 ring 效果 | `iperf3` 4 流 | 无 |
| 整理 PCIe EP 的上游补丁 | 文档工作 | 无 |

## 19.5 换模块的安全顺序

```sh
# 1. 备份现用模块（不压缩存一份原样）
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/dsa/mv88e6xxx/mv88e6xxx.ko /root/backup/
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/marvell/mvpp2/mvpp2.ko /root/backup/

# 2. 覆盖（**不压缩**，见 20 §20.9 的 xz 坑）+ depmod
# 3. 重启（不要热换：DSA 卸载/重装会让已创建的 netdev 处于不一致状态）
reboot

# 4. 起来后验证
ip -br link            # p1…p8、end0 都在
ethtool -i end0 | grep version
ip -d link show end0 | grep -o 'tx-queue-len [0-9]*'
```

失败时（走 x86 → ttyS2 的 NPU 控制台）：

```sh
cp /root/backup/mv88e6xxx.ko /lib/modules/$(uname -r)/kernel/drivers/net/dsa/mv88e6xxx/
cp /root/backup/mvpp2.ko    /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/marvell/mvpp2/
depmod -a && reboot
```

## 19.6 风扇：**有**，但软件控不了

**先说结论：这台机器是有风扇的**（整机一颗，上电就转，不存在"fanless"版本）。
下面的表格讲的是**为什么软件控制不了它**。早前文档里写成"无风扇/被动散热"是错的，已更正。

| 侧 | 能力 | 原厂是否使用 |
|---|---|---|
| NPU | 有 3 个 PWM 控制器：AP GPIO（20 路）、CP0 GPIO1（32 路）、CP0 GPIO2（31 路） | **没有**：原厂 DTB 里没有任何 `fan`/`pwm` 节点，rootfs 里也没有 `fancontrol`/`pwmfan`/相关 unit，只有 `xgs-cpss-temperature`、`xgs-dimm-temperature`、`xgs-phy-temperature` 三个测温小工具 |
| x86 | 无：没有 SuperIO 风扇控制器（`nct6775`/`it87` 加载后不产生 hwmon），ACPI 里没有风扇设备，**连 thermal zone 都没有** | 不适用 |

结论：**软件层面两边都没在控风扇。** 风扇要么是**定速常转**，要么由**板载硬件温控**
（模拟电路/热敏电阻）自行调节。要接管它，必须先量出风扇 PWM/TACH 接在哪根 MPP 上
（需要原理图或逐个试）。