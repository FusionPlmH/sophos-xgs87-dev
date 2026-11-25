#!/bin/sh
# vNTB 链路：跑一次、判一次、必要时动一次，然后退出。由 xgs-ntb-watch.timer 每 2 秒
# 拉起一次。
#
# 为什么不是常驻循环（这里是三次真机踩坑后的结论）：
#   试过三种常驻写法 —— sleep 轮询、udevadm+ip monitor 写同一个 FIFO、bash 的
#   read -t 1 -u 5 —— 都会在某次异常之后**卡死在 wait() 里**不再往下走，进程还在、
#   systemd 看着 active、journal 里最后一条日志完全正常，于是"看起来在跑，其实早停了"。
#   改成 oneshot + timer：每一拍都是全新的进程，不存在"上一拍留下的死锁"；
#   systemd 还用 TimeoutStartSec 兜底，卡住就杀掉，2 秒后照常来下一拍。
#
# 状态（冷却时间戳）放在 /run 里，进程退出不丢。
set -u
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

PEER=${PEER:-10.234.56.1}
PLUMB_CD=${PLUMB_CD:-2}			# 重建协议栈的间隔
BIND_CD=${BIND_CD:-2}
STRICT_RELOADS=${STRICT_RELOADS:-2}	# 重建几次无效 -> remove+rescan
STRICT_CD=${STRICT_CD:-20}
RESCAN_CD=${RESCAN_CD:-2}
RETRAIN_AFTER=${RETRAIN_AFTER:-120}
RETRAIN_CD=${RETRAIN_CD:-300}
WATCH_LOG=${WATCH_LOG:-/var/log/xgs-ntb-watch.log}
STATE=${STATE:-/run/xgs-ntb}
# shellcheck disable=SC1091
[ -r /etc/default/xgs-ntb-watch ] && . /etc/default/xgs-ntb-watch

mkdir -p "$STATE"

log() {
	echo "xgs-ntb-watch: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t xgs-ntb-watch "$*"
}

st() { # st <名字> -> 秒级时间戳（没有就 0）
	v=$(cat "$STATE/$1" 2>/dev/null) || v=0
	echo "${v:-0}"
}
sets() { echo "$2" >"$STATE/$1" 2>/dev/null || true; }

find_epf() {
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x1957 ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = 0x0809 ] || continue
		PCI_DEV=$d
		return 0
	done
	return 1
}

pci_driver() {
	[ -e "$1/driver" ] || return 0
	d=$(readlink -f "$1/driver" 2>/dev/null) || return 0
	echo "${d##*/}"
}

ntb_iface() {
	for n in /sys/class/net/*; do
		dev=${n##*/}
		[ "$dev" = lo ] && continue
		drv=$(timeout 3 ethtool -i "$dev" 2>/dev/null | sed -n 's/^driver: //p')
		[ "$drv" = ntb_netdev ] && { echo "$dev"; return 0; }
	done
	return 1
}

