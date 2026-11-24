# 04 · NPU 系统（原厂 Buildroot）

> 🏷 **状态（2026-11-23 复核）**：📦 **原厂档案（已退役）**：Buildroot 系统已被 Debian 13 替换，本文只作排查硬件问题时的参考。

> ⚠️ **本文是历史档案**：这里的 Buildroot 系统在 2026-11-22 已被 Debian 13 替换。
> 保留它是因为原厂的初始化顺序、驱动清单和 VPD 布局仍然是排查硬件问题的唯一参考。
> 当前系统见 [14-npu-debian-hardware.md](14-npu-debian-hardware.md)，网络与自启见 [20](20-lan-over-vntb.md)。

## 4.1 概况

| 项目 | 值 |
|---|---|
| 发行版 | **Buildroot 2018.11-gbe220aa**（Marvell SDK 10.22.03） |
| 内核 | **4.14.207-10.22.03** aarch64，Marvell GCC 7.3.0 |
| rootfs | ext4，`/dev/mmcblk0p3`，278 MB 已用 / 1.5 GB |
| init | sysvinit（`/etc/init.d/S*`）+ 少量 systemd 风格工具 |
| shell | bash（登录后是 `~#`） |
| 包管理 | 无 |
| 登录 | `marvell` / 空密码；**root 空密码** |

内核配置要点（`reference/npu-kernel-config.gz`）：

```
CONFIG_MVPP2=y
CONFIG_MVPP2X=m
# 无 CONFIG_MV88E6XXX（交换机不在 Linux 里）
# 无 CONFIG_NTB / PCI_EPF_VNTB
```

## 4.2 init 顺序

```
S01logging  S02sysctl  S15watchdog  S20urandom  S30dbus  S38platform
S40network  S50sshd   S55logforward  S91xgsstartup
```

### S38platform

按 `CPU part` 判断平台（0xd08 = ARMADA），把 `/usr/marvell/<PLATFORM>/{lib,bin,…}`
挂/拷到系统目录，然后 `depmod`。本机走 `ARMADA` 分支。

### S91xgsstartup → `/sbin/xgs_startup.sh`

```
partno=$(xgs-platform npu0.assembly.partno)      # = AMDA0200-0001
xgs-do-depmod.sh
xgs-check-partno.sh
xgs-check-uboot-sdk.sh &
case $partno in
  AMDA0200-000x) /usr/sbin/xgs_dt1_startup.sh ;;
  …
esac
xgs-sff-event &          # SFP 事件
xgs-healthmond &         # 健康监控
xgs-poe -i               # PoE 默认值
touch /tmp/npu_startup_complete
```

### `/usr/sbin/xgs_dt1_startup.sh`（本机走这条）

```bash
gpioset 3 0=1 1=1 … 15=1          # 关掉所有 speed LED
[ "$revision" = x01 -o "$revision" = x02 ] && { gpioset 2 17=0; sleep 1; gpioset 2 17=1; sleep 1; }
modprobe mvmdio_uio
[ "$pxeboot" = 1 ] && xgs_dt_ipxe_target_setup.sh
. /etc/sophos/dp_startup.conf
$DP_DT1_STARTUP_SCRIPT $DP_DT1_STARTUP_ARGS &   # 起 PCIe 数据面（mvmgmt0）
sleep 5 … 等 mvmgmt0 出现，最多 15 次
```

> 本机 `revision=07`，所以**不会**复位交换机 —— 这也意味着在 U-Boot 里配好的交换机状态
> 能一直保留到 Linux 起来之后。

## 4.3 驱动与模块

`/proc/modules`（原厂启动后）：

```
mv_nwa_target         24576  0  Live   ← 数据面（NWA）
mv_pcinet_trgt        28672  0  Live   ← PCIe 网络 target
mv_armada_ep          36864  2  Live   ← PCIe endpoint 框架
mv_facility_trgt_dma  16384  1  Live   ← DMA facility
uio_pdrv_genirq       16384  0  Live
mv_dmax2_uio          16384  0  Live   ← XOR DMA
musdk_cma             16384  0  Live
mvmdio_uio            16384  0  Live   ← 用户态 MDIO
```

