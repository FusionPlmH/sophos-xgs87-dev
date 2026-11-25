#!/bin/sh
# 通过 XGS 87 内部的串口（x86 的 /dev/ttyS2，115200 8N1）和 NPU 说话。
#
# 老 image 内核的 16550 是 2x 分频（host 57600 = 线上 115200）；当前 Debian
# 用 115200 即可，要兼容老系统就 `BAUD=57600 serial.sh`。
#
# 维护盘用它当"控制通道"：一条命令一条命令地敲，把 NPU 的回显收回来。
# 数据不走这里（115200 的线跑 190 MB 要几个小时），数据走网线/vNTB。
#
#   . serial.sh
#   serial_open                      # 打开 + 登录
#   serial_run 'ip -br a'            # 跑一条命令，打印输出
#
# 注意：/dev/ttyS2 同一时刻只能有一个读者，所以用完要 serial_close。
set -u

TTY=${TTY:-/dev/ttyS2}
BAUD=${BAUD:-115200}
NPU_USER=${NPU_USER:-admin}
NPU_PASS=${NPU_PASS:-P@ssw0rd}

# U-Boot 的提示符。这台原厂 U-Boot 是 "Marvell>> "，不是主线的 "=> "：
# 2026-11-25 实测，之前所有只等 "=> " 的写法每次都白等满整个超时，于是
# npu-rescue.sh 判"没停住"、lzma 那次实验也永远等不到提示符。两个都认。
UBOOT_PROMPT=${UBOOT_PROMPT:-'Marvell>> '}
UBOOT_PROMPT_ALT=${UBOOT_PROMPT_ALT:-'=> '}

_serial_open=0

# 读，直到出现 $1（纯字符串匹配，不是正则）或者 $2 秒超时。
# 可选的 $3 是"另一个也算数的标记"，用来同时认两种提示符。
# 输出写进 $_SERIAL_BUF，成功返回 0。
serial_read_until() {
	_pat=$1
	_to=${2:-10}
	_pat2=${3:-}
	_SERIAL_BUF=
	_end=$(( $(date +%s) + _to ))
	while [ "$(date +%s)" -le "$_end" ]; do
		_chunk=$(timeout 1 dd bs=1 count=4096 <&3 2>/dev/null | tr -d '\r')
		_SERIAL_BUF="$_SERIAL_BUF$_chunk"
		case "$_SERIAL_BUF" in
		*"$_pat"*) return 0 ;;
		esac
		if [ -n "$_pat2" ]; then
			case "$_SERIAL_BUF" in
			*"$_pat2"*) return 0 ;;
			esac
		fi
	done
	return 1
}

# 攒 $2 秒的输出（没有期待的模式时用）
serial_drain() {
	_to=${1:-2}
	_SERIAL_BUF=
	_end=$(( $(date +%s) + _to ))
	while [ "$(date +%s)" -lt "$_end" ]; do
		_SERIAL_BUF="$_SERIAL_BUF$(timeout 1 dd bs=1 count=4096 <&3 2>/dev/null | tr -d '\r')"
	done
}

serial_send() {
	printf '%s\r' "$*" >&3
}

# 一个 RDWR 的 fd 撑住整个会话。
#
# 以前每次读写都各自 open 一次 /dev/ttyS2（`printf > $TTY`、`dd < $TTY`），
# 端口上还留着 hupcl：关掉 fd 就掉一次 DTR，再打开时 UART 的 FIFO 里那段已经
# 丢了。实测（2026-11-25，机器刚装好）：NPU 明明停在 `xgs-debian-npu login:`，
# serial_login 连发 5 次回车都读不到它，安装器的串口兜底因此直接判"NPU 没起来"。
# 改成一直开着同一个 fd，读写都走它，并在 stty 里加 -hupcl。
# 只把端口打开（常开 fd 3 + 关掉 RTS），不发任何东西、不登录。
# 给"对面不是 Linux"的场合用：U-Boot 提示符、刚复位完还没起系统的 NPU。
serial_raw_open() {
	[ -e "$TTY" ] || { echo "serial: 没有 $TTY" >&2; return 1; }
	[ "$_serial_open" = 1 ] && return 0
	stty -F "$TTY" "$BAUD" raw -echo -crtscts clocal -hupcl 2>/dev/null || true
	exec 3<>"$TTY" || { echo "serial: 打不开 $TTY" >&2; return 1; }
	_serial_open=1
	# 这块板子的 UART 收发器拿 RTS 当方向控制：RTS 拉低才把 x86 的 TX 放出去。
	# 不清掉的话只能读不能写（2026-11-25 实测，见 docs/05「控制台」）。
	# stty 表达不了 RTS 引脚，只能 ioctl；fd 3 已经开着了，这里再用一个 fd
	# 清一次不会把端口的调制解调器线重置掉。
	python3 -c 'import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
fcntl.ioctl(fd, 0x5417, struct.pack("i", 0x004))
os.close(fd)' "$TTY" 2>/dev/null || true
	return 0
}

