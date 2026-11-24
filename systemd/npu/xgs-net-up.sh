#!/bin/sh
# 按 /etc/xgs87/net.conf 把面板口分成 WAN / LAN 两个桥，并把两条 vNTB VLAN 接进去。
#
#   br-wan = WAN_PORTS + eth0.100   （面板 2/WAN，上游；自己 DHCP 拿地址）
#   br-lan = LAN_PORTS + eth0.200   （面板 1/LAN，下游；静态 10.234.56.1/24）
#
# 两个桥都用 vlan_filtering 且各自一个 VID：交换芯片默认 VLAN 1 谁都不用，
# 免得两个网段在芯片里其实是同一个广播域。
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
LAN_PORTS=${LAN_PORTS:-p1}
LAN_MODE=${LAN_MODE:-static}
LAN_ADDR=${LAN_ADDR:-10.234.56.1/24}
LAN_VID=${LAN_VID:-200}
WAN_VID=${WAN_VID:-100}

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
modprobe 8021q 2>/dev/null

# Remove DSA ports that used to be in a bridge but are no longer listed, so
# changing LAN_PORTS/WAN_PORTS really removes a port instead of only adding.
for p in p1 p2 p3 p4 p5 p6 p7 p8 sfp; do
	[ -e "/sys/class/net/$p" ] || continue
	case " $WAN_PORTS $LAN_PORTS " in
	*" $p "*) ;;
	*) ip link set "$p" nomaster 2>/dev/null || true ;;
	esac
done

# make_bridge <name> <vid> <ports...>
make_bridge() {
	br=$1
	vid=$2
	shift 2

	ip link show "$br" >/dev/null 2>&1 || ip link add name "$br" type bridge
	ip link set "$br" type bridge stp_state 0 forward_delay 0 2>/dev/null || true
	ip link set "$br" type bridge vlan_default_pvid 0 2>/dev/null || true
	ip link set "$br" type bridge vlan_filtering 1 2>/dev/null || true

	# 桥自己的 MAC 默认是随机生成的，DHCP 租约和 ssh known_hosts 每重启一次
	# 就变一次。借第一个真实端口的 MAC 钉死它。
	for p in "$@"; do
		if [ -r "/sys/class/net/$p/address" ]; then
			ip link set "$br" address "$(cat "/sys/class/net/$p/address")" 2>/dev/null || true
			break
		fi
	done

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

# apply_mode <bridge> <mode> <gateway|-> [addr...]
apply_mode() {
	br=$1
	mode=$2
	gw=$3
	shift 3
	case "$mode" in
	dhcp)
		echo "$br" >> "$RUN/dhcp-ifaces"
		;;
	static)
		for a in "$@"; do
			ip addr show dev "$br" | grep -q " ${a%/*}/" ||
				ip addr add "$a" dev "$br"
		done
		[ "$gw" = - ] || ip route replace default via "$gw" dev "$br"
		;;
	none) ;;
	*) echo "xgs-net-up: $br 的 mode '$mode' 不认识（dhcp/static/none）" >&2 ;;
	esac
}

echo "== WAN: $WAN_PORTS (VLAN $WAN_VID)  mode=$WAN_MODE"
rc=0
make_bridge br-wan "$WAN_VID" $WAN_PORTS &&
	apply_mode br-wan "$WAN_MODE" "${WAN_GW:--}" ${WAN_ADDR:-} || rc=1

echo "== LAN: $LAN_PORTS (VLAN $LAN_VID)  mode=$LAN_MODE"
make_bridge br-lan "$LAN_VID" $LAN_PORTS &&
	apply_mode br-lan "$LAN_MODE" "${LAN_GW:--}" ${LAN_ADDR:-} || rc=1

for br in br-wan br-lan; do
	echo "xgs-net-up: $br = $(ip -br a show "$br" 2>/dev/null | tr -s ' ')"
done
echo "xgs-net-up: DHCP 接口: $(tr '\n' ' ' < "$RUN/dhcp-ifaces")"
exit $rc
