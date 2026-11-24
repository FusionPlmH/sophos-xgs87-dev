# 23 · MCP2210 SPI NOR 救砖工具

> 🏷 **状态（2026-11-25 复核）**：✅ **实机验证**：x86 的 `/dev/hidraw0`（MCP2210，04d8:00de）能正确读到
> NPU SPI NOR 的 `C2 20 16`（MX25L3205D）、SR=0x00，能读出并校验 64 KiB U-Boot env。
> 工具在 [tools/on-x86/mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py)。

## 23.1 为什么需要它

NPU 从 **SPI NOR flash 0** 启动：BootROM → TF-A → U-Boot → Linux。SPI NOR 里是
**TF-A + U-Boot + U-Boot env**（mtd0/mtd1），eMMC（p1–p4）不在这条 SPI 总线上。
U-Boot 刷坏或 env 写坏时，NPU 可能连控制台都进不去；x86 板载的 MCP2210 是**不拆机**的最后一条
写入通道。

默认写入全部限制在 **env 的 64 KiB**（`0x3F0000..0x400000`）。唯一会碰 mtd0
（TF-A/U-Boot）的是显式的 `mtd0-restore`：它必须同时给 `--unsafe-mtd0` 和 `--commit`，
而且只重写与镜像不同的 64 KiB 块。这不是建议，是代码里的硬约束：`dump` 必须先做整片双遍读；
`env-write` 没有已验证的整片备份、没有通过 U-Boot 参考镜像对拍、没有 `--commit`，都不会动 flash。

## 23.2 实测硬件事实

| 项目 | 值 |
|---|---|
| USB | Microchip MCP2210，`04d8:00de`，x86 内部 hub，`/dev/hidraw0` |
| HID | 64 字节命令/响应，**Linux 下没有 report ID 前缀**（Windows 才需要前导 `0x00`） |
| SPI NOR | Macronix **MX25L3205D**，4 MiB，JEDEC `C2 20 16`，256 B page，4 KiB sector，64 KiB block |
| 布局 | mtd0 `0x000000..0x3F0000`（TF-A + U-Boot，4032 KiB）；mtd1 `0x3F0000..0x400000`（env，64 KiB） |
| CS | **GP0**（MCP2210 的 CS0）；片选低有效 |
| NPU 控制 | **GP0 / GP3 / GP5**，mask `0x0029`。XGS 87/107（**AMDA0200**）`hold=0xFFD7`、`release=0xFFFF` |

### 为什么必须先 hold

MCP2210 和 NPU 的 SPI 控制器共用 flash 总线。NPU 正常上电时，GP0/GP3/GP5 是输入，板上拉高 =
**release**（`0x029`），总线在 NPU 手里；此时 MCP2210 读 flash 只会得到全 `FF`。
原厂 `xgs-usb-spi-flash` 的做法是先把这三根线写成 **hold**（AMDA0200：`0xFFD7`），
NPU 被复位、总线切给 MCP2210；操作完再写 **release**（`0xFFFF`）让 NPU 启动。

这些值来自对原厂 `xgs-usb-spi-flash` 的反汇编（见 os-xgs-npu 参考仓库的
`docs/npuep/npu-bring-up.md` 和 `src/opnsense/scripts/npuctl/mcp2210.py`），不是猜的；
**AMDA0200 的极性和 AMDA0201（XGS 126/136）正好相反**，不要照抄别的机型。

> ⚠️ hold 期间 NPU 处于复位、PCIe 端点会消失。先把 `xgs-ntb-watch` / `xgs-ntb` 停掉，
> 免得它们去碰 PCIe（虽然 watcher 现在默认不 rescan，`xgs-ntb` 的启动等待仍会刷屏）：
> `sudo systemctl stop xgs-ntb-watch xgs-ntb`。操作完可以再 `start`。
>
> 工具在 `SpiNor.close()` 里**无论成功失败都会 release**；如果进程被 SIGKILL 或断电，
> 下次运行 `npu release`（或给 MCP2210 断电/重启 x86）即可恢复。

## 23.3 MCP2210 命令集（DS22288A，实测）

> 早期 [05](05-x86-system.md) 里写的 “0x10 get GPIO / 0x20 SPI settings / 0x30 cancel /
> 0x40 transfer” 是错的（少了一组）。以本表和 datasheet 为准。

