#!/bin/sh
# 在 /etc/xgs87/net.conf 里选了 dhcp 的桥上跑 dhcpcd。
#
# xgs-net-up.sh 会把接口名写进 /run/xgs87/dhcp-ifaces；一个 dhcpcd 实例可以
# 同时盯多个接口（dhcpcd -4 -B -w br-lan br-wan），所以这里只起一个进程。
set -u

RUN=/run/xgs87
IFACES=$(tr '\n' ' ' < "$RUN/dhcp-ifaces" 2>/dev/null || true)

# 一个都不用跑（两个桥都是 static/none）时也别让单元变成 failed：
# 留着 sleep 让 Type=simple 的单元保持 active，配置改了重启本单元即可。
if [ -z "${IFACES% }" ]; then
	echo "xgs-dhcp: 没有接口配置成 dhcp（见 /etc/xgs87/net.conf）"
	exec sleep infinity
fi

echo "xgs-dhcp: dhcpcd -4 -B -w $IFACES"
exec /usr/sbin/dhcpcd -4 -B -w $IFACES
