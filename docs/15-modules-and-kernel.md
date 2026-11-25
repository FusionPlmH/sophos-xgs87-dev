# 15 · 换模块 vs 重编内核（以及风扇到底归谁管）

> 🏷 **状态（2026-11-23 复核）**：✅ **结论已复核**：`mvpp2` / `mv88e6xxx` 都是模块、都不用重编内核；
> 真需要重编内核的情形也验证过一次（`CONFIG_PSTORE_CONSOLE`）。风扇一节已更正为"**有风扇**但软件不可控"。

## 15.1 什么时候只要换模块

原以为 TCAM 修复和 `MVPP2_AGGR_TXQ_SIZE` 都要重编内核，查了 Debian 的实际配置后发现**都是模块**：

| 目标改动 | 源码位置 | Debian 配置 | 实际需要的动作 |
|---|---|---|---|
| mv88e6xxx TCAM 越权修复（`e3624f5eeac4` + `242ebf4c5114`） | `drivers/net/dsa/mv88e6xxx/` | `CONFIG_NET_DSA_MV88E6XXX=m` | 重建 **`mv88e6xxx.ko`** |
| `MVPP2_AGGR_TXQ_SIZE` 256 → 512 | `drivers/net/ethernet/marvell/mvpp2/mvpp2.h` | `CONFIG_MVPP2=m` | 重建 **`mvpp2.ko`** |
| vNTB 全套 | `drivers/ntb/`、`drivers/pci/endpoint/` | 都没编 | 外挂模块（[ntb/](../ntb/)），见 [档案](archive/p8-shared-mgmt.md) |
| x86 侧 NTB 栈 | 同上（amd64） | 都没编 | 外挂模块，见 [tools/build](../tools/build/) |
| cpufreq（OPP）+ thermal 降频 | `drivers/cpufreq/armada-8k-cpufreq.c`、`drivers/clk/mvebu/ap-cpu-clk.c` | 两个都**没编** | 两个模块都试了：`ap-cpu-clk` 段错误，`armada-8k-cpufreq` 报 `Cannot get clock for CPU 0`，**仍未修** |
| safexcel 8 ring / MUSDK SAM | `drivers/crypto/inside-secure/` | `=m` | 大工程，暂不做（CPU 侧足够快） |

顺带确认：`CONFIG_ARMADA_THERMAL=m`、`CONFIG_CPU_THERMAL=y`、`CONFIG_THERMAL_GOV_STEP_WISE=y`
—— **热管理框架齐的**，缺的只有"能降频的 cooling device"。

## 15.2 什么时候必须重编内核

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
> 但 ramoops 本身在这块板子上没用（每次复位都 DDR scrub），见 [09 §11.1](09-vntb.md)。

⚠️ **反过来的坑更致命**：模块绑死在内核版本上。**已解决** —— out-of-tree 模块都做成了
DKMS 包（[kernel/x86](../kernel/x86/)、[kernel/npu](../kernel/npu/)），`install.sh` 会把
dkms + headers 装上，之后内核升级自动重编。历史实机验证：`full` 变体的 x86 从 6.12.94
升到 6.12.118，重启后链路自己回来。
NPU 则干脆切回**发行版内核**（自编的 `CONFIG_PSTORE_CONSOLE` 内核已退役，因为 ramoops 本来就没用）。

> **发布用的 `lean` 镜像不在这条"自动重编"的覆盖范围内**：它把工具链 purge 掉了，也不装
> dkms，模块是构建时用 `make` 编好放进 `/lib/modules/<kver>/updates/` 的 `.ko.xz`，内核被
> `apt-mark hold`。要换内核：`apt-mark unhold linux-image-amd64`（NPU 是 `linux-image-arm64`）
> → 升内核 → 跑 `/opt/xgs87/kernel/<side>/install.sh`（它会把 dkms 装回来）。