`/lib/modules/` 下还有 OCTEONTX / OCTEONTX2 / OCTEONTX2-98XX 三套（同一份 rootfs 支持多平台）。

## 4.4 数据面初始化（pcinet）

内核日志：

```
armada-ep cp0:armada-ep: probing Armada PCI-EP device
armada-ep: BAR0 address @ … size 0x100000
armada-ep: BAR2 address @ … size 0x1000000
armada-ep: Copying target barmap info to end of mapped memory
armada-ep: Remapped host memory @ … size 0x1000000000   (64 GB)
armada-ep: facility dma thresholds: H2T > 8, T2H > 32 bytes
armada-ep: pcinet: mvmgmt0: netdev registered, ifindex = 3
armada-ep: pcinet: status_ptr:…
armada-ep: pcinet: Status written
armada-ep: pcinet: mvmgmt0: started
```

`mvmgmt0` 是一条"管理以太网"，走 PCIe 到 x86。原厂 x86 侧靠它做带内管理。

原厂的数据面初始化绑在**和 x86 的两次握手上**，所以换掉 x86 的原厂系统后这条链会停在中间：

```
xgs_dt1_startup.sh
  └─ armada_target_setup_usfp.sh custom1
       ├─ insert_mod mv_pcinet_trgt / mv_armada_ep / mv_nwa_target / mvmdio_uio …
       ├─ ifup mvmgmt0
       ├─ while true: 读 /sys/kernel/facility/dump_conf 的 handshake，等它 >= 0xb
       │              ← 实测恒为 0x1（x86 上没有 pcinet host 驱动就没人推进它）
       ├─ ./NetAgent &  UMSD_NPU &  usfp_startup_armada.sh …   ← 这三行永远轮不到
       └─ touch /tmp/npu_startup_complete                      ← 从未生成
```

即使用手工补跑把 `usfp` 拉起来（内存分配、MQA 表初始化都成功），它还会卡在第二道
`pf#0: Wait till Host change the status to 'Host Management Ready'`；**配交换机的代码在第二道之后**，
所以 `eth0` 恒 `NO-CARRIER`。这就是"前面板口不通"的原厂原因，也是本仓库改走 vNTB 的理由
（[17](17-x86-npu-shared-mgmt.md)、[20](20-lan-over-vntb.md)）。

顺带两条常被误判的线索：

- 内核那条 `mdio@12a200/switch@2 has invalid PHY address` **不是硬件故障**：DT 里用的是自定义
  属性 `phy-addr`，标准 `of_mdio` 只认 `reg`，所以报"无效地址"；交换机本来就由用户态
  （`mdio_uio` → USFP/DPDK）配置。`gpioget 2 17` = `1` 也说明复位线没被按住。
- `mvswitch` / `ext4ls` 这类命令"敲了没反应"先怀疑串口，别怀疑命令集（[08](08-console-access.md) §8.5 第 10 条）。


## 4.5 `/opt/sophos` —— 机型数据库

```
/opt/sophos/plt/     AMDA0105-0001R00.txt … AMDA0222-0002R00.txt   （几十个机型）
/opt/sophos/uenv/    xgsdt1_uenv.txt, xgsdt2_116_uenv.txt, …
/opt/sophos/usfp/    armada/ octtx/ octtx2/ octtx2-98xx/            （SFP 参数）
```

每个 `.txt` 是一份 **key=value 的机型定义**，包含：用哪颗交换芯片、MDIO 地址、
每个面板口的 PHY 类型/速率/LED/GPIO/流控、SFP 的 i2c 与 GPIO、背板 10G 口。
**这是做端口映射最权威的资料**（本机用的是 `AMDA0200-0001R00.txt`）。