| 命令 | 作用 | 备注 |
|---|---|---|
| `0x10` | Get chip status | 总线 owner / release 请求 / 密码状态 |
| `0x11` | Cancel current SPI transfer | 不是 0x30 |
| `0x20` / `0x21` | Get / Set GPIO chip settings | 9 个 designation + 输出值 + 方向 + other |
| `0x30` / `0x31` | Set / Get GPIO **live value** | 0x30 写 16 位值，0x31 读回 |
| `0x32` / `0x33` | Set / Get GPIO **live direction** | 1 = 输入，0 = 输出 |
| `0x40` / `0x41` | Set / Get SPI transfer settings | 17 字节结构；bit rate 等字段小端 |
| `0x42` | SPI data transfer | 每包最多 60 字节；见 23.4 |
| `0x80` | Request SPI bus release | 外部 master 用 |
| `0x50` / `0x51` | Read / Write user EEPROM | 板号在 EEPROM 字节 0–1 |

GPIO chip settings 的 14 字节结构（`0x20` 响应的 `[4:18]`，`0x21` 请求同样偏移）：

```
[0..8]  GP0..GP8 designation：0=GPIO, 1=CS, 2=dedicated
[9..10] output value (LE16，上电/输出默认值)
[11..12] direction (LE16，1=input)
[13]    other chip settings（bit0: 1=SPI 总线不释放）
```

`0x20` 的 direction/output 是 **chip settings 的副本**；实时方向/电平要用 `0x33`/`0x31`。
`0x21` 写入 direction 后**会立即改变 live direction**（原厂 `gpio_write` 就靠这一点），
不需要再发 `0x32`。

## 23.4 SPI 传输引擎

`0x40` 的 17 字节设置：

```
[0..3]  bit rate (LE32, 1500..12,000,000)
[4..5]  idle chip-select value (16 位掩码，1=高)
[6..7]  active chip-select value
[8..9]  CS→data delay (100 µs 单位)
[10..11] last byte→CS delay
[12..13] inter-byte delay
[14..15] bytes per SPI transaction (LE16, 1..65535)
[16]    SPI mode (0..3)
```

一次事务（transaction）可以跨多个 `0x42` 包；`bytes per SPI transaction` 到了，CS 才会撤销。
每个 `0x42` 包：

```
请求: [0x42, count(0..60), 0, 0, data...]
响应: [0x42, status, rx_count, engine_status, rx_data...]
status: 0x00=接受, 0xF7=总线被外部 master 占用, 0xF8=忙（重发本包）
engine_status: 0x20=已开始无数据, 0x30=未结束有数据, 0x10=结束
```

注意：

- **0x42 不能盲目重试**：如果设备已接受但响应丢了，重发会把同一包数据重复发进事务。
  工具对 0x42 只发一次；0xF8 才重发同一包。
- HID 队列会错位：一条陈旧响应会让后续读到的都是上一条命令的答案。**0x42 的陈旧响应和
  下一次 0x42 命令字节相同，靠 `rx[0]` 回显根本区分不了**——2026-11-24 第一次整片 dump
  就是因此在 `0x000000..` 处两遍不一致。工具现在**每条命令前都 drain**（和原厂
  `xgs-usb-spi-flash` / os-xgs-npu 的做法一致），修复后同一 4 KiB 连读 5 次 SHA 完全一致。
- 打开设备后的第一条命令经常丢，重发即可。
- 1 MHz 下实测整片读约 **10–15 KiB/s**（瓶颈是 HID 轮询，不是 SPI）；4 MiB 单遍约 6–7 分钟。

## 23.5 安全模型（代码强制）

`dump`：

1. 读 JEDEC，必须是 `C2 20 16`（可用 `--force-chip` 绕过，不推荐）。
2. 整片 4 MiB 读**两遍**，逐字节比较；不一致直接报错，不落盘。
3. 写 `<out>.bin`、`<out>.json`（manifest：大小、SHA-256、每 64 KiB 的 SHA-256、芯片、
   MCP2210 序列号、SPI 参数、passes、verified）、`<out>.sha256`。

`env-write`（唯一的写命令）：

