#!/bin/sh
# 维护 U 盘上几个脚本共用的小工具。
#
# 地址为什么是两个：旧镜像里管理段是独立的 br-mgmt（NPU 192.168.100.1），
# 新布局把管理并进了 WAN，NPU 的 br-lan 是 10.234.56.1。U 盘系统可能对着
# 任何一个版本，所以两个都试。
set -u

NPU_CANDIDATES=${NPU_CANDIDATES:-"10.234.56.1 192.168.100.1"}

# find_npu [timeout_seconds] -> 打印可达的 NPU 地址；NPU 变量已设时直接用它
find_npu() {
	[ -n "${NPU:-}" ] && { echo "$NPU"; return 0; }
	_end=$(( $(date +%s) + ${1:-0} ))
	while :; do
		for a in $NPU_CANDIDATES; do
			if ping -c1 -W1 "$a" >/dev/null 2>&1; then
				echo "$a"
				return 0
			fi
		done
		[ "$(date +%s)" -ge "$_end" ] && return 1
		sleep 1
	done
}

# lan_addr -> x86 在 LAN 那一段（eth0.200）的地址，NPU 控制台要靠它 wget
lan_addr() {
	_a=$(ip -4 -br a show dev eth0.200 2>/dev/null |
		awk '$3 ~ /^[0-9]/ { print $3 }' | cut -d/ -f1 | head -1)
	[ -n "$_a" ] || _a=$(ip -4 -br a show up 2>/dev/null |
		awk '$1 != "lo" && $3 ~ /^[0-9]/ { print $3 }' | cut -d/ -f1 | head -1)
	echo "$_a"
}

# ensure_store -> 打印可用的备份目录；备份分区没准备好就返回 1
#
# 备份分区是第一次开机由 xgs87-usbstore.sh 在 U 盘尾部切出来的 exfat。这里再调
# 一次是幂等的：已经挂好了它直接退出；没挂好就现切。绝不能因为目录"看起来存在"
# 就往 root 分区里写 —— 那条路会先把 U 盘系统自身撑爆。
ensure_store() {
	_dir=${STORE:-/media/xgs87-bak}
	if [ -x /usr/local/sbin/xgs87-usbstore.sh ]; then
		/usr/local/sbin/xgs87-usbstore.sh >/dev/null 2>&1 || true
	fi
	findmnt -n -o TARGET "$_dir" >/dev/null 2>&1 || return 1
	echo "$_dir"
}