`mv88e6xxx` / `mvpp2` 也不再替换了：两个补丁（TCAM 越权、`AGGR_TXQ_SIZE 512`）都只是加固/调优，
用发行版原版即可，补丁留在 [net/patches/](../net/patches/) 里备用。

## 15.3 DKMS 是怎么组织的

```
kernel/npu/   ntb_core ntb_transport ntb_netdev pci_ep_cfs pci_epf_vntb
              pcie_dw_plat spi-orion clkfix          → 8 个模块，一个 DKMS 包
kernel/x86/   ntb_core ntb_transport ntb_netdev ntb_hw_epf   → 4 个模块
```

- 源码是**上游文件 + `ntb/*.patch`**，直接放在包里（Debian 的 headers 包不带这些驱动的源码）。
- `DEST_MODULE_LOCATION = /updates/dkms`，所以会**覆盖** `kernel/` 里的同名模块，不用动发行版文件。
- 装法：`kernel/npu/install.sh` / `kernel/x86/install.sh`（会自己装 `dkms` 和对应 headers）。
- 验尸命令：`dkms status`，应为 `xgs87-npu/1.0.0, 6.12.117+deb13-arm64, aarch64: installed`。

## 15.4 风险：换模块可能失联

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

（当前 Debian 的 host 侧用 **115200**；只有老 `image/` 内核才要 57600，细节见
[10](10-console.md) §10.3。）

## 15.5 模块替换（历史；现在镜像用发行版原版）

| 模块 | 改动 | 结果 |
|---|---|---|
| `mvpp2` | `MVPP2_AGGR_TXQ_SIZE` 256 → **512** | ✅ 曾交叉编译并上线；现在镜像用发行版原版，512 版是可选优化 |
| `mv88e6xxx` | 两个 TCAM 越权补丁（`e3624f5eeac4` + `242ebf4c5114`） | ✅ 曾交叉编译并上线，9 个 netdev 正常；现在镜像用发行版原版，补丁留在 [net/patches/](../net/patches/) 备用 |

> 为什么又改回发行版：两个改动都只是加固/调优，不是功能必需；用发行版原版可以让
> `apt upgrade` + DKMS 的维护面最小。见 [15](15-modules-and-kernel.md) §15.2。

### 15.5.1 交叉编译（不要再走 qemu 模拟）

Debian 的 `linux-headers` 包里 `scripts/` 是 **arm64 二进制**（`fixdep`、`modpost`），
在 x86 上跑不了，所以之前只能把整个 rootfs 塞进 qemu-user 里编 —— 一个 216 KB 的
`mvpp2_main.c` 要十几分钟。正解是用**完整源码树 + 交叉编译器**，host 工具用宿主 gcc 编，
只有模块代码走交叉 gcc：

```sh
apt-get install gcc-14-aarch64-linux-gnu flex bison bc libelf-dev libssl-dev

# 1) 准备独立输出目录，喂进 NPU 自己的 config
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 modules_prepare

# 2) modules_prepare 不生成 Module.symvers，从 headers 包里借
cp /srv/npu/usr/src/linux-headers-6.12.117+deb13-arm64/Module.symvers /srv/kbuild/

# 3) vermagic 必须带 Debian 的后缀，否则 modprobe 直接拒载
#    （LOCALVERSION= 会被 olddefconfig 吃掉，源码根目录 localversion 文件会和
#     CONFIG_LOCALVERSION 重复；正确做法是直接改 .config 里的 CONFIG_LOCALVERSION）
grep CONFIG_LOCALVERSION /srv/kbuild/.config     # CONFIG_LOCALVERSION="+deb13-arm64"
grep UTS_RELEASE /srv/kbuild/include/generated/utsrelease.h   # "6.12.117+deb13-arm64"

# 4) 按内核自己的 Kbuild 编（不要在外部目录手拼 Makefile）
make -C $SRC O=/srv/kbuild ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     M=$SRC/drivers/net/dsa/mv88e6xxx modules
```