1. 必须有带 manifest 的 **两遍已验证** 整片备份（`--allow-unverified-backup` 可绕过，不推荐）。
2. 默认**重读整片**并与备份逐字节比较（`--quick` 只比 env，快但弱）。
3. 备份的 mtd0 必须与已知-good 的 U-Boot 参考镜像一致；不一致说明问题不在 env，
   直接拒绝（`--allow-uboot-mismatch` 才放行）。
4. 新 env 必须是 64 KiB、CRC 正确；如果 `ethaddr` 是 `xx:xx` 占位符而备份里是真 MAC，
   拒绝写入（防止把仓库里 redact 过的参考 env 直接刷进去）。
5. 读 SR；有 BP0–BP2 保护就拒绝（`--clear-bp` 才清）。
6. **默认只出计划，不写**；`--commit` 才执行，且还要交互输入 `WRITE-ENV`（或 `--yes`）。
7. 只擦 `0x3F0000` 的 64 KiB block、只 program env 内的非 0xFF 页；写完整段读回逐字节验证。
8. 写/验失败自动用备份里的旧 env **回滚**（仍然只动 env 区）。

`mtd0-restore`（唯一会写 0x000000..0x3F0000 的命令，默认只出计划）：

1. 必须有带 manifest 的两遍已验证整片备份（同 `env-write`）。
2. 镜像必须**正好** 0x3F0000 字节；给了 `--expect-image-sha256` 就必须对得上。
3. 先重读 **mtd0 区**并与备份逐字节比较（其它区域不管——这条命令根本不写 env，
   而 env 是随时会变的）；芯片的 mtd0 和备份不一致就拒绝。
4. 只有**差异的 64 KiB block** 才擦写，每块写完立刻读回验证，不一致就停
   （后面未写的块不动，env 区永不碰）。
5. 必须同时给 `--unsafe-mtd0`（承认这是 U-Boot/TF-A 区）和 `--commit`，
   再加交互输入 `RESTORE-MTD0` 或 `--yes`；缺一个都只出计划。
6. 全部写完再整段回读一次，SHA-256 必须等于镜像。

> 这条命令的存在理由是"把刷坏的 U-Boot 救回来"，不是日常操作。
> 现状：mtd0 与参考逐字节一致，**没有运行它的必要**（见 §23.7）。

## 23.6 用法（在 x86 上）

```sh
# 0) 先停掉会刷屏的 PCIe watcher
sudo systemctl stop xgs-ntb-watch

# 1) 只读：看 MCP2210 设置、JEDEC、SR、当前 env
sudo ./mcp2210-nor.py info --cs-pin 0 --read-env

# 2) 整片双遍 dump + manifest（NPU 会被 hold 约 12 分钟）
sudo ./mcp2210-nor.py dump --cs-pin 0 --out /var/backups/npu-nor-$(date +%F).bin

# 3) 再读一遍，确认备份与芯片当前内容一致
sudo ./mcp2210-nor.py verify --cs-pin 0 --backup /var/backups/npu-nor-2026-11-24.bin

# 4) 以备份里的真实 env（含真实 MAC）为底，只改 bootcmd
sudo ./mcp2210-nor.py env-build --from-backup /var/backups/npu-nor-2026-11-24.bin \
    --out /var/backups/env-rescue.bin --set 'bootcmd=run bootcmd_emmc3'

# 5) 先看计划（不写）
sudo ./mcp2210-nor.py env-write --cs-pin 0 \
    --backup /var/backups/npu-nor-2026-11-24.bin --image /var/backups/env-rescue.bin

# 6) 真正写（重读整片 + 对拍 mtd0 + 擦/写/回读验证 + 失败回滚）
#    x86 上没有仓库参考镜像时，用已知-good 的 mtd0 SHA-256 代替文件：
#    fe13a2a3d4240bcef568bcef41b9270a95bdf01e785ea1e3d055a43f031c2473
sudo ./mcp2210-nor.py env-write --cs-pin 0 --commit --yes \
    --reference-uboot-sha256 fe13a2a3d4240bcef568bcef41b9270a95bdf01e785ea1e3d055a43f031c2473 \
    --backup /var/backups/npu-nor-2026-11-24.bin --image /var/backups/env-rescue.bin
```

离线（不接 MCP2210）：

