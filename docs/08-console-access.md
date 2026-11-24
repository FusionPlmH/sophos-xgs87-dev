# 08 · 进机器的方式（Console / SSH）

> 🏷 **状态（2026-11-25 复核）**：✅ **全部实测**：micro-USB 也是 115200 不是 38400、NPU 是 Debian 不是 Buildroot。
> **ttyS2 的波特率**：TF-A / U-Boot / p3 / 当前 Debian 都是 115200；老 `image/` 系统的 16550 是 2x
> （host 57600 = 线上 115200），只适用于那套内核。2026-11-24 那个"BL31→BL33 复位"是 x86 的
> remove/rescan 风暴造成的，已推翻；见 [03 §3.6](03-boot-chain.md)。

## 8.1 物理口

| 口 | 用途 | 速率 |
|---|---|---|
| RJ45（面板标 CONSOLE） | **x86 控制台** | 115200 8N1 |
| micro-USB（前面板旁） | x86 控制台（Prolific PL2303GL，`067b:23a3`） | **115200 8N1** |
| 4×RJ45（面板 1-4） | 数据口 | 1G |
| SFP F1 | 光口 | 10G（实测 10GBASE-R，见 14） |
| USB-A | x86 的 USB（EHCI） | 2.0 |

> **RJ45 和 micro-USB 是同一个 x86 `ttyS0` 的二选一复用**，不是两个 UART。
> 插上 micro-USB 时 RJ45 那路就没有输出。两者都是 **115200**（早期记的 38400 是错的）。
> RJ45 是 Cisco 交叉线序。

## 8.2 登录

| 目标 | 方法 | 账号 |
|---|---|---|
| x86（`image/` 系统） | `ssh admin@10.234.56.2`（LAN）或 WAN 的 DHCP 地址 | `admin` / `P@ssw0rd` |
| NPU（`image/` 系统） | `ssh admin@10.234.56.1`（LAN） | `admin` / `P@ssw0rd`；p2 待重刷时此路不通 |
| 旧手工系统 | `ssh root@192.168.0.50` / `.66` | 公钥 `id_xgs_ed25519`（历史） |
| x86 控制台 | `COM5` 115200 | `admin` / `P@ssw0rd`（`image/` 产出的系统；现网旧系统用的是本地账号） |
| NPU 控制台（TF-A） | **x86 的 `/dev/ttyS2`**，host 侧设 **115200**（当前 Debian） | — |
| NPU 控制台（U-Boot / p3 Linux） | **PC 的 CH340（COM7）115200**，或老 `image/` 的 ttyS2 host 57600 | p3 原厂 `root` / `openwrt123`；`image/` 产出的是 `admin` / `P@ssw0rd` |

> `image/` 里 `root` 是 `passwd -l` 锁死的，sshd 也 `PermitRootLogin no`，登录一律走 `admin` + `sudo`
> （`sudo` 要密码）。见 [image/release-x86.md](../image/release-x86.md)。

## 8.3 NPU 控制台的波特率：三段都是 115200

**线上**三个阶段的速率不同：

| 阶段 | 线上速率 | 当前 Debian 的读法 |
|---|---|---|
| TF-A | 115200 | `stty -F /dev/ttyS2 115200` 干净（2026-11-23 晚实测：DDR training → `NOTICE: Cold boot`） |
| U-Boot | 115200 | 和 TF-A 同速率；U-Boot 只在成功启动时打印。2026-11-24 的“BL31→BL33 复位”已推翻，见 [03 §3.6](03-boot-chain.md) |
| p3 Linux | 115200 | 同上 |

原因：U-Boot 和 TF-A 都是 115200；之前把 230400 误判成 U-Boot 的波特率，实际是 TF-A 数据在 230400 采样下的 2x 乱码。
`bootargs` 里写的 `console=ttyS0,115200n8` 是**标称值**，线上也是 115200。

