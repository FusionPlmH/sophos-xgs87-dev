#!/bin/sh
# 维护 U 盘上几个脚本共用的小工具。
#
# 地址为什么是两个：旧镜像里管理段是独立的 br-mgmt（NPU 192.168.100.1），
# 新布局把管理并进了 WAN，NPU 的 br-lan 是 10.234.56.1。U 盘系统可能对着
# 任何一个版本，所以两个都试。
set -u

NPU_CANDIDATES=${NPU_CANDIDATES:-"10.234.56.1 192.168.100.1"}
# 这两个以前只在菜单里赋值，脚本单独跑（或菜单那条路没走到赋值）就撞上 set -u
# 直接退出 —— 真机上的 "NPU_PASS: parameter not set" 就是这么来的。
NPU_USER=${NPU_USER:-admin}
NPU_PASS=${NPU_PASS:-P@ssw0rd}

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
# ---------------------------------------------------------------- 登录 NPU ---
# 维护盘上没有 admin 的 SSH key，而 admin 的密码是 NPU_PASS。ssh 在控制台上有
# tty，默认会去 tty 上问密码 —— 脚本没法回答。用 SSH_ASKPASS + REQUIRE=force
# 让它改成调用我们的小程序（OpenSSH 8.4+ 支持，Debian 13 是 10.x）。
npu_ssh_setup() {
	_ap=${TMPDIR:-/tmp}/.xgs87-askpass.$$
	printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "'${NPU_PASS:-}'" >"$_ap"
	chmod 700 "$_ap"
	SSH_ASKPASS=$_ap
	SSH_ASKPASS_REQUIRE=force
	export SSH_ASKPASS SSH_ASKPASS_REQUIRE
	NPU_SSH_OPTS="-o PreferredAuthentications=password -o PubkeyAuthentication=no
		-o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"
}

# npu_ssh <cmd>：以 admin 登录并用 sudo 跑一段脚本。
# 密码既用于 ssh 登录（askpass），也用于 sudo（-S 从 stdin 读），所以第一行
# 喂给 sudo，命令体跟在后面。
npu_ssh() {
	npu_ssh_setup
	# shellcheck disable=SC2086  # 选项串就是要分词
	{ printf '%s\n' "$NPU_PASS"; printf '%s\n' "$1"; } |
		ssh $NPU_SSH_OPTS "admin@$NPU" "sudo -S -p '' bash -s"
}
# npu_ssh_stream：给"要把数据从 stdin 灌进去"的场景（例如 zstd -dc tar | 它）。
# 普通 npu_ssh 把密码喂给 sudo -S，stdin 就被占了；这里改成在 NPU 上放一个
# askpass 脚本、让 sudo -A 自己去问，stdin 空出来给数据。
npu_ssh_stream() {
	_cmd=$1
	npu_ssh_setup
	npu_ssh "printf '#!/bin/sh\nprintf \"%%s\\n\" %s\n' >/tmp/.xgs87-ap && chmod 700 /tmp/.xgs87-ap" >/dev/null || return 1
	# shellcheck disable=SC2086
	ssh $NPU_SSH_OPTS "admin@$NPU" "SUDO_ASKPASS=/tmp/.xgs87-ap sudo -A bash -c \"$_cmd\""
}