#!/bin/sh
# 按 /etc/xgs87/net.conf 把面板口分成 WAN / LAN 两个桥，并把两条 vNTB VLAN 接进去。
#
#   br-lan  = LAN_PORTS  + eth0.31   （家里内网，x86 也从这条拿地址）
#   br-wan  = WAN_PORTS  + eth0.32   （面板 2/WAN）
#
# 管理段 br-mgmt（p8 + eth0.100）由 xgs-mgmt-bridge.sh 负责，这里不碰。
#
# 两个桥都用 vlan_filtering 且各自一个 VID：交换芯片默认 VLAN 1 已经被
# br-mgmt 占着（p8），再让别的桥用 VLAN 1 会直接报
# "hw VLAN 1 already used by port 8 in br-mgmt" 并把两个网段搅在一起。
#
# 幂等：可以反复跑。
set -u

CONF=${CONF:-/etc/xgs87/net.conf}
if [ -r "$CONF" ]; then
	# shellcheck disable=SC1090  # 路径运行时可配，读的是设备上的配置
	. "$CONF"
fi

WAN_PORTS=${WAN_PORTS:-p2}
WAN_MODE=${WAN_MODE:-dhcp}
LAN_PORTS=${LAN_PORTS:-p1 p3 p4}
LAN_MODE=${LAN_MODE:-dhcp}
LAN_VID=${LAN_VID:-31}
WAN_VID=${WAN_VID:-32}

RUN=/run/xgs87
mkdir -p "$RUN"
: > "$RUN/dhcp-ifaces"

# 等交换机端口出现（DSA 是异步注册的）
i=0
for p in $WAN_PORTS $LAN_PORTS; do
	while [ ! -e "/sys/class/net/$p" ] && [ $i -lt 60 ]; do
		i=$((i + 1))
		sleep 1
	done
done

# 找 vNTB 出来的那个 netdev（它的 device 链到 0001:* PCI 地址）
# 也可以用 NTB=... 直接指定（测试或平台差异时）。
if [ -z "${NTB:-}" ]; then
	for n in /sys/class/net/*; do
		dev=${n##*/}
		[ -e "$n/device" ] || continue
		case "$(readlink -f "$n/device")" in
		*/0001:*) NTB=$dev ;;
		esac
	done
fi
[ -n "$NTB" ] || {
	echo "xgs-net-up: 还没有 vNTB netdev（NPU 的 EP 没起来？）" >&2
	exit 1
}
ip link set "$NTB" mtu 2022 2>/dev/null || true
ip link set "$NTB" up

# make_bridge <name> <vid> <ports...>
make_bridge() {
	br=$1
	vid=$2
	shift 2

	ip link show "$br" >/dev/null 2>&1 || ip link add name "$br" type bridge
	ip link set "$br" type bridge stp_state 0 forward_delay 0 2>/dev/null || true
	ip link set "$br" type bridge vlan_default_pvid 0 2>/dev/null || true
	ip link set "$br" type bridge vlan_filtering 1 2>/dev/null || true

	vl=$NTB.$vid
	ip link show "$vl" >/dev/null 2>&1 ||
		ip link add link "$NTB" name "$vl" type vlan id "$vid" || return 1
	ip link set "$vl" up
	ip link set "$vl" master "$br"
	bridge vlan del dev "$vl" vid 1 2>/dev/null || true
	bridge vlan add dev "$vl" vid "$vid" pvid untagged 2>/dev/null || true

	for p in "$@"; do
		if [ ! -e "/sys/class/net/$p" ]; then
			echo "xgs-net-up: 警告：端口 $p 不存在，跳过" >&2
			continue
		fi
		ip link set "$p" master "$br" 2>/dev/null || true
		ip link set "$p" up
		bridge vlan del dev "$p" vid 1 2>/dev/null || true
		bridge vlan add dev "$p" vid "$vid" pvid untagged 2>/dev/null || true
	done

	# 桥自己也得上同一个 VID（`self`），否则 NPU 自己在桥上的地址会不通。
	bridge vlan add dev "$br" vid "$vid" pvid untagged self 2>/dev/null || true
	ip link set "$br" up
}

# apply <bridge> <mode> [addr...]
apply_mode() {
	br=$1
	mode=$2
	shift 2
	case "$mode" in
	dhcp)
		echo "$br" >> "$RUN/dhcp-ifaces"
		;;
	static)
		for a in "$@"; do
			ip addr show dev "$br" | grep -q " ${a%/*}/" ||
				ip addr add "$a" dev "$br"
		done
		;;
	none) ;;
	*) echo "xgs-net-up: $br 的 mode '$mode' 不认识（dhcp/static/none）" >&2 ;;
	esac
}

echo "== WAN: $WAN_PORTS (VLAN $WAN_VID)  mode=$WAN_MODE"
rc=0
make_bridge br-wan "$WAN_VID" $WAN_PORTS &&
	apply_mode br-wan "$WAN_MODE" ${WAN_ADDR:-} || rc=1

echo "== LAN: $LAN_PORTS (VLAN $LAN_VID)  mode=$LAN_MODE"
make_bridge br-lan "$LAN_VID" $LAN_PORTS &&
	apply_mode br-lan "$LAN_MODE" ${LAN_ADDR:-} || rc=1

for br in br-wan br-lan; do
	echo "xgs-net-up: $br = $(ip -br a show "$br" 2>/dev/null | tr -s ' ')"
done
echo "xgs-net-up: DHCP 接口: $(tr '\n' ' ' < "$RUN/dhcp-ifaces")"
exit $rc