```sh
./mcp2210-nor.py compare --dump /var/backups/npu-nor-2026-11-24.bin
# 或指定参考镜像
./mcp2210-nor.py compare --dump ... \
    --reference-uboot reference/mtd/npu-mtd0-uboot.bin.gz \
    --reference-env reference/mtd/npu-mtd1-env.bin.gz
```

没有 CS 被设为 CS 时，`--cs-pin 0` 会把 GP0 临时设为 CS；工具退出时恢复原 GPIO/SPI 设置，
并按 23.2 的 hold/release 把 NPU 放回 release。

## 23.7 2026-11-24 这台砖机的实测

- `info --cs-pin 0`：JEDEC `C2 20 16`、SR `0x00`（无 BP 保护），1 MHz。
- 当前 env：CRC **OK**，35 项；`bootcmd=run bootcmd_deb10g`，`bootcmd_deb` 从
  `mmc 0:2` 加载 `/boot/Image`、`/boot/cn9130-sophos-xgs87w-sfp10g.dtb`、`/boot/initrd.img`，
  `bootargs_deb` 的 root 是 `/dev/mmcblk0p2`。
- **flash 开头没坏**：0x000000 起 4 KiB 的 SHA-256 是
  `855cafb74e480f6d554bb6b3c0cd4f3bf310747b5e26b47909ce9354c6e09c72`，与
  `reference/mtd/npu-mtd0-uboot.bin.gz` 的前 4 KiB **完全一致**。
- 第一次整片 dump 两遍在 0x000000.. 不一致，是 0x42 陈旧响应的跨事务错位（见 §23.4）；
  加上每条命令前 drain 后，同一 4 KiB 连读 5 次 SHA 全部一致。**修复版整片双遍 dump 已完成，
  两遍一致**：备份 `/var/backups/npu-nor.bin`，4 MiB，SHA-256
  `406776183588cb26d476d9d95c70ec6438fd731afd6e01846f110433720057de`，manifest `verified: true`；
  mtd0 的 SHA-256 是 `fe13a2a3d4240bcef568bcef41b9270a95bdf01e785ea1e3d055a43f031c2473`，
  与参考完全一致。
- 2026-11-24 已按“只改 env”写入 **p3 原厂启动**：
  `bootcmd=run bootcmd_deb10g` → `bootcmd=run bootcmd_emmc3`，其余 34 个变量（含真实 MAC、
  `bootcmd_deb`/`bootargs_deb`）全部保留。env CRC `0xAFA6FE54`，镜像 SHA-256
  `e82204e4ba7ff4497406fb1a432bc64dfbceb2d19bdc98f6388b7f528bd7f646`；工具回读逐字节验证通过。
- **2026-11-24 复读线上 env（`env-get --cs-pin 0 --json`）**：CRC `0xAFA6FE54` OK、35 项，与写入记录一致。
  关键值：`bootcmd=run bootcmd_emmc3`；`bootcmd_deb` = `ext4load mmc 0:2 … /boot/Image` +
  `/boot/cn9130-sophos-xgs87w-sfp10g.dtb` + `/boot/initrd.img` → `booti`；
  `bootargs_deb` = `root=/dev/mmcblk0p2 rootwait rw`；`bootcmd=run bootcmd_deb10g` 的 10G 分支
  （`mvswitch 2 write 9 0 0xd` + `dev_write … f002/2000`）原样保留。
- ⚠️ `bootcmd_deb` 引用的两个文件名在 `p2.img` 里原本不存在（镜像只有 `board.dtb` /
  `initrd.img-<ver>`），已在镜像侧用 hardlink 补齐，见 [07](07-storage.md) §7.4。
- ⚠️ **x86 的 `ttyS2` 是干净的**（2026-11-24 复核）：以 host `115200` 抓，TF-A 全程可读。
  之前判成“乱码/通路不可靠”是 host 侧波特率设错（230400/57600）造成的采样错。
  详见 [08](08-console-access.md) §8.3。
- **当时的“BL31→BL33 复位”结论已在 2026-11-25 被推翻**：停掉 x86 侧
  `xgs-ntb-up.sh` 的 remove/rescan 循环后，U-Boot 正常跑到 `Marvell>>`；
  `l` 不是 U-Boot 的第一个字节，而是下一条 `NOTICE` 的首字符被 UART 重配吃掉。
  完整时间线见 [03](03-boot-chain.md) §3.6。
