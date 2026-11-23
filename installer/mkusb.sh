#!/bin/bash
# 用 debian-x86.img + debian-npu.tar.zst 拼一条自用维护 U 盘。
#
#   ./installer/mkusb.sh \
#       --x86 out/debian-x86.img.zst \
#       --npu out/debian-npu.tar.zst \
#       --dtb out/cn9130-sophos-xgs87w-sfp10g.dtb \
#       --out out/xgs87-usb.img
#
# 做法：先把 x86 的整盘镜像解开，追加一个带标签 XGS87 的 ext4 分区放 payload，
# 再往镜像里的 root 分区塞入 installer 单元并在 tty1 上自动启动菜单。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
X86=
NPU=
DTB=
OUT=$REPO/out/xgs87-usb.img
EXTRA_MB=512

while [ $# -gt 0 ]; do
	case "$1" in
	--x86)   X86=$2; shift 2 ;;
	--npu)   NPU=$2; shift 2 ;;
	--dtb)   DTB=$2; shift 2 ;;
	--out)   OUT=$2; shift 2 ;;
	--extra) EXTRA_MB=$2; shift 2 ;;
	-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$X86" ] && [ -n "$NPU" ] || { echo "--x86 and --npu are required" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

WORK=$(mktemp -d)
LOOP=
cleanup() {
	umount "$WORK/root" 2>/dev/null || true
	umount "$WORK/data" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 解开 x86 镜像"
zstd -dc "$X86" > "$WORK/base.img"

echo "== 追加 payload 分区（+${EXTRA_MB} MiB）"
PAYLOAD_MB=$(( ($(stat -c %s "$NPU") + ${DTB:+$(stat -c %s "$DTB")} + 1048575) / 1048576 + EXTRA_MB ))
cp --sparse=always "$WORK/base.img" "$OUT"
truncate -s +${PAYLOAD_MB}M "$OUT"
# 新分区从最后一个分区的末尾开始
END=$(sfdisk -d "$OUT" | awk -F'[=,]' '/^\/.*[0-9]$/{print $4}' | sort -n | tail -1)
START=$(( END + 2048 ))
echo "start=$START, size=$((PAYLOAD_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"XGS87\"" |
	sfdisk --append "$OUT"

LOOP=$(losetup -f --show -P "$OUT")
mkfs.ext4 -q -L XGS87 "${LOOP}p3"
mkdir -p "$WORK/data" "$WORK/root"
mount "${LOOP}p3" "$WORK/data"
mount "${LOOP}p2" "$WORK/root"

echo "== 放 payload"
mkdir -p "$WORK/data"
cp "$X86" "$WORK/data/debian-x86.img.zst"
cp "$NPU" "$WORK/data/debian-npu.tar.zst"
[ -n "$DTB" ] && cp "$DTB" "$WORK/data/"
cp -a "$REPO"/installer/payload/. "$WORK/data/"
chmod 755 "$WORK/data"/*.sh
sync

echo "== 往 U 盘系统的 root 里塞菜单"
cat > "$WORK/root/etc/systemd/system/xgs87-installer.service" <<'EOF'
[Unit]
Description=XGS 87 维护菜单
After=multi-user.target
ConditionPathExists=/run/media/xgs87

[Service]
Type=simple
ExecStart=/usr/local/sbin/xgs87-menu.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF
install -m755 "$WORK/data/menu.sh" "$WORK/root/usr/local/sbin/xgs87-menu.sh"
mkdir -p "$WORK/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/xgs87-installer.service \
	"$WORK/root/etc/systemd/system/multi-user.target.wants/xgs87-installer.service"

# 让菜单能找到 payload：把 XGS87 分区挂到固定位置
cat > "$WORK/root/etc/systemd/system/run-media-xgs87.mount" <<'EOF'
[Unit]
Description=XGS87 payload partition
Before=local-fs.target

[Mount]
What=/dev/disk/by-label/XGS87
Where=/run/media/xgs87
Type=ext4
Options=ro

[Install]
WantedBy=local-fs.target
EOF
mkdir -p "$WORK/root/etc/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/run-media-xgs87.mount \
	"$WORK/root/etc/systemd/system/local-fs.target.wants/run-media-xgs87.mount"

# U 盘系统不要跑正常的链路单元（那时 NPU 可能是坏的）
for u in xgs-ntb xgs-ntb-watch xgs-netconsole; do
	rm -f "$WORK/root/etc/systemd/system/multi-user.target.wants/$u.service"
done

sync
umount "$WORK/root" "$WORK/data"
losetup -d "$LOOP"; LOOP=

echo "== 压缩"
zstd -T0 -10 -f --rm "$OUT" -o "$OUT.zst"
ls -lh "$OUT.zst"
cat <<EOM

写到 U 盘：
    zstd -d $OUT.zst
    sudo dd if=${OUT%.zst} of=/dev/sdX bs=4M conv=fsync status=progress

插到 XGS 87 上开机，选 USB 启动，tty1 上就是菜单（也走串口 115200）。
EOM