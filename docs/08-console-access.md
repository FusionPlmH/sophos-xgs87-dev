# 08 · 进机器的方式（Console / SSH）

> 🏷 **状态（2026-11-23 复核）**：✅ **全部实测**（本文 2026-11-23 整篇重写）：micro-USB 也是 115200 不是 38400、NPU 是 Debian 不是 Buildroot、ttyS2 host 侧要 57600。

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
| x86（网络） | `ssh root@192.168.0.50` | 公钥（`id_xgs_ed25519`） |
| NPU（网络） | `ssh root@192.168.0.66` | 公钥 |
| x86 控制台 | `COM5` 115200 | `admin` / `P@ssw0rd`，`sudo` 免密 |
| NPU 控制台 | **x86 的 `/dev/ttyS2`**，host 侧设 **57600** | `root` / `openwrt123` |

## 8.3 NPU 控制台的波特率是个坑：host 侧要设 57600

NPU 的 `bootargs` 写的是 `console=ttyS0,115200n8`，但从 x86 这头必须设 **57600** 才能解出干净文字：

```
stty -F /dev/ttyS2 115200 ...  → 0~2 字节乱码
stty -F /dev/ttyS2 57600  ...  → 干净的 "xgs87-npu login:"
```

原因：x86 这颗 16550 的 `base_baud` 被报成 115200，而板上实际晶振是它的**两倍**，
内核按 115200 算出的 divisor 让线路速率翻倍。软件写 57600 = 线上 115200。
换句话说这条链路**实际就是 115200**，只是软件刻度是斜的。

## 8.4 从 x86 操作 NPU 控制台

```sh
stty -F /dev/ttyS2 57600 raw -echo -crtscts
printf '\r' > /dev/ttyS2            # 唤出 login:
timeout 5 cat /dev/ttyS2            # 看输出
printf 'root\r' > /dev/ttyS2 ; sleep 1
printf 'openwrt123\r' > /dev/ttyS2
```

长期挂后台（**只能有一个读者**）：

```sh
setsid cat /dev/ttyS2 > /tmp/npu.log 2>&1 < /dev/null &
```

现成工具：[tools/on-x86/npu-console.sh](../tools/on-x86/npu-console.sh)（在 x86 上跑，`sudo npu-console login`
然后 `sudo npu-console '命令'`）。

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

## 8.6 网络怎么来的（现状）

不是临时 `ifconfig` 了，全部由 systemd 单元管，细节见 [20](20-lan-over-vntb.md)：

| 位置 | 单元 |
|---|---|
| NPU | `xgs-ports-up` → `xgs-vntb` → `xgs-mgmt-bridge` → `xgs-lan-uplink` → `xgs-lan-dhcp` |
| x86 | `xgs-ntb` → `xgs-ntb-watch`，地址由 `systemd-networkd` 的 `31-house-lan.network` 取得 |

## 8.7 备份与救砖

| 场景 | 手段 |
|---|---|
| NPU 系统坏了 | `/dev/ttyS2` 进 U-Boot → `bootcmd_emmc2` 起另一个槽 |
| NPU U-Boot 坏了 | x86 的 MCP2210（USB-SPI）写 SPI NOR，或 JTAG |
| x86 系统坏了 | UEFI 启动菜单，或换 eMMC / U 盘启动 |
| x86 卡在 GRUB 命令行 | 串口发 ESC 逼回 `grub>`，再发 `normal` + 回车 |
| 交换机模块改坏了 | 面板口全消失但 NPU 还活着 → 用 `.ko.xz.orig` 回滚（见 20 §20.9） |
| 两台都失联 | 断电源 5 秒。注意**只有一条电源线**，断电两台一起下 |