- **flash/env 侧仍然全部是好的**：mtd0 与参考逐字节一致，env CRC 正常；但真正的问题是
  eMMC 的 **MBR 疑似被裸 ext4 镜像覆盖**，以及 env 被反复 `saveenv` 写坏。两者都已处理：
  前者用 `mbrfix` 写回原厂 MBR，后者用本工具的 `flash-write --offset 0x3F0000`。
  （"MBR 是否真的坏过"存在两种现场记录，`mbrfix` 成功无法分辨；判别方法见
  [09](09-remaining-work.md) §9.2 第 0 步。）
- 现在的剩余动作不是“改 U-Boot”，而是**先只读验证 p2**：挂得上就只改 `bootcmd`，
  挂不上才把 p2.img 写回 `/dev/mmcblk0p2`（见 [09](09-remaining-work.md) §9.2）。
  p3 原厂槽已经能启动。

## 23.8 mtd0 组件表与"心跳桩"诊断

U-Boot 不是独立文件，而是 **Marvell BIN**（BIN 头 + TF-A + BL33）里的一段。实测布局
（`reference/mtd/npu-mtd0-uboot.bin.gz`，0x3F0000 字节）：

| 偏移 | 内容 | 证据 |
|---|---|---|
| 0x000000 | BIN 头：magic `0xB105B002`，字段里有 `0x0005E000`（正好等于 BL31 偏移） | 头部 dump |
| 0x000048 | BL1/BL2 代码；**0x05BFF0 起是 `0xDEC0ADDE` 填充**，到 0x05E000 结束 | 填充魔数 |
| 0x05E000 | 当时标成"BL31 入口"（`mov/movk sctlr_el3` → `isb` → `bl` → `br x0`，典型 PIE 入口）——**心跳桩证伪，不是入口**；更可能是 BIN 头 `0x04` 字段所记的 prologue 大小边界 | capstone 反汇编；ATF 字符串 `Marvell`/`BL31` 在 0x62037/0x624B5 |
| ~0x112000 | BL33 = U-Boot 代码起点附近（`xhci_*` 等 U-Boot 字符串在 0x135000） | 字符串 |
| 0x13B7DC | `U-Boot 2019.10-10.22.03` 版本串；0x13D000 起 `** Bad FIT image` 等 | 字符串 |
| 0x16CF84 | U-Boot 的 control DTB（FDT magic `d00dfeed`） | magic |
| 0x170000+ | 全 `0xFF` | 块统计 |

### 判决实验：把 BL31 入口换成心跳桩

在 **0x5E000** 写 32 字节的 AArch64 桩（TF-A 已把 UART 0xF0512000 配好，桩直接往 THR 写 `X`）：

```asm
movz x0, #0x2000        ; 0xF0512000 = TF-A 控制台
movk x0, #0xf051, lsl #16
mov  w1, #0x58          ; 'X'
loop:  str  w1, [x0]
       movz x2, #0x800, lsl #16
dloop: subs x2, x2, #1
       b.ne dloop
       b    loop
```

```sh
# x86 上，从已验证的备份生成（只改 0x50000 这一个 64 KiB 块）
python3 /tmp/mk-heartbeat.py /var/backups/npu-nor.bin /tmp/mtd0-heartbeat.bin
# sha256 8ab024c4ba6d775641d64e8cdfa51a2aecbc15f4db5c846c4eab8cb6436fe54d
sudo ./mcp2210-nor.py mtd0-restore --cs-pin 0 \
    --backup /var/backups/npu-nor.bin --image /tmp/mtd0-heartbeat.bin \
    --expect-image-sha256 8ab024c4ba6d775641d64e8cdfa51a2aecbc15f4db5c846c4eab8cb6436fe54d \
    --unsafe-mtd0 --commit --yes
# 控制台（x86 /dev/ttyS2 115200）
sudo cat /dev/ttyS2      # 期望：TF-A 输出到 "BL1: Booting BL31" 之后开始刷 X
```

判据：

| 现象 | 结论 | 下一步 |
|---|---|---|
| `X` 持续刷、**不再出现 BootROM** | BL31 之后的复位来自 **BL33（U-Boot）**，改 U-Boot 有意义 | 把桩换成"打印 + 读命令"的最小 loader，或替换整个 BL33 |
| 仍然 3.285 s 回 BootROM、没 `X` | BL31 根本没执行到，复位来自 BL1/BL2/BootROM 的看门狗 | **改 U-Boot 永远无效**，只能改 TF-A 或查硬件 |

