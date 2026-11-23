#!/bin/sh
# 打开 NPU 的串口控制台：x86 上的 /dev/ttyS2，57600 8N1。
#
# 这条线是主板内部走的（16550 的基准是标称值的两倍，所以"线上 115200、软件
# 57600"），NPU 起不来、SSH 不通的时候它是唯一能进去说话的地方。
#
# 不需要 chroot 到内置盘的系统里：ttyS2 属于 x86 这块板子，U 盘系统自己就能开。
set -u

TTY=${TTY:-/dev/ttyS2}
BAUD=${BAUD:-57600}

if [ ! -e "$TTY" ]; then
	echo "找不到 $TTY —— 这台机器上没有那路串口？" >&2
	exit 1
fi

echo
echo "== NPU 控制台：$TTY @ $BAUD"
echo "   有 picocom 的话退出是 Ctrl-A 再 Ctrl-X；没有的话按 Ctrl-D 回来。"
echo "   提示符是 xgs87-npu login:（账号 admin / P@ssw0rd）。"
echo

# picocom 会自己管 tty 的 raw/回显/信号，比手搓中继靠谱得多。
if command -v picocom >/dev/null 2>&1; then
	exec picocom -q -b "$BAUD" "$TTY"
fi

# 退路：后台 cat 把 NPU 的输出打到屏幕，前台 cat 把键盘送过去。
stty -F "$TTY" "$BAUD" raw -echo 2>/dev/null || true
( cat "$TTY" ) &
relay=$!
trap 'kill "$relay" 2>/dev/null' EXIT INT TERM
cat > "$TTY"
kill "$relay" 2>/dev/null