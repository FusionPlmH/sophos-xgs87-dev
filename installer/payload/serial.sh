#!/bin/sh
# 通过 XGS 87 内部的串口（x86 的 /dev/ttyS2，57600 8N1）和 NPU 说话。
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
BAUD=${BAUD:-57600}
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
		_chunk=$(timeout 1 dd bs=1 count=4096 <"$TTY" 2>/dev/null | tr -d '\r')
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
		_SERIAL_BUF="$_SERIAL_BUF$(timeout 1 dd bs=1 count=4096 <"$TTY" 2>/dev/null | tr -d '\r')"
	done
}

serial_send() {
	printf '%s\r' "$*" >"$TTY"
}

serial_open() {
	[ -e "$TTY" ] || { echo "serial: 没有 $TTY" >&2; return 1; }
	stty -F "$TTY" "$BAUD" raw -echo -crtscts 2>/dev/null || true
	_serial_open=1
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
	[ "$_serial_open" = 1 ] && _serial_open=0
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
serial_run() {
	_cmd=$1
	_to=${2:-60}
	_mark="XGS87DONE$$"
	serial_send "$_cmd; echo XGS87\$(echo DONE)$$"
	if ! serial_read_until "$_mark" "$_to"; then
		printf '%s\n' "$_SERIAL_BUF"
		echo "serial: 等 $_mark 超时（命令：$_cmd）" >&2
		return 1
	fi
	printf '%s\n' "$_SERIAL_BUF" | grep -v -e "$_mark" -e 'XGS87$(echo DONE)' || true
	return 0
}