回滚（同样只动 0x50000 一块）：

```sh
sudo ./mcp2210-nor.py mtd0-restore --cs-pin 0 --backup /var/backups/npu-nor.bin \
    --image /var/backups/npu-nor.bin --unsafe-mtd0 --commit --yes
```

### 实测结果（2026-11-24）：BIN **没有**完整性校验，但 0x5E000 不是任何入口

心跳桩写入并回读验证（`mtd0 restored and verified`, SHA `8ab024c4…`）后，第一次抓到的是：

```
Booting from SPI NOR flash 0 (0x34)
    Error: Failed boot attempt 04.  error = 0x018      Trying Uart..
```

**当时以为**这是 BootROM 的签名/校验拒绝。**几小时后被推翻**——同一份桩还在芯片里时再启动，控制台是：

```
BootROM - 2.03 … Found valid image at boot position 0x0000
lNOTICE:  Starting binary extension
Setting up Comphy lane 0 as PCIe …  NOTICE:  SVC: DEV ID: CN913x, FREQ Mode: 0xd
```

即：**镜像照样被判定有效、TF-A 照常运行**。所以

- **没有签名/校验和检查**，改字节是被接受的（我先前穷举 CRC/求和/SHA 全部对不上，是因为那个字段根本不是校验和）；
- **0x5E000 不是 BL1/BL2/BL31 的入口**（桩在那里从未被执行；§23.8 上表的"BL31 入口"标注是错的，
  它更可能是 BIN 头 `0x04` 字段所记的"prologue 大小 0x5E000"的边界）；
- 那次 `error = 0x018` 的真实原因是**我们自己的工具把 GP0(flash CS) 留在驱动状态**，
  BootROM 读 flash 时总线被 MCP2210 抢着 → 读到垃圾 → 判定镜像无效。

> ⚠️ **教训（已写进 §23.9）**：`env-write`/`mtd0-restore` 退出时必须确认 MCP2210 恢复了 GPIO
> designation（`npu status` 里 `live_dir` 应该是全输入的上拉值）；否则 BootROM 会在下一次启动时
> 读到垃圾并显示成"镜像错误"，极易误判。写完不要立刻抓串口下结论，先做一次干净的上电。
>
> ⚠️ 心跳桩实验本身也受 x86 rescan 风暴干扰：桩在 0x5E000 没有被执行，不能据此判断
> "UART 注入通道不可用"；4 KiB XMODEM + EOT 的成功已经证明通道至少能收小载荷。

### UART 恢复通道（实测可用）

镜像无效时 BootROM 会 `Trying Uart..`，协议就是 Marvell 的
`u-boot/tools/mrvl_uart.sh`：主机连发 `BB 11 22 33 44 55 66 77`，BootROM 锁定后要求 XMODEM。
实测（x86 的 `/dev/ttyS2`，纯 Python 实现，见 §23.10 的 `mrvl-uart.py`）：

```
phase1 handshake 0x15 after 4352 pattern bytes
```

- 4352 字节（约 0.4 s）就被锁上，握手字节是 `0x15`（XMODEM checksum 模式）；
- 镜像要 4 MiB，115200 下约 7–11 分钟；`F4` 前缀可把速率协商到 460800（约 3 分钟）；
- 用途：**把任意镜像灌进 RAM 运行，完全不碰 flash** —— 这是在 BL33 坏掉的情况下唯一能拿到
  控制权的通道。
- 实现与实测（2026-11-24 深夜，x86 上纯 Python，`/tmp/mrvl-uart.py` + `/tmp/uart-direct.py`）：
  - 顺序必须是 **先 pattern 把它锁住**（锁定后会一直发 `0x15` 等数据），再 XMODEM；
  - 4 KiB 测试文件：`NAK seen after 0.05 s` → `100.0% 4096/4096 10.1 KiB/s` → `EOT -> 0x06` **成功**；
  - 4 MiB 真镜像：传到 **block 192（约 2.4 s）时 NPU 自己复位**，传输中断。
    ⚠️ 这次中断发生在 x86 的 rescan 风暴期间；停掉 rescan 后没有复测 4 MiB 全片，
    所以不能据此断言"通道传不了大文件"。
