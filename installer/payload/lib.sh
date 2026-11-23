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
	legacy_mgmt
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
# legacy_mgmt -> 给 eth0.100 补一个 192.168.100.2/24（老镜像的 NPU 管理段）
#
# 新布局里 x86 的 eth0.100 走 DHCP，上游根本不会发 192.168.100.x，所以拿不
# 到地址就 ping 不通老 NPU 的 192.168.100.1 —— 看起来像"NPU 不在线"，其实只是
# 这一端没有同网段地址。加一个临时的就行（重启就没了）。
legacy_mgmt() {
	_dev=eth0.100
	[ -e "/sys/class/net/$_dev" ] || return 0
	ip addr show dev "$_dev" 2>/dev/null | grep -q 'inet 192\.168\.100\.2/' && return 0
	ip link set "$_dev" up 2>/dev/null || true
	ip addr add 192.168.100.2/24 dev "$_dev" 2>/dev/null || true
}

# local_addrs -> 本机所有非 lo 的 IPv4 地址（一行一个）
local_addrs() {
	ip -4 -br a show up 2>/dev/null |
		awk '$1 != "lo" && $3 ~ /^[0-9]/ { print $3 }' | cut -d/ -f1
}