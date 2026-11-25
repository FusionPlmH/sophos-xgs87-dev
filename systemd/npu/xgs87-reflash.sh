#!/bin/sh
# xgs87-reflash -- write a new root image into p2 without corrupting it.
#
# The eMMC layout is fixed and only p2 belongs to this project:
#
#   p1  /dev/mmcblk0p1   500 MiB   factory Marvell rootfs   never written
#   p2  /dev/mmcblk0p2   1.5 GiB   our Debian root          the only write target
#   p3  /dev/mmcblk0p3   1.5 GiB   factory Sophos system    never written, ever
#   p4  /dev/mmcblk0p4   100 MiB   VPD (serial, MACs)       never written
#
# p3 is the lifeboat, not a spare slot.  It boots read-only (rootwait ro), so it
# can never be damaged, and it is what you fall back to when p2 is broken.  Some
# other OS staying intact is worth more than any convenience another slot would
# buy -- and it would not help anyway: p3 has no data path to the x86 (its only
# netdev is pcinet's mvmgmt0, which waits for the Sophos host driver and times
# out), and the UART runs at 115200.
#
# Rewriting the root you are running from corrupts it: dd finishes, and then the
# old filesystem keeps flushing its dirty pages into the brand new metadata
# (docs/11 §11.2.1).  FIFREEZE is what makes it safe -- it syncs the filesystem
# and blocks every writer, so once it returns nothing but our dd can touch p2.
#
#   install  （已禁用：见 do_install 里的 2026-11-25 事故说明）
#       FILE must already be on this machine and must live on a tmpfs, never on
#       p2 itself: the image is read while p2 is overwritten, so a copy inside p2
#       would be destroyed halfway through.  The freeze covers only the dd -- no
#       network traffic happens while the filesystem is frozen, because a frozen
#       root blocks sshd's own writes and throttles the transfer to ~1 MB/s.
#       After a successful write the machine hard-reboots (-f: systemd shutdown
#       would only block on the frozen filesystem).
#
#   snapshot -|FILE
#       Consistent image of the running root, for a backup.  The consumer must be
#       local (pipe it into a file on /dev/shm), never a network hop.
#
#   thaw, status, factory, debian
#       Manual unfreeze, layout + U-Boot state, and the boot selector.
set -u

DISK=/dev/mmcblk0
TARGET_P=2
TARGET="${DISK}p${TARGET_P}"
FACTORY_P=3
RUN=/run/xgs87-reflash
FROZEN=0
WD=

die() { echo "xgs87-reflash: $*" >&2; exit 1; }
say() { echo "== $*" >&2; }

need_root() { [ "$(id -u)" = 0 ] || die "run me as root"; }

root_part() {
	src=$(findmnt -n -o SOURCE /)
	case "$src" in
	"$DISK"p[0-9]) echo "${src##*p}" ;;
	*) echo none ;;
	esac
}

fs_state() { dumpe2fs -h "$1" 2>/dev/null | awk -F': *' '/^Filesystem state/ { print $2 }'; }

# --------------------------------------------------------------- freeze ------
freeze_root() {
	command -v fsfreeze >/dev/null 2>&1 || die "no fsfreeze -- refusing to touch the running root"
	say "freezing / (watchdog unfreezes after 10 min)"
	fsfreeze --freeze / || die "cannot freeze / -- something else is mounted on the same filesystem"
	( sleep 600; fsfreeze --unfreeze / ) >/dev/null 2>&1 &
	WD=$!
	FROZEN=1
	# A dropped ssh session must not leave the machine frozen.
	trap 'unfreeze_root' HUP INT TERM
}

unfreeze_root() {
	[ -n "$WD" ] && kill "$WD" 2>/dev/null
	if fsfreeze --unfreeze / 2>/dev/null; then say "unfrozen"; fi
	FROZEN=0
	trap - HUP INT TERM
}

# ---------------------------------------------------------------- status ----
do_status() {
	need_root
	echo "-- running"
	echo "   root        : $(findmnt -n -o SOURCE /) (partition $(root_part))"
	echo "   filesystem  : $(findmnt -n -o FSTYPE /), options $(findmnt -n -o OPTIONS /)"
	echo "   usage       : $(df -h / | tail -1 | awk '{print $3" of "$2" ("$5")"}')"
	echo "   kernel      : $(uname -r)"
	echo
	echo "-- partitions"
	for p in 1 2 4; do
		dev="${DISK}p${p}"
		sectors=$(cat "/sys/class/block/$(basename "$dev")/size" 2>/dev/null) || sectors=0
		sz=$(awk -v s="${sectors:-0}" 'BEGIN { printf "%.2f GiB", s / 2 / 1024 / 1024 }')
		case $p in
		1) role="factory Marvell rootfs (never written)" ;;
		2) role="our Debian root (the only write target)" ;;
		*) role="VPD: serial + MACs (never written)" ;;
		esac
		printf '   p%s  %-9s  %-38s state=%s\n' "$p" "$sz" "$role" "$(fs_state "$dev")"
	done
	dev="${DISK}p${FACTORY_P}"
	sectors=$(cat "/sys/class/block/$(basename "$dev")/size" 2>/dev/null) || sectors=0
	sz=$(awk -v s="${sectors:-0}" 'BEGIN { printf "%.2f GiB", s / 2 / 1024 / 1024 }')
	printf '   p%s  %-9s  %-38s state=%s\n' "$FACTORY_P" "$sz" \
		"factory Sophos system (never written)" "$(fs_state "$dev")"
	echo
	echo "-- U-Boot"
	echo "   bootcmd     : $(fw_printenv -n bootcmd 2>/dev/null)"
	echo "   bootargs_deb: $(fw_printenv -n bootargs_deb 2>/dev/null)"
	case "$(fw_printenv -n bootcmd 2>/dev/null)" in
	*bootcmd_deb*) echo "   -> boots p2 (our system)" ;;
	*bootcmd_emmc3*) echo "   -> boots p3 (factory system, read-only)" ;;
	*) echo "   -> something else; check it before rebooting" ;;
	esac
}