- **前提**：只有 SPI 镜像是"无效"的时候 BootROM 才留在 UART 模式。镜像有效时，窗口只存在于
  启动早期的几毫秒，`probe` 偶尔能拿到一个 `0x15` 但随即被 SPI 启动打断。所以要反复做 UART
  实验，就得先写一份无效镜像（清 BIN 头 magic），工具里已有 `mk-invalid.py`。
- 4 KiB 载荷实验（把心跳桩放在文件的 `0x48` 或 `0x0`）：XMODEM 都传完且 EOT 被确认，但
  **控制台没有任何输出** → BootROM 的跳转入口既不是"文件 0"也不是"文件 0x48"，
  下一轮要按 BIN 头里的偏移字段（`0x04`/`0x0C`）反推真正的装载/入口地址。

### 当时的推论（已被 2026-11-25 推翻）：~3 s 的"硬件定时复位"

| 观测 | 数值 | 现在的解释 |
|---|---|---|
| 原厂镜像：BootROM → TF-A → 复位，周期间隔 | **3.285 s**（9 个周期一致） | 与 x86 `xgs-ntb-up.sh` 的 2 s remove/rescan 对齐；停掉后 U-Boot 正常到 `Marvell>>` |
| 空/无效镜像：BootROM 4 次失败 → `Trying Uart..` → 复位 | 同样 ~3–5 s 一轮 | 同上；BootROM 的失败重试本来就是这个量级 |
| **纯 BootROM 的 UART 下载过程中**传了 2.4 s 就被复位 | 2.4 s | 当时 x86 仍在 rescan；不能据此说复位源在软件之外 |

所以"复位源在软件之外"这个结论**不成立**。BootROM/BL1 的 watchdog 没有被证明有问题；
真正的复位源是主机侧的 PERST#。保留这张表是为了记住：**在抖动窗口里看到的"稳定周期"
不一定属于被测对象**，先把自己的干扰源停掉再下结论。

## 23.9 故障排查
| 现象 | 处理 |
|---|---|
| RDID 全 `FF` | hold 没生效 / CS 不是 GP0 / NPU 正在驱动总线。先 `npu status`，确认 live `0x0029` 是 HOLD 还是 RELEASE；`info --cs-pin 0` 会自动 hold |
| `permission denied` | `/dev/hidraw0` 是 `root:root 0600`，用 `sudo` |
| `0xF7` | MCP2210 说总线被外部 master 占用；检查 NPU 是否在跑、GP8 是否被拉低 |
| `0xF8` 反复 | 设备忙；工具会重发同一包。长时间不退就 Ctrl-C，重新跑 |
| `0xF8` 卡死（`0x40` 永远 busy） | 上一次读被 **Ctrl-C 打断**，MCP2210 的 SPI 事务停在半路。先发 `0x11 cancel` 再发 `0x80 release` 即可恢复（见下） |
| 整片读 7 分钟，被串口工具超时打断 | 用 `setsid nohup … &` 后台跑，输出重定向到文件，再 `tail`；1 MHz 下 4 MiB 约 7 分钟，`--speed 4M/8M` 在当前固件上会报 `SPI settings echo mismatch`，别指望加速 |
| 地址全对但内容全 `FF` | 读到了未连接/未上电的 flash，或 CS 错。先确认 JEDEC，再 dump |
| `BP=111` / 写失败 | flash 块保护；`env-write --clear-bp`（先确认 WP# 为高） |
| 控制台被 PCIe 日志刷屏 | `sudo systemctl stop xgs-ntb-watch`，`sudo dmesg -n 1` |

## 23.10 参考

- Microchip **DS22288A**（MCP2210 datasheet），第 3 章命令集。
- os-xgs-npu 参考仓库：`src/opnsense/scripts/npuctl/mcp2210.py`、
  `docs/npuep/npu-bring-up.md`（GP0/3/5、hold/release 表、HID 队列坑）。
- 本仓库：[tools/on-x86/mcp2210-nor.py](../tools/on-x86/mcp2210-nor.py)、
  [test_mcp2210_nor.py](../tools/on-x86/test_mcp2210_nor.py)（无硬件模拟测试）、
  [07-storage.md](07-storage.md) §7.1、[05-x86-system.md](05-x86-system.md) §5.3。
