#!/bin/sh
# 让 NPU 停在它自己的 U-Boot 提示符上（"=> "）。
#
# U-Boot 的 bootdelay 只有 3 秒，而且必须"一边重启一边敲空格"—— 串口只有一个读者，
# 所以这件事得一个脚本干完：自己发 reboot，然后连续敲空格 20 秒，最后把串口交给
# picocom 交互。docs/03 §3.4 里说的"小脚本"就是这个。
#
# 到了 "=> " 之后能做的事（板上 U-Boot 2019.10，原厂环境变量都在）：
#   mmc dev 0; ext4load mmc 0:2 $kernel_addr_r /boot/Image      # 验证分区可读
#   setenv bootcmd 'run bootcmd_emmc1'; saveenv                  # 换回 p1 上的系统
#   setenv bootcmd 'run bootcmd_deb10g'; saveenv                 # 换回 p2 上的 Debian
#   printenv / setenv bootargs … / mmc part
# 它读不到 x86 的 U 盘，所以"装整份 rootfs"别走这条路（见 release-usb 里的对比表）。
set -u

TTY=${TTY:-/dev/ttyS2}
BAUD=${BAUD:-57600}
NPU_PASS=${NPU_PASS:-P@ssw0rd}
SPAM_SECS=${SPAM_SECS:-20}
INTERACTIVE=${INTERACTIVE:-1}

[ -e "$TTY" ] || { echo "找不到 $TTY" >&2; exit 1; }

echo
echo "== 让 NPU 重启并停在 U-Boot（$TTY @ $BAUD，敲 ${SPAM_SECS}s 空格）"
stty -F "$TTY" "$BAUD" raw -echo -crtscts 2>/dev/null || true

# 它现在可能停在 shell 上，也可能已经停在 "=> "。前者要 sudo 密码（从 tty 读）。
printf 'sudo -S systemctl reboot\r' >"$TTY"
sleep 1
printf '%s\r' "$NPU_PASS" >"$TTY"

i=0
n=$(( SPAM_SECS * 7 ))
while [ "$i" -lt "$n" ]; do
	printf ' ' >"$TTY"
	i=$((i + 1))
	sleep 0.15 2>/dev/null || sleep 1
done
printf '\r' >"$TTY"
echo "== 空格敲完，串口交给你（看到 '=> ' 就是停住了；U-Boot 里 Ctrl-C 之类不走本地信号）"

[ "$INTERACTIVE" = 1 ] || exit 0
if command -v picocom >/dev/null 2>&1; then
	exec picocom -q -b "$BAUD" "$TTY"
fi
echo "没有 picocom：用 cat 中继，Ctrl-D 退出"
( cat "$TTY" ) &
relay=$!
trap 'kill "$relay" 2>/dev/null' EXIT INT TERM
cat >"$TTY"
kill "$relay" 2>/dev/null