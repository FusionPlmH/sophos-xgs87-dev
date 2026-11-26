#!/bin/sh
# 一直盯着 vNTB 这条链路 —— 这里才是"恢复"的地方，xgs-ntb-up.sh 只是开机时的第一次尝试。
#
# 为什么必须常驻：上电顺序根本不受我们控制
#   * BIOS 扫 PCIe 时 NPU 的端点常常还没武装（NPU 自己上电到 vNTB 就绪要 ~12 s）；
#   * host 重启会先拉 PERST# 把 NPU 一起复位，两边同时起来；
#   * NPU 单独重启 / 进 U-Boot / 换镜像，链路就是会消失又出现。
# 一次性脚本只要抢在"端点还没出现"那一瞬间跑完就 exit 1，然后**再没人管**：症状是
# `lspci` 里有 1957:0809、却没有 eth0，只能人工登进去敲一条命令（2026-11-25 上电后
# 就是这样，而且这台机器唯一的网络就是这条链路，等于把自己关在门外）。
#
# 三种状态，处理方式完全不同：
#   端点在、netdev 不在  → 重跑 xgs-ntb-up.sh（只 modprobe + bind + VLAN + 地址，不碰 PCIe）
#   端点不在             → 先 plain rescan；连续 RETRAIN_AFTER 次都无效，才 toggle 根端口
#                          的 Link Disable 让 LTSSM 重新训练（不 assert PERST#，不复位 NPU）
#   都在、对端不通       → 只记日志（多半是 NPU 停在 U-Boot 或还在启动）
#
# 可调项在 /etc/default/xgs-ntb-watch。
set -u

export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

INTERVAL=${INTERVAL:-5}
PEER=${PEER:-10.234.56.1}
RESCAN_CD=${RESCAN_CD:-20}		# plain rescan 冷却（秒）
RETRAIN_AFTER=${RETRAIN_AFTER:-3}	# 连续几次 rescan 无效才动链路
RETRAIN_CD=${RETRAIN_CD:-180}		# Link Disable 冷却（秒）
PLUMB_CD=${PLUMB_CD:-20}		# 重跑 xgs-ntb-up.sh 的冷却（秒）
WATCH_LOG=${WATCH_LOG:-/var/log/xgs-ntb-watch.log}
# shellcheck disable=SC1091
[ -r /etc/default/xgs-ntb-watch ] && . /etc/default/xgs-ntb-watch

log() {
	echo "xgs-ntb-watch: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t xgs-ntb-watch "$*"
}

# 端点在哪：返回 0 并把 PCI_DEV 设成 sysfs 路径。不写死 bus 号 —— 冷启动之后
# BIOS 可能重新编号（上一版写死 0000:03:00.0，被重编号时就一直报"端点不见了"）。
find_epf() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x1957 ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = 0x0809 ] || continue
		PCI_DEV=$d
		return 0
	done
	return 1
}

# ntb_netdev 建出来的接口是不是已经在（名字可能是 eth0，也可能是别的；
# 急救时插了 USB 网卡它也叫 eth0，所以必须按 driver 认，不能按名字）。
is_ntb_netdev() {
	local n dev drv
	for n in /sys/class/net/*; do
		dev=${n##*/}
		[ "$dev" = lo ] && continue
		drv=$(ethtool -i "$dev" 2>/dev/null | sed -n 's/^driver: //p')
		[ "$drv" = ntb_netdev ] && return 0
	done
	return 1
}

# 根端口 = secondary bus 等于端点所在 bus 的那个 bridge
find_root_port() {
	local bus port sec tmp
	tmp=${PCI_DEV##*/}
	bus=$(printf '%d' "0x$(echo "$tmp" | cut -d: -f2)") || return 1
	for port in /sys/bus/pci/devices/*; do
		[ -r "$port/secondary_bus_number" ] || continue
		sec=$(cat "$port/secondary_bus_number" 2>/dev/null)
		[ "$sec" = "$bus" ] && { echo "${port##*/}"; return 0; }
	done
	return 1
}

retrain_link() {
	local port cur off on
	port=$(find_root_port) || { log "找不到 ${PCI_DEV:-?} 的根端口"; return 1; }
	cur=$(setpci -s "$port" CAP_EXP+10.w 2>/dev/null) || return 1
	[ -n "$cur" ] || return 1
	off=$(printf '%04x' $(( 0x$cur | 0x10 )))
	on=$(printf '%04x' $(( 0x$cur & 0xffef )))
	log "重训链路 $port（$cur -> $off -> $on）"
	setpci -s "$port" CAP_EXP+10.w="$off" 2>/dev/null || return 1
	sleep 2
	setpci -s "$port" CAP_EXP+10.w="$on" 2>/dev/null || return 1
	return 0
}

retrain_at=0
rescan_at=0
plumb_at=0
bad_rescans=0
state=init
PCI_DEV=

log "开始盯着 vNTB（每 ${INTERVAL}s 一拍，对端 $PEER）"

while :; do
	now=$(date +%s)
	new=unknown

	if ! find_epf; then
		new=no-device
		if [ $((now - rescan_at)) -ge "$RESCAN_CD" ]; then
			rescan_at=$now
			bad_rescans=$((bad_rescans + 1))
			log "总线上没有端点，plain rescan（第 $bad_rescans 次）"
			echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
			sleep 2
			find_epf && bad_rescans=0
		fi
		if [ "$bad_rescans" -ge "$RETRAIN_AFTER" ] &&
			[ $((now - retrain_at)) -ge "$RETRAIN_CD" ]; then
			retrain_at=$now
			retrain_link || log "重训失败"
		fi
	elif ! is_ntb_netdev; then
		new=no-netdev
		if [ $((now - plumb_at)) -ge "$PLUMB_CD" ]; then
			plumb_at=$now
			log "端点在但没有 ntb netdev，重跑 xgs-ntb-up.sh"
			WAIT=8 /usr/local/sbin/xgs-ntb-up.sh >>"$WATCH_LOG" 2>&1 || true
			is_ntb_netdev && new=netdev-up
		fi
	elif ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; then
		new=up
	else
		new=no-peer
	fi

	if [ "$new" != "$state" ]; then
		log "状态 $state -> $new"
		state=$new
	fi
	sleep "$INTERVAL"
done
