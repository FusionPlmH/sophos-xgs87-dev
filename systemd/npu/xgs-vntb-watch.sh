#!/bin/sh
# 一直盯着 vNTB 链路的**这一端**（NPU / PCIe endpoint）。
#
# 为什么需要它：xgs-vntb 只在开机跑一次，可是对端（x86）会
#   * 重启 —— 它重启时会先拉 PERST# 把我们这块端点复位，硬件回到出厂状态，而
#     configfs 里的 start 还写着 1，我们这边完全不知道；
#   * 重新装一遍 NTB 协议栈 —— 它的 QP 重建了，我们的 QP 还停在老状态。
# 结果：x86 那边 eth0 有、地址也有，但两边 QP 握不上手，从外面看就是"链路死了"。
# 2026-11-25 实测两次都是靠人工 restart xgs-vntb 救回来的 —— 这里把它自动化。
#
# 四种状态，动作不同：
#   up        载体=1                    什么都不做
#   link-down 接口 UP、carrier=0        连续 DOWN_SEC 秒 → 重新武装端点
#   adm-down  carrier 读不出来（接口没收 up）→ 只补管道（ip link up + xgs-net-up.sh）
#   none      连接口都没有              → 重新武装端点
# 重新武装先走软的（configfs + 协议栈），连续 WARN_AFTER 次都救不回来就在日志里
# 说清楚"端点控制器卡住了，只能重启 NPU" —— 这块板子上没有系统内复位控制器这条路。
# 注意：carrier 只有在接口 UP 的时候才读得到，所以"读不出来"必须单独当成一种状态，
# 否则重新武装出来的新接口会永远被判成"链路断了"（2026-11-25 踩过）。
set -u

export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

INTERVAL=${INTERVAL:-5}
DOWN_SEC=${DOWN_SEC:-20}
REARM_CD=${REARM_CD:-90}
PLUMB_CD=${PLUMB_CD:-20}
WARN_AFTER=${WARN_AFTER:-3}
LOG=${LOG:-/var/log/xgs-vntb-watch.log}

log() {
	echo "xgs-vntb-watch: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t xgs-vntb-watch "$*"
}

ntb_if() {
	local n dev drv
	for n in /sys/class/net/*; do
		dev=${n##*/}
		[ "$dev" = lo ] && continue
		drv=$(ethtool -i "$dev" 2>/dev/null | sed -n 's/^driver: //p')
		[ "$drv" = ntb_netdev ] && { echo "$dev"; return 0; }
	done
	return 1
}

link_state() {
	local ifc
	ifc=$(ntb_if) || { echo none; return; }
	if [ "$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)" = 1 ]; then
		echo up
	elif [ -r "/sys/class/net/$ifc/carrier" ]; then
		echo link-down
	else
		echo adm-down
	fi
}

# 重新武装。**只能软着来**：这块板子上没有"在系统内复位端点控制器"这回事
# （dw-pcie 关掉了 bind/unbind，重装 pcie_dw_plat 会让内核直接卡死，2026-11-25
# 实测两次），所以这里只做 configfs + 协议栈 + 补管道。硬卡死只能重启 NPU，
# 或者重启 x86 让 PERST# 把它一起复位。
rearm() {
	log "重新武装 vNTB 端点"
	modprobe -r ntb_netdev 2>/dev/null || true
	modprobe -r ntb_transport 2>/dev/null || true
	sleep 1
	timeout 60 /usr/local/sbin/xgs-vntb.sh >>"$LOG" 2>&1 || true
	plumbing
}

# 连续软重装都救不回来就别再折腾了（每次重装都会短暂打断对端），
# 只把"该怎么办"写进日志。
fails=0
warned=0
recover() {
	rearm
	if [ "$(link_state)" = up ]; then
		fails=0
		warned=0
		return 0
	fi
	# 新接口起来要一两秒，别把"还没来得及 carrier"算成失败
	i=0
	while [ "$i" -lt 10 ]; do
		[ "$(link_state)" = up ] && { fails=0; warned=0; return 0; }
		i=$((i + 1))
		sleep 1
	done
	fails=$((fails + 1))
	if [ "$fails" -ge "$WARN_AFTER" ] && [ "$warned" = 0 ]; then
		warned=1
		log "连续 ${fails} 次重新武装都没恢复：端点控制器已经卡住了，在系统内救不了。"
		log "  → 重启 NPU；或者重启 x86（它的 PERST# 会把 NPU 一起复位）。"
	fi
}

# 新接口默认是 DOWN 的，桥/VLAN/地址也要重新挂回去
plumbing() {
	local ifc
	ifc=$(ntb_if) || return 0
	ip link set "$ifc" up 2>/dev/null || true
	/usr/local/sbin/xgs-net-up.sh >>"$LOG" 2>&1 || true
}

down_since=0
last_rearm=0
last_plumb=0
state=init

log "开始盯着自己这端（每 ${INTERVAL}s 一拍，连续 DOWN ${DOWN_SEC}s 才重新武装）"

while :; do
	now=$(date +%s)
	new=$(link_state)

	case "$new" in
	link-down)
		[ "$down_since" = 0 ] && down_since=$now
		if [ $((now - down_since)) -ge "$DOWN_SEC" ] &&
			[ $((now - last_rearm)) -ge "$REARM_CD" ]; then
			last_rearm=$now
			down_since=0
			recover
			new=$(link_state)
		fi
		;;
	adm-down)
		down_since=0
		if [ $((now - last_plumb)) -ge "$PLUMB_CD" ]; then
			last_plumb=$now
			log "接口在但没收 up，补管道"
			plumbing
			new=$(link_state)
		fi
		;;
	none)
		down_since=0
		if [ $((now - last_rearm)) -ge "$REARM_CD" ]; then
			last_rearm=$now
			recover
			new=$(link_state)
		fi
		;;
	*)
		down_since=0
		;;
	esac

	if [ "$new" != "$state" ]; then
		log "状态 $state -> $new"
		state=$new
	fi
	sleep "$INTERVAL"
done