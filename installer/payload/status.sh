#!/bin/sh
# 只读的状态检查。
set -u
PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
NPU=${NPU:-192.168.100.1}
echo "== 本机磁盘"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
echo
echo "== U 盘上的东西"
ls -lh "$PAYLOAD" 2>/dev/null | head -30
echo
echo "== vNTB 链路"
ip -br a 2>/dev/null | grep -E '^(eth0|br-)' || echo "  （没有 eth0，vNTB 没起来）"
ping -c 1 -W 2 "$NPU" >/dev/null 2>&1 && echo "  NPU 在 $NPU 可达" \
	|| echo "  NPU 不可达"
echo
echo "== NPU 能不能 SSH"
ssh -o BatchMode=yes -o ConnectTimeout=4 "admin@$NPU" true 2>/dev/null \
	&& echo "  SSH ok" || echo "  不通（NPU 没起来，或者还没配 key）"