serial_open() {
	serial_raw_open || return 1
	# 一直按回车直到看见 login:（NPU 可能已经在提示符上，也可能刚重启）
	i=0
	while [ $i -lt 5 ]; do
		serial_send ""
		serial_read_until "login:" 2 && return 0
		i=$((i + 1))
	done
	echo "serial: 等不到 NPU 的 login: 提示（NPU 没起来？）" >&2
	return 1
}

serial_close() {
	if [ "$_serial_open" = 1 ]; then
		exec 3<&-
		_serial_open=0
	fi
	return 0
}

# 登录（幂等：如果已经在提示符上，login: 不会出现，按超时算失败，由调用方决定）
serial_login() {
	serial_open || return 1
	serial_send "$NPU_USER"
	serial_read_until "assword" 5 || {
		echo "serial: 没等到密码提示" >&2
		return 1
	}
	serial_send "$NPU_PASS"
	serial_read_until '$' 8 || serial_read_until '#' 3 || {
		echo "serial: 登录失败" >&2
		return 1
	}
	return 0
}

# 跑一条命令，等一个唯一标记来判断命令结束。
#
# 标记不能在发出去的命令里出现：NPU 的 tty 会把输入回显回来，直接等
# "XGS87DONE4711" 会立刻匹配到我们自己敲的那一行。所以发出去的是
#   printf 'XGS87%s%s\n' DONE 4711
# 回显里是带 %s 的原文，只有真正执行完才有光秃秃的 XGS87DONE4711。
#
# 以前这里写的是 `echo XGS87$(echo DONE)$$`，等的是本机的 $$ —— 而远端展开的
# 是它自己的 PID，两边永远不相等，于是每次调用都要白等满整个超时再假失败
# （2026-11-25 复查：串口兜底"白跑一趟"就是这个）。现在标记由本机生成、原样
# 作为参数发过去。
serial_run() {
	_cmd=$1
	_to=${2:-60}
	_tag=$$
	_mark="XGS87DONE$_tag"
	serial_send "$_cmd; printf 'XGS87%s%s\\n' DONE $_tag"
	_SERIAL_BUF=
	_answered=0
	_end=$(( $(date +%s) + _to ))
	while [ "$(date +%s)" -le "$_end" ]; do
		_SERIAL_BUF="$_SERIAL_BUF$(timeout 1 dd bs=1 count=4096 <&3 2>/dev/null | tr -d '\r')"
		case "$_SERIAL_BUF" in
		*"$_mark"*) break ;;
		esac
		if [ "$_answered" = 0 ]; then
			case "$_SERIAL_BUF" in
			*"password for"*)
				serial_send "$NPU_PASS"
				_answered=1
				;;
			esac
		fi
	done
	case "$_SERIAL_BUF" in
	*"$_mark"*) ;;
	*)
		printf '%s\n' "$_SERIAL_BUF"
		echo "serial: 等 $_mark 超时（命令：$_cmd）" >&2
		return 1
		;;
	esac
	printf '%s\n' "$_SERIAL_BUF" | grep -v -e "$_mark" -e "XGS87%s%s" || true
	return 0
}

# serial_uboot <uboot 命令> [秒]
#
# U-Boot 的提示符不会跑 `; printf …` 这种 shell 尾巴，所以 serial_run 在这里
# 只会得到一串 "Unknown command"。U-Boot 的命令都是同步的（ext4load / unzip /
# loady 都会自己把结果打完才回 "=> "），于是这里只做一件事：发出去，然后等
# $2 秒把输出收完。返回值只能表示"发成功"，判断成败交给调用方 grep 输出。
serial_uboot() {
	serial_send "$1"
	serial_drain "${2:-5}"
	printf '%s\n' "$_SERIAL_BUF"
	return 0
}