#!/bin/sh
# 只读的状态检查。
set -u
PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
. "$PAYLOAD/lib.sh"
NPU=$(find_npu 3) || NPU=
echo "== 本机磁盘"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
echo
echo "== U 盘上的东西"
ls -lh "$PAYLOAD" 2>/dev/null | head -30
echo
echo "== vNTB 链路"
ip -br a 2>/dev/null | grep -E '^(eth0|br-)' || echo "  （没有 eth0，vNTB 没起来）"
if [ -n "$NPU" ]; then
	echo "  NPU 在 $NPU 可达"
else
	echo "  NPU 不可达（试过：$NPU_CANDIDATES）"
fi
echo
echo "== NPU 能不能 SSH"
if [ -n "$NPU" ] && ssh -o BatchMode=yes -o ConnectTimeout=4 "admin@$NPU" true 2>/dev/null; then
	echo "  SSH ok"
else
	echo "  不通（NPU 没起来，或者还没配 key）"
fi