# 把整条链路重来：卸栈 → remove → rescan → 装回。对端重启过之后只有这个有用
# （端点那边的 BAR 分配被硬件清掉了，我们这边还记着老地址，probe 写到不存在的
# 地址上就是 -110；必须让内核重新读 config space、重写 BAR）。
# 实测 remove+rescan **不会**复位 NPU。
flush_link() {
	find_epf || return 1
	bdf=${PCI_DEV##*/}
	log "整条重来（$bdf：卸栈 → remove → rescan → 装回）"
	modprobe -r ntb_netdev 2>/dev/null
	modprobe -r ntb_transport 2>/dev/null
	modprobe -r ntb_hw_epf 2>/dev/null
	sleep 0.3
	echo 1 >"/sys/bus/pci/devices/$bdf/remove" 2>/dev/null
	timeout 15 sh -c 'echo 1 > /sys/bus/pci/rescan' 2>/dev/null
	i=0
	while [ ! -e "/sys/bus/pci/devices/$bdf" ] && [ "$i" -lt 12 ]; do
		i=$((i + 1))
		sleep 0.25
	done
	WAIT=6 /usr/local/sbin/xgs-ntb-up.sh >>"$WATCH_LOG" 2>&1
}

reload_stack() {
	log "重建本机 NTB 协议栈"
	modprobe -r ntb_netdev 2>/dev/null
	modprobe -r ntb_transport 2>/dev/null
	sleep 0.3
	WAIT=6 /usr/local/sbin/xgs-ntb-up.sh >>"$WATCH_LOG" 2>&1
}

retrain_link() {
	port= tmp=${PCI_DEV##*/}
	bus=$(printf '%d' "0x$(echo "$tmp" | cut -d: -f2)") || return 1
	for p in /sys/bus/pci/devices/*; do
		[ -r "$p/secondary_bus_number" ] || continue
		[ "$(cat "$p/secondary_bus_number" 2>/dev/null)" = "$bus" ] && { port=$p; break; }
	done
	[ -n "$port" ] || return 1
	cur=$(setpci -s "${port##*/}" CAP_EXP+10.w 2>/dev/null) || return 1
	off=$(printf '%04x' $(( 0x$cur | 0x10 )))
	on=$(printf '%04x' $(( 0x$cur & 0xffef )))
	log "重训链路 ${port##*/}（$cur -> $off -> $on）"
	setpci -s "${port##*/}" CAP_EXP+10.w="$off" 2>/dev/null || return 1
	sleep 2
	setpci -s "${port##*/}" CAP_EXP+10.w="$on" 2>/dev/null || return 1
}

now=$(date +%s)
prev=$(cat "$STATE/state" 2>/dev/null) || prev=init

ifc=$(ntb_iface) || ifc=
car=
[ -n "$ifc" ] && car=$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)

if [ -n "$ifc" ] && [ "$car" = 1 ] && { [ -z "$PEER" ] || timeout 4 ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; }; then
	new=up
elif [ -n "$ifc" ]; then
	new=no-carrier
elif find_epf; then
	if [ -n "$(pci_driver "$PCI_DEV")" ]; then new=no-netdev; else new=unbound; fi
else
	new=no-device
fi

if [ "$new" = up ]; then
	sets bad 0
	sets stack_fails 0
else
	bad=$(st bad)
	[ "$bad" = 0 ] && { bad=$now; sets bad "$now"; }

	case "$new" in
	unbound)
		# 端点挂着没驱动：probe 失败过（-110），让内核再试；一直不行就重枚举。
		if [ $((now - bad)) -ge 8 ]; then
			if [ $((now - $(st flash_at))) -ge "$STRICT_CD" ]; then
				sets flash_at "$now"
				flush_link || true
			fi
		elif [ $((now - $(st bind_at))) -ge "$BIND_CD" ]; then
			sets bind_at "$now"
			timeout 20 sh -c "echo ${PCI_DEV##*/} > /sys/bus/pci/drivers/ntb_hw_epf/bind" 2>/dev/null || true
		fi
		;;
	no-device)
		if [ $((now - $(st rescan_at))) -ge "$RESCAN_CD" ]; then
			sets rescan_at "$now"
			timeout 10 sh -c 'echo 1 > /sys/bus/pci/rescan' 2>/dev/null || true
		fi
		# 端点不在就别乱动链路；只有长时间没有端点才重训（这条一定要慢，
		# NPU 正常重启要 30 秒，急着重训会把它打回去重启）
		if [ $((now - bad)) -ge "$RETRAIN_AFTER" ] &&
			[ $((now - $(st retrain_at))) -ge "$RETRAIN_CD" ]; then
			sets retrain_at "$now"
			[ -n "$PCI_DEV" ] || find_epf || true
			retrain_link || log "重训失败"
		fi
		;;
	*)
		# no-carrier / no-netdev / peer-down
		# 光重建协议栈救不了"端点 BAR 被清掉"这种情况，所以试 STRICT_RELOADS 次
		# 之后就升级到 remove+rescan。
		reloads=$(st stack_fails)
		if [ "$reloads" -ge "$STRICT_RELOADS" ] &&
			[ $((now - $(st flash_at))) -ge "$STRICT_CD" ]; then
			sets flash_at "$now"
			sets stack_fails 0
			log "$new：重建 ${reloads} 次无效，升级到 remove+rescan"
			flush_link || true
		elif [ $((now - $(st stack_at))) -ge "$PLUMB_CD" ]; then
			sets stack_at "$now"
			sets stack_fails $((reloads + 1))
			reload_stack
		fi
		;;
	esac
fi

if [ "$new" != "$prev" ]; then
	log "状态 $prev -> $new"
	sets state "$new"
fi