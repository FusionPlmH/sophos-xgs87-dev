#!/bin/sh
# 用 ssh + dd 把 ext4 镜像整块写进 NPU 的 p2。
#
# 为什么需要这一级：NPU 上如果是原厂系统，既没有 tar/zstd（流式解包走不通），
# 也装不上 nbd-server（没有外网）。但 busybox 一定有 dd —— 只要能把字节灌到
# /dev/mmcblk0p2，就能装。
#
#   NPU=10.234.56.1 sh npu-sshdd.sh            # 参数都能用环境变量覆盖
#   NPU=192.168.100.1 sh npu-sshdd.sh          # 老镜像的管理段
#   NPU_USER=root   → 用 root 登录（原厂系统只有 root）
#   NPU_PASS=...    → 需要密码时设它（x86 上没有 tty 可问）
#   SRC=/mnt/usb/p2.img → 直接写这个现成的裸 ext4 镜像，跳过"从 tar 造镜像"
#
# ⚠️ 写的是 NPU 正在跑的根分区：写的过程中它大概率会崩，这是"装系统"的正常表现。
set -u

PAYLOAD=${PAYLOAD:-$(cd "$(dirname "$0")" && pwd)}
NPU=${NPU:-10.234.56.1}
IMG=${IMG:-/var/tmp/npu-p2.img}
SRC=${SRC:-}
TAR=${TAR:-$PAYLOAD/debian-npu.tar.zst}
DTB=${DTB:-$(ls "$PAYLOAD"/cn9130-sophos-xgs87w-sfp10g*.dtb 2>/dev/null | head -1)}
MNT=${MNT:-/var/tmp/npuroot}
PART=${PART:-/dev/mmcblk0p2}
PNAME=${PART##*/}

die() { echo "$*" >&2; exit 1; }

# 裸 ext4 镜像只能写分区。写成 /dev/mmcblk0 会把分区表覆盖掉 —— 2026-11-24 那台
# NPU 就是这么砖的，U-Boot 从此报 "No partition table - mmc 0"。
. "$PAYLOAD/lib.sh"
require_partition "$PART" "目标分区"

if [ -z "$SRC" ]; then
	[ -f "$TAR" ] || die "找不到 $TAR"
	[ -n "$DTB" ] || die "找不到 DTB"
fi

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

# 密码：ssh 在脚本里没有 tty，只能靠 askpass 回话。
if [ -n "${NPU_PASS:-}" ]; then
	_ap=${TMPDIR:-/tmp}/.xgs87-askpass.$$
	printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "'$NPU_PASS'" >"$_ap"
	chmod 700 "$_ap"
	SSH_ASKPASS=$_ap SSH_ASKPASS_REQUIRE=force
	export SSH_ASKPASS SSH_ASKPASS_REQUIRE
	SSHOPT="$SSHOPT -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1"
else
	SSHOPT="$SSHOPT -o BatchMode=yes"
fi

# 找一个能登录的用户名（原厂只有 root，我们的镜像只有 admin）。
login=
for u in ${NPU_USER:-root admin}; do
	# shellcheck disable=SC2086
	if ssh $SSHOPT "$u@$NPU" true 2>/dev/null; then login=$u; break; fi
done
[ -n "$login" ] || die "ssh 登不进 $NPU（试过 ${NPU_USER:-root admin}）"

echo "== $login@$NPU 可登录"

sec=$(ssh $SSHOPT "$login@$NPU" "cat /sys/class/block/$PNAME/size" 2>/dev/null) ||
	die "拿不到 $PNAME 大小"
bytes=$((sec * 512))
echo "== $PNAME = $bytes 字节（$((bytes / 1048576)) MiB）"

if command -v zstd >/dev/null 2>&1 && [ "${TAR##*.}" = zst ]; then
	unc=$(zstd -l "$TAR" 2>/dev/null | awk '/^[0-9]/{print $5}' | tail -1)
	echo "== 压缩包解压后 ${unc:-?} 字节"
fi

if [ -n "$SRC" ]; then
	# 现成的镜像：只做检查，不重建。它必须是**裸文件系统**——带分区表的整盘镜像
	# 写进分区等于把分区表塞到 p2 里，p2 反而还是坏的（这是 2026-11-24 那次事故的镜像版）。
	[ -f "$SRC" ] || die "找不到 SRC=$SRC"
	_sig=$(dd if="$SRC" bs=512 count=1 2>/dev/null | tail -c 2 | od -An -tx1 | tr -d ' \n')
	[ "$_sig" = "55aa" ] && die \
		"$SRC 的 LBA 0 以 55AA 结尾 —— 这是整盘镜像（有分区表），不能写进 $PART"
	_size=$(stat -c %s "$SRC")
	[ "$_size" -le "$bytes" ] || die \
		"$SRC 有 $_size 字节，比 $PNAME（$bytes 字节）还长，拒绝写"
	echo "== 直接写现成镜像 $SRC（$_size 字节）"
	IMG=$SRC
else
	avail=$(df -k "${IMG%/*}" | awk 'NR==2 {print $4 * 1024}')
	echo "== ${IMG%/*} 可用 $((avail / 1048576)) MiB"
	[ "$avail" -ge "$bytes" ] || die "空间不够（要 $((bytes / 1048576)) MiB）"

	echo "== 造镜像 $IMG"
	rm -f "$IMG"
	truncate -s "$bytes" "$IMG" 2>/dev/null || fallocate -l "$bytes" "$IMG" 2>/dev/null ||
		dd if=/dev/zero of="$IMG" bs=1M count=$((bytes / 1048576)) 2>/dev/null || die "建不出镜像"
	mkfs.ext4 -q -F -L root -O ^metadata_csum_seed,^orphan_file -I 256 "$IMG" || die "mkfs.ext4 失败"
	mkdir -p "$MNT"
	mount -o loop "$IMG" "$MNT" || die "挂不上 $IMG"
	zstd -dc "$TAR" | tar -x -C "$MNT" --numeric-owner || echo "   （解包时有报错，继续）"
	cp -f "$DTB" "$MNT/boot/" 2>/dev/null || echo "   （DTB 没放进去，检查 $MNT/boot）"
	# U-Boot 的 bootcmd 找固定文件名 /boot/Image 和 /boot/initrd.img；tar
	# 解包不会跑内核 postinst 钩子，这里补齐（尽量用 hardlink，省 36+34 MB）。
	materialize_boot_names "$MNT" || echo "   （/boot/Image 或 initrd 没补齐，检查 $MNT/boot）"
	sync
	umount "$MNT" || die "卸不下 $MNT"
fi

echo "== 写到 $NPU:$PART（NPU 上正在用的根分区，它会崩）"
sync
dd_rc=0
ssh $SSHOPT "$login@$NPU" "sync; dd of=$PART bs=1M; sync" <"$IMG" || dd_rc=$?

echo "== 回读校验前 4 MiB"
a=$(dd if="$IMG" bs=1M count=4 2>/dev/null | md5sum | cut -d' ' -f1)
b=$(ssh $SSHOPT "$login@$NPU" "dd if=$PART bs=1M count=4 2>/dev/null | md5sum" 2>/dev/null | cut -d' ' -f1)
echo "   本地 $a"
echo "   NPU  ${b:-回读失败（NPU 崩了，属正常）}"
[ -n "$SRC" ] || rm -f "$IMG"

if [ "$a" = "$b" ]; then
	echo "== 校验一致，写完了"
	exit 0
fi
# 回读读不到有两种：NPU 在 dd 里崩了（正常，多半已经写完）或真的没写成。
# dd 自己返回 0 说明整份灌完并 sync 过，按成功算，交给重启去验证。
if [ "$dd_rc" = 0 ]; then
	echo "== dd 返回 0（整份灌完并 sync），NPU 只是没能回读"
	echo "== 重启 NPU 看它起不起来：断电，或从 U-Boot 里 reset"
	exit 0
fi
echo "== 没写成（dd rc=$dd_rc），而且回读也对不上" >&2
exit 1
