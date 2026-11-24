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

_serial_open=0

# 读，直到出现 $1（正则不支持的，纯字符串匹配）或者 $2 秒超时。
# 输出写进 $_SERIAL_BUF，成功返回 0。
serial_read_until() {
	_pat=$1
	_to=${2:-10}
	_SERIAL_BUF=
	_end=$(( $(date +%s) + _to ))
	while [ "$(date +%s)" -le "$_end" ]; do
		_chunk=$(timeout 1 dd bs=1 count=4096 <&3 2>/dev/null | tr -d '\r')
		_SERIAL_BUF="$_SERIAL_BUF$_chunk"
		case "$_SERIAL_BUF" in
		*"$_pat"*) return 0 ;;
		esac
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
serial_open() {
	[ -e "$TTY" ] || { echo "serial: 没有 $TTY" >&2; return 1; }
	if [ "$_serial_open" != 1 ]; then
		stty -F "$TTY" "$BAUD" raw -echo -crtscts clocal -hupcl 2>/dev/null || true
		exec 3<>"$TTY" || { echo "serial: 打不开 $TTY" >&2; return 1; }
		_serial_open=1
	fi
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
# "XGS87DONE<pid>" 会立刻匹配到我们自己敲的那一行。所以发出去的是
#   echo XGS87$(echo DONE)$$
# 回显里是那个 $(...) 原文，只有真正执行完才有光秃秃的 XGS87DONE<pid>。
#
# sudo 在串口上会问密码，这里替它回答一次（$NPU_PASS）。
serial_run() {
	_cmd=$1
	_to=${2:-60}
	_mark="XGS87DONE$$"
	serial_send "$_cmd; echo XGS87\$(echo DONE)$$"
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
	printf '%s\n' "$_SERIAL_BUF" | grep -v -e "$_mark" -e 'XGS87$(echo DONE)' || true
	return 0
}