`xgs-platform` 命令就是读这些文件：

```
# xgs-platform npu0.assembly.revision
07
# xgs-platform npu0.assembly.partno
AMDA0200-0001
```

## 4.6 `/usr/marvell` —— SDK 用户态

```
cpss_agent                  Marvell CPSS 交换芯片控制（ELF）
armada_target_setup.sh
armada_target_giu_reload.sh
softnic_setup.sh
nwa_db_*.bin                各平台的 NWA 数据库（cn9130_crb / cn9131 / cn96xx …）
umsd_*.cfg, UMSD_NPU/       用户态多交换机驱动(CPSS UMSD) 配置
npu_dump_83xx.sh, dump_9130_dma_regs.sh
xgs-tools-utar-in-root.tar
resource/
```

> 原厂交换机配置走的是 **CPSS + UMSD（用户态）**，不是内核 DSA。
> 这解释了为什么 `mvswitch` 只在 U-Boot 里有。

## 4.7 `/persistent`（p4）—— 出厂数据

```
/persistent/xgsdt1-vpd.txt     机型/序列号/MAC 基址
/persistent/xgsdt1-vpd.bin     同上二进制
```

**刷机时不要动 p4**，否则 MAC 和机型信息会丢。

## 4.8 已安装的常用工具

`busybox` 全家桶之外还有：`ethtool`, `i2cdetect/i2cdump/i2cget/i2cset/i2ctransfer`,
`devmem`, `flashcp/flash_erase`, `fw_printenv/fw_setenv`, `xz/gzip/tar`, `wget`,
`sshd/sftp-server`, `eeprog`, `hdparm`, `bridge/brctl`, `ifup/ifdown`.

缺：`lspci`、`nc`、`httpd`、`dtc`、`python`。

## 4.9 系统现状（实测）

- 启动后 `eth0` **DOWN**，`mvmgmt0` 无载波 —— 因为原厂把数据面交给 x86，自己不再配交换机。
- 没有任何用户态守护进程常驻（`ps` 只有 init + 我们开的 shell）。
- `/sys/class/leds` 不存在（DT 里没有 LED 节点）。
- RTC 未设好时会回到 2105 年（`armada38x-rtc`），注意日志时间戳。

## 4.11 为什么不把完整 rootfs 放进本仓库

原厂 rootfs（p3，约 100 MB gzip）里包含 **Sophos / Marvell 的专有二进制**
（`cpss_agent`、`nwa_db_*.bin`、`mv_*` 驱动、各类闭源工具），公开分发有版权风险，
因此本仓库只放**实测数据**（设备树、内核 config、U-Boot、日志）和文档。

需要完整镜像时在自己机器上导出即可（命令见 [07-storage.md](07-storage.md)）：

```sh
# 在 NPU 上
tar -C / --exclude=./proc --exclude=./sys --exclude=./dev \
        --exclude=./tmp --exclude=./run -czf - . > /rootfs.tar.gz
```

或者把本仓库 clone 下来，用 `tools/` 里的脚本重新采集。

## 4.12 我们做过的改动（可回滚）

| 改动 | 目的 |
|---|---|
| `mount -o remount,rw /` | 写 sshd 配置/authorized_keys（重启后自动回 ro） |
| `passwd root` 设为 `openwrt123` | 方便 SSH（原厂空密码不能远程登录）。**这个名字是 OpenWrt 时代留下的，密码一直没改**。`image/` 产出的 Debian 镜像反过来：root 锁定、只留 admin + sudo |
| `/root/.ssh/authorized_keys` 追加公钥 | 免密登录 |
| `/etc/ssh/sshd_config` 追加 `PermitRootLogin yes` | 允许 root 登录 |
| `ifconfig eth0 192.168.1.1/24 up` | 验证数据面（未持久化） |

> p3 分区原厂挂载是 ro，改完重启就恢复；密码和 authorized_keys 是写到 p3 的，会保留。