老 `image/` 系统里 x86 这颗 16550 的 `base_baud` 被报成 115200、板上晶振却是两倍，
所以那套内核要 host 57600 才等于线上 115200；**当前 Debian 13 不是这样**，host 115200 就是线上 115200。

PC 侧工具：[tools/on-pc/npu-console.py](../tools/on-pc/npu-console.py)（`--baud 115200`，
`--interrupt` 可在 U-Boot `bootdelay=3` 内停在 `=>`）。

> ⚠️ **不要把 CH340 插到 x86 的 USB**：CH340 和内部 MCP2210 在同一个 USB hub 上，
> 插上 CH340 的瞬间 MCP2210 会被 disconnect（`usb 1-1.3: USB disconnect`），救砖工具直接失联。
> NPU 控制台统一走 x86 的 `/dev/ttyS2`。

## 8.4 从 x86 操作 NPU 控制台

TF-A 阶段（当前 Debian，host 115200）：

```sh
stty -F /dev/ttyS2 115200 raw -echo -crtscts
timeout 5 cat /dev/ttyS2            # DDR training / NOTICE: Cold boot
```

U-Boot / p3 Linux 阶段（115200；U-Boot 只在启动成功时打印）：

```sh
# PC 上，CH340（COM7）
python tools/on-pc/npu-console.py --port COM7 --baud 115200 --seconds 30 --interrupt
python tools/on-pc/npu-console.py --port COM7 --baud 115200 --send 'mmc list' --send 'ext4ls mmc 0:3 /boot'
```

p3 内核登录后同样是 115200：`xgs87-npu login:`，`root` / `openwrt123`。

长期挂后台（**只能有一个读者**）：

```sh
setsid cat /dev/ttyS2 > /tmp/npu.log 2>&1 < /dev/null &
```

现成工具：[tools/on-x86/npu-console.sh](../tools/on-x86/npu-console.sh)（默认 host 115200；
老 `image/` 内核用 `BAUD=57600`）。

维护 U 盘的 **菜单 4（NPU 串口）** 会跑 `installer/payload/npu-console.sh`：
`picocom -b 115200 /dev/ttyS2`（老内核用 `BAUD=57600`；没有 picocom 就用 `cat` 双向中继，按 Ctrl-D 退出）。

> 不需要 chroot 进内置盘的系统：`/dev/ttyS2` 属于 x86 这块板子，U 盘系统、装好的 Debian、
> 甚至 BIOS 之后任何跑在 x86 上的系统都能开它。**唯一限制是同一时刻只能有一个读者**（见 8.5）。

## 8.5 自动化时的坑（全部踩过）

1. **`/dev/ttyS2` 同一时刻只能有一个读者**。两个 `cat` 会把字节流切成乱码 —— 这是最容易
   浪费时间的一条，看到"全是乱码"先查 `ps aux | grep ttyS2`。
2. **登录要状态机**，不能靠固定延时。上一轮残留的 `Password:` 会让你的用户名被当成密码、
   命令被当成用户名，然后循环出 `Login incorrect`。正确做法：等 `login:` 出现发用户名，
   等 `Password:` 出现发密码。
3. **pyserial 打开端口会清接收缓冲**（`PurgeComm`）。短连接"打开→发→读→关"会丢数据，
   尤其是对端正在输出的场景。
4. **行宽回绕**：超过 ~80 字符终端会回绕重显，看起来像乱码，实际内容是对的（用 `md5sum` 核对）。
5. **传文件别用 heredoc**，会缺字符。用 `base64` 分块 + 校验，或者干脆走网络。
6. **`stty -echo` 能救你**：读长输出前先在 NPU 侧关掉回显，否则命令回显和输出会交错打乱。
7. **多行命令必须压成一行再发**（2026-11-25 踩到，花了两个小时）：
   `x86-console.py` 原来的做法是把整段命令 + `; echo __XGS_RC__$?` 一起发出去，
   多行命令就会变成

   ```
   ...
   echo "最后一行"
   ; echo __XGS_RC__$?
   ```

   最后一行的 `;` 开头是 **bash 语法错误**，哨兵永远不打印 → 工具一直等到超时。
   表现极具误导性：**命令其实执行了，但你看不到任何输出，像是"卡死"**。
   现在 `run()` 会用 `; ` 把多行压成一行再发。自己写类似工具时注意这一点。
