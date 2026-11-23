#!/bin/sh
# LAN → WAN 的转发和 NAT。
#
# br-lan（10.234.56.0/24）下面的设备把网关指到 10.234.56.1 就能上网；上游是
# br-wan 上 DHCP 拿到的网络。没有这个，LAN 只是个孤岛。
#
# 规则全放在自己的一张 nft table（inet xgs87）里，重复执行就是重建它，不碰
# 别人的规则；关掉这个单元再 `nft delete table inet xgs87` 就完全回退。
set -u

CONF=${CONF:-/etc/xgs87/net.conf}
if [ -r "$CONF" ]; then
	# shellcheck disable=SC1090  # 路径运行时可配，读的是设备上的配置
	. "$CONF"
fi

LAN_IF=${LAN_IF:-br-lan}
WAN_IF=${WAN_IF:-br-wan}
LAN_ADDR=${LAN_ADDR:-10.234.56.1/24}
# 只取第一个地址；nft 会把 10.234.56.1/24 归一化成 10.234.56.0/24
LAN_NET=${LAN_ADDR%% *}

if [ ! -e "/sys/class/net/$WAN_IF" ] || [ ! -e "/sys/class/net/$LAN_IF" ]; then
	echo "xgs-nat: $LAN_IF / $WAN_IF 还没建好（xgs-net-up 跑了吗？）" >&2
	exit 1
fi

sysctl -q -w net.ipv4.ip_forward=1

nft delete table inet xgs87 2>/dev/null || true
nft add table inet xgs87

# 只允许 LAN → WAN 新建连接，回程放 established/related，其余转发全丢。
nft add chain inet xgs87 forward '{ type filter hook forward priority filter; policy accept; }'
nft add rule inet xgs87 forward iifname "$LAN_IF" oifname "$WAN_IF" accept
nft add rule inet xgs87 forward iifname "$WAN_IF" oifname "$LAN_IF" ct state established,related accept
nft add rule inet xgs87 forward drop

# LAN 出去时做源地址伪装（上游只认识 br-wan 那个地址）。
nft add chain inet xgs87 postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule inet xgs87 postrouting oifname "$WAN_IF" ip saddr "$LAN_NET" masquerade

echo "xgs-nat: $LAN_NET via $WAN_IF（ip_forward=1，masquerade 已装）"