# 08 · 进机器的方式（Console / SSH）

## 8.1 物理口

| 口 | 用途 | 速率 |
|---|---|---|
| RJ45（标 CONSOLE，最右边） | **x86 控制台** | 115200 8N1 |
| micro-USB（前面板旁边） | x86 控制台（Prolific PL2303，`067b:23a3`） | **38400 8N1** |
| 4×RJ45（面板 1-4） | 数据口 | 1G |
| SFP F1 | 光口 | 1G（待确认是否 2.5G） |
| USB-A | x86 的 USB（EHCI） | 2.0 |

> 两个 console 口同时只会有优先级高的那个（micro-USB 优先）。RJ45 是 Cisco 交叉线序。

## 8.2 登录

| 目标 | 方式 |
|---|---|
| x86 Debian | 串口 `COM5` 115200，登录 `admin`（密码在你自己手里） |
| NPU Buildroot | **x86 的 `/dev/ttyS2`** 115200，登录 `marvell` 或 `root`，**空密码** |

NPU 登录后的提示：

```
Welcome to Buildroot Marvell
marvell login: root
~#
```

## 8.3 从 x86 打开 NPU 控制台

```sh
stty -F /dev/ttyS2 115200 raw -echo -ixon -crtscts
printf '\r' > /dev/ttyS2            # 显示 login prompt
timeout 5 cat /dev/ttyS2            # 看输出
printf 'root\r' > /dev/ttyS2        # 登录（空密码再回车一次）
```

或者是长期挂在后台：

```sh
setsid cat /dev/ttyS2 > /tmp/npu.log 2>&1 < /dev/null &
# 之后 tail -f /tmp/npu.log 看 NPU 的输出
```

## 8.4 自动化时的坑（重要）

1. **pyserial 打开端口会清空接收缓冲**（`PurgeComm`）。用"打开→发命令→读→关闭"的短连接
   模式会**丢数据**，尤其是 NPU 在重启/输出的场景。正确做法是**常驻一个进程**持续读，
   命令通过队列文件投递。
2. **UART 没有流控**：115200 下 Python `print` 太快也会丢字符；一次只发一行、每行等回显。
3. **Linux 控制台的行宽**：超过 ~80 字符会被终端回绕并重新回显，看起来像乱码，
   但实际内容是正确的（用 `md5sum` 校验文件即可确认）。
4. **heredoc 走串口传文件容易缺字符**（我们实测 1464 B 的脚本传过去只剩 1417 B）。
   要么用 `base64` 分块 + 校验和，要么干脆走网络。
5. **NPU 上 `dhcp`/`getty` 会在登录前就打印 prompt**，第一次发 `\r` 看不到东西是正常的。

## 8.5 开网络（临时）

NPU 上：

```sh
mount -o remount,rw /
ifconfig eth0 192.168.1.1 netmask 255.255.255.0 up
# 交换机要先在 U-Boot 里配过（见 06）
```

PC 侧：给接面板口的网卡配 `192.168.1.2/24`。

> 如果 PC 上装了 **Tailscale 且订阅了 `192.168.1.0/24` 子网路由**，它 metric 0 会抢走
> 这条路由，导致 ping/ssh 全走隧道。排查方法：`Test-NetConnection` 看 `SourceAddress`，
> 或 `Get-NetRoute -DestinationPrefix 192.168.1.0/24`。

## 8.6 永久开 SSH（NPU）

```sh
mount -o remount,rw /
printf 'openwrt123\nopenwrt123\n' | passwd root
grep -q 'PermitRootLogin yes' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
/etc/init.d/S50sshd restart
# 公钥
mkdir -p /root/.ssh; echo 'ssh-ed25519 AAAA… xgs' >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
```

> 原厂 `sshd_config` 里 `PermitRootLogin` 是注释掉的（默认 `prohibit-password`），
> 所以**公钥认证本来就能用**；只有密码登录需要显式打开。
> 注意 Windows 自带的 OpenSSH 客户端在 `Postponed publickey` 之后会自己断开
> （服务端日志：`Connection reset by authenticating user`），用 paramiko/PuTTY 就正常。

## 8.7 备份与救砖

| 场景 | 手段 |
|---|---|
| NPU 系统坏了 | 串口进 U-Boot → `bootcmd_emmc2` 起另一个槽 |
| NPU U-Boot 坏了 | x86 的 MCP2210（USB-SPI）写 SPI NOR，或 JTAG |
| x86 系统坏了 | UEFI 启动菜单，或者换 eMMC / U 盘启动 |
| 交换机配乱了 | 断电重启（U-Boot 不配交换机，重新跑 `sw_init`） |