# -------------------------------------------------------------- snapshot ----
do_snapshot() {
	need_root
	[ "$(root_part)" = "$TARGET_P" ] || die "only meaningful when running from p2"
	out=${1:-}
	case "$out" in
	""|-|/dev/stdout) ;;
	*)
		[ -w "$(dirname "$out")" ] || die "cannot write $out"
		case "$(findmnt -n -o FSTYPE --target "$out")" in
		tmpfs) ;;
		*) die "$out is not on a tmpfs; a 1.5 GiB image there would eat p2" ;;
		esac
		;;
	esac
	mkdir -p "$RUN"
	sync
	freeze_root
	say "reading $TARGET"
	if [ -z "$out" ] || [ "$out" = - ] || [ "$out" = /dev/stdout ]; then
		dd if="$TARGET" bs=4M 2>/dev/null
		rc=$?
	else
		dd if="$TARGET" of="$out" bs=4M conv=fsync 2>/dev/null
		rc=$?
	fi
	unfreeze_root
	[ "$rc" = 0 ] || die "read failed"
	[ -n "$out" ] && [ "$out" != - ] && [ "$out" != /dev/stdout ] &&
		say "wrote $out ($(stat -c %s "$out") bytes)"
	return 0
}

# --------------------------------------------------------------- helpers ----
decompress() {
	case "$1" in
	*)
		[ -r "$1" ] || die "cannot read $1"
		hdr=$(dd if="$1" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
		;;
	esac
	case "$hdr" in
	28b52ffd) zstd -dc "$1" ;;
	1f8b*) gzip -dc "$1" ;;
	*) cat "$1" ;;
	esac
}

sniff() {
	# 2048 bytes: the ext4 superblock starts at 1024 and its magic is at 1080,
	# the tar magic at 257 and the MBR signature at 510.
	dd bs=2048 count=1 2>/dev/null > "$RUN/head"
	if [ "$(dd if="$RUN/head" bs=1 skip=257 count=5 2>/dev/null)" = ustar ]; then
		echo tar
	elif [ "$(dd if="$RUN/head" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 53ef ]; then
		echo ext4
	else
		echo unknown
	fi
}

# --------------------------------------------------------------- install ----
# **故意做成硬拒绝。**
# 2026-11-25：`install /dev/shm/p2.img.zst` 在 fsfreeze 之后 dd 到 p2 失败
# （write failed，错误还被吞了），而 p2 上跑的正是这个根文件系统 —— 元数据被
# 倒回 20 分钟前的样子、再跟写进去的新数据混在一起，e2fsck 最后只捞回 11 个文件。
# 头注释里"FIFREEZE 就安全了"的说法是错的：ext4 不支持在挂载状态下被整体覆盖，
# 冻结只是把写者挡住，改不了"这就是同一个文件系统"这个事实。
# 唯一可靠的前提是**写的时候 p2 没有挂载**：起急救 initramfs（根在内存里），
# 或者从 p3 原厂系统写。流程见 docs/14-rescue.md。
do_install() {
	cat >&2 <<'EOF'
xgs87-reflash: install 已被禁用（2026-11-25 事故之后）

在"正跑着的根"上 dd 会把 p2 写成碎片，冻结并不能让它变安全。要换 p2，只有两条：

  A. 常规：x86 上 ssh+dd —— 但 NPU 必须先**从别的系统起来**（p3 原厂或急救
     initramfs），否则 installer/payload/npu-sshdd.sh 会直接拒绝。

  B. 最后手段（p2 起不来、x86 又只剩串口）：RAM 急救 initramfs + 面板口，
     见 docs/14-rescue.md 的「最后手段」一节。

剩下的子命令都是只读或低风险：status / snapshot / thaw / factory / debian
EOF
	exit 1
}
# ---------------------------------------------------------- boot selector ----
do_bootsel() {
	need_root
	case "$1" in
	factory)
		fw_setenv bootcmd 'run bootcmd_emmc3' || die "fw_setenv failed"
		say "bootcmd: $(fw_printenv -n bootcmd)"
		echo "   p3 boots read-only, so it cannot be damaged. Its console is the x86's"
		echo "   /dev/ttyS2 at 115200 and its root password is not known, so leaving it"
		echo "   again means: serial break + 'b' (SysRq reset) while spamming the UART so"
		echo "   U-Boot cannot autoboot, then fix bootcmd at the Marvell>> prompt."
		;;
	debian)
		fw_setenv bootcmd 'run bootcmd_deb10g' || die "fw_setenv failed"
		say "bootcmd: $(fw_printenv -n bootcmd)  (p2, our system)"
		;;
	*) die "usage: xgs87-reflash.sh factory|debian" ;;
	esac
}

case "${1:-}" in
status)   shift; do_status ;;
snapshot) shift; do_snapshot "$@" ;;
install)  shift; do_install "$@" ;;
thaw)     need_root; unfreeze_root ;;
factory|debian) do_bootsel "$1" ;;
*)
	echo "usage: xgs87-reflash.sh status | snapshot -|FILE | install FILE [--sha256 HEX] | thaw | factory | debian"
	exit 1
	;;
esac