一套下来 **十几秒**，比 qemu 快两个数量级。脚本见 [tools/build/build-npu-net.sh](../tools/build/build-npu-net.sh)。

### 15.5.2 踩过的两个坑

| 现象 | 真因 |
|---|---|
| 模块能加载，但 `p1..p8/sfp` 全部消失，dmesg 一行错都没有 | 我在外部目录**手拼 Makefile**，漏了内核 Kbuild 里的条件对象，`dsa_register_switch()` 之后没下文。必须用 in-tree Kbuild。 |
| dmesg 出现 `decompression failed with status 6`，模块根本没被加载 | 手工用 `xz -9` 压的模块：64 MiB 字典**超出内核 xz 解码器允许范围**。小字典（`--lzma2=dict=1MiB`）或干脆放未压缩的 `.ko` 都行。反过来说，`make modules_install` 自己产出的 `.ko.xz` 是能加载的 —— 镜像里 `/lib/modules/*/updates/` 那四个就是 `.ko.xz`（`CONFIG_MODULE_COMPRESS_XZ=y`），一直在用。 |

第二个坑特别有欺骗性：`lsmod` 里看不到模块，但启动过程不报错，看起来就像"驱动不 probe"。

### 15.5.3 回滚

```sh
D=/lib/modules/6.12.117+deb13-arm64/kernel/drivers/net/dsa/mv88e6xxx
# 放未压缩的 .ko（手工 xz -9 的 64 MiB 字典会被内核解码器拒绝）
cp -a $D/mv88e6xxx.ko.orig $D/mv88e6xxx.ko
depmod -a && reboot
```

交换机一死，NPU 就只能从 console 进（面板口全没了），所以动 `mv88e6xxx` 之前必须确认
`/dev/ttyS2` 这条路是通的。
## 15.6 不需要串口、随时能做的

| 项 | 命令（在 NPU 上） | 风险 |
|---|---|---|
| mvpp2 ring 加大 | `ethtool -G end0 rx 2048 tx 2048` | 无（可回退） |
| 复测吞吐验证 ring 效果 | `iperf3` 4 流 | 无 |
| 整理 PCIe EP 的上游补丁 | 文档工作 | 无 |

## 15.7 换模块的安全顺序

```sh
# 1. 备份现用模块（不压缩存一份原样）
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/dsa/mv88e6xxx/mv88e6xxx.ko /root/backup/
cp -a /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/marvell/mvpp2/mvpp2.ko /root/backup/

# 2. 覆盖（放未压缩的 .ko 最省事；别手工 xz -9，见 20 §15.5 的 xz 坑）+ depmod
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

## 15.8 风扇：**有**，但软件控不了

**先说结论：这台机器是有风扇的**（整机一颗，上电就转，不存在"fanless"版本）。
下面的表格讲的是**为什么软件控制不了它**。早前文档里写成"无风扇/被动散热"是错的，已更正。

| 侧 | 能力 | 原厂是否使用 |
|---|---|---|
| NPU | 有 3 个 PWM 控制器：AP GPIO（20 路）、CP0 GPIO1（32 路）、CP0 GPIO2（31 路） | **没有**：原厂 DTB 里没有任何 `fan`/`pwm` 节点，rootfs 里也没有 `fancontrol`/`pwmfan`/相关 unit，只有 `xgs-cpss-temperature`、`xgs-dimm-temperature`、`xgs-phy-temperature` 三个测温小工具 |
| x86 | 无：没有 SuperIO 风扇控制器（`nct6775`/`it87` 加载后不产生 hwmon），ACPI 里没有风扇设备，**连 thermal zone 都没有** | 不适用 |

结论：**软件层面两边都没在控风扇。** 风扇要么是**定速常转**，要么由**板载硬件温控**
（模拟电路/热敏电阻）自行调节。要接管它，必须先量出风扇 PWM/TACH 接在哪根 MPP 上
（需要原理图或逐个试）。