8. **内核刷屏会把控制台协议打烂**：x86 的 ttyS0 就是我们的控制台，而
   `xgs-ntb.service` 失败重试、PCIe 端点抖动都会往它上面打日志，命令回显和输出被
   切碎，哨兵匹配时灵时不灵。动手之前先静音：

   ```sh
   sudo sh -c 'echo 1 > /proc/sys/kernel/printk'
   ```

9. **往机器里推大文件**（没有网络时唯一可行的手段，实测 100 KB 源码要走 ~20 s）：

   ```sh
   # PC 端：gzip 再 base64，按 2000 字节切块（tty 单行上限约 4 KiB）
   gzip -9c tool.py | base64 -w0 > tool.b64   # 分块后逐片 printf >> /tmp/t.b64
   # 远端：解码 + 校验
   base64 -d /tmp/t.b64 | gunzip > /tmp/tool.py && sha256sum /tmp/tool.py
   ```

   推之前 `stty -echo`（省一半流量），推完 `stty echo`；**一定要比 sha256**，
   串口传文件出错是静默的。100 KB 的 `mcp2210-nor.py` 压完 25 KB、base64 后 33.5 KB，
   24 条命令、约 20 秒完成。

10. **U-Boot 提示符下"命令不存在"多半是假象**（2026-11-25 踩到，一度被记成"这份 `help` 是假的、
    U-Boot 只能跑 `bootcmd`"）：某次排障里 `help` 明明列出 `mmc`/`ext4ls`/`run`，敲进去却全回
    `Unknown command`，而同一台机器 `bootcmd` 每次都能从 p3 启动。真实原因是那一轮 `/dev/ttyS2`
    上的输入正被复位风暴打断，命令根本没完整送进 U-Boot（`bootcmd` 是 U-Boot 自己解析的字符串，
    不经串口，所以不受影响）。判别办法：先 `echo` 一个短串看回显是否完整、停掉 x86 侧的
    remove/rescan，再用 `npu-uboot.py` 一行一行敲。**不要因为一次 `Unknown command` 就断定
    命令集缺失** —— `bootcmd` 里的 `run`/`ext4load` 能跑，就说明命令是有的。

## 8.6 网络怎么来的（现状）

不是临时 `ifconfig` 了，全部由 systemd 单元管，细节见 [20](20-lan-over-vntb.md)：

| 位置 | 单元 |
|---|---|
| NPU | `xgs-ports-up` → `xgs-vntb` → `xgs-net-up` → `xgs-dhcp` |
| x86 | `xgs-ntb` → `xgs-ntb-watch`，地址由 `systemd-networkd` 的 `100-wan.network`（DHCP）/ `200-lan.network`（静态）给 |

## 8.7 备份与救砖

| 场景 | 手段 |
|---|---|
| NPU 系统坏了 | 用 **x86 的 `/dev/ttyS2`（115200）** 在 `bootdelay=3` 内发空格进 U-Boot → `bootcmd_emmc2` 起另一个槽；PC 的 CH340（COM7）只接了 RX，只能看日志 |
| NPU U-Boot 坏了 | x86 的 MCP2210（USB-SPI）写 SPI NOR，或 JTAG |
| x86 系统坏了 | UEFI 启动菜单，或换 eMMC / U 盘启动 |
| x86 卡在 GRUB 命令行 | 串口发 ESC 逼回 `grub>`，再发 `normal` + 回车 |
| 交换机模块改坏了 | 面板口全消失但 NPU 还活着 → 用 `.ko.orig` 回滚（模块不压缩，见 20 §20.9） |
| 两台都失联 | 断电源 5 秒。注意**只有一条电源线**，断电两台一起下 |
