#!/bin/bash
# 组装 NPU 的"急救包"：Image.gz + initramfs.gz + DTB。
#
#   ./tools/build/build-rescue.sh --npu out/debian-npu.tar.zst --out out/xgs87-rescue.tar.zst
#
# 这一包是给最坏情况用的：NPU 的 Debian 起不来、也没有 USB 网卡做物理旁路。
# 它只有十几 MB，可以走串口推进 U-Boot 的内存，起来之后把 vNTB 拉通，
# 再让 x86 用 HTTP/NBD 把整份 rootfs 送过来。
#
# 为什么能这么小：
#   * 用户态只有一个静态 busybox（wget/dd/ip/mount/modprobe 全在里面）
#   * 内核模块只挑急救要用的那几个（EP + ntb + mmc + vlan），不是整个 /lib/modules
#   * 不需要 nbd-server / sshd / zstd / glibc
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
NPU=
OUT=$REPO/out/xgs87-rescue.tar.zst
BUSYBOX_DEB=
KERNEL_DIR=
MIRROR=http://deb.debian.org/debian

while [ $# -gt 0 ]; do
	case "$1" in
	--npu)    NPU=$2; shift 2 ;;
	--out)    OUT=$2; shift 2 ;;
	--busybox-deb) BUSYBOX_DEB=$2; shift 2 ;;
	--kernel) KERNEL_DIR=$2; shift 2 ;;
	--mirror) MIRROR=$2; shift 2 ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$NPU" ] || { echo "--npu <debian-npu.tar.zst> is required" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
R=$WORK/root
mkdir -p "$R"/{bin,sbin,proc,sys,dev,run,tmp,lib/modules}

echo "== 1/6 从 NPU 的 tar 里取内核和模块"
# Debian 是 merged-/usr：模块在 ./usr/lib/modules，/lib 是个符号链接。
# 镜像里没有 /boot/Image（那是装机后由 postinst 钩子从 vmlinuz 解出来的），
# 只有 vmlinuz-<kver>。分开解：一个通配符没匹配到不该让整条命令失败。
tar --zstd -xf "$NPU" -C "$WORK" --wildcards './boot/*' 2>/dev/null || true
tar --zstd -xf "$NPU" -C "$WORK" --wildcards './usr/lib/modules/*' 2>/dev/null || true
KRUN=
for k in "$WORK"/boot/vmlinuz-* "$WORK/boot/Image"; do
	[ -f "$k" ] && { KRUN=$k; break; }
done
[ -n "$KRUN" ] || { echo "tar 里没有内核" >&2; exit 1; }
[ -d "$WORK/lib/modules" ] || ln -s "$WORK/usr/lib/modules" "$WORK/lib/modules" 2>/dev/null || {
	mkdir -p "$WORK/lib"; ln -s "$WORK/usr/lib/modules" "$WORK/lib/modules"
}
KVER=
if [ -n "$KERNEL_DIR" ]; then
	KVER=$(cat "$KERNEL_DIR/kver")
	SRC_MODS="$KERNEL_DIR/modules/lib/modules/$KVER"
else
	SRC_MODS="$WORK/lib/modules/$KVER"
fi
for d in "$WORK"/lib/modules/*; do
	[ -d "$d" ] && { KVER=${d##*/}; break; }
done
[ -n "$KVER" ] || { echo "读不出内核版本" >&2; exit 1; }
echo "   kernel $KVER"

# 急救要用的模块（EP + ntb 必须；mmc 用来写 eMMC）。急救全程用裸 eth0，
# 不碰 VLAN，所以 8021q/vlan 不用带。
KEEP="pci_ep_cfs pcie_dw_plat pci_epf_vntb ntb_core ntb_hw_epf ntb_transport ntb_netdev
      sdhci sdhci-of-dwcmshc mmc_block dw_mmc"
mkdir -p "$R/lib/modules/$KVER"
for m in $KEEP; do
	f=$(find "$SRC_MODS" -name "$m.ko*" | head -1)
	[ -n "$f" ] || continue
	d=$R/lib/modules/$KVER/${f#"$SRC_MODS/"}
	mkdir -p "$(dirname "$d")"
	cp "$f" "$d"
done
cp "$WORK/lib/modules/$KVER/modules.order" "$R/lib/modules/$KVER/" 2>/dev/null || true
cp "$WORK/lib/modules/$KVER/modules.builtin" "$R/lib/modules/$KVER/" 2>/dev/null || true
if command -v depmod >/dev/null 2>&1; then
	depmod -b "$R" "$KVER" 2>/dev/null || echo "   depmod 失败，退化成按名字 insmod"
fi
echo "   模块 $(find "$R/lib/modules" -name '*.ko*' | wc -l) 个，$(du -sh "$R/lib/modules" | cut -f1)"

echo "== 2/6 取 arm64 的静态 busybox"
if [ -z "$BUSYBOX_DEB" ]; then
	name=$(curl -fsS "$MIRROR/pool/main/b/busybox/" |
		grep -oE 'busybox-static_[0-9][^"<>]*_arm64[.]deb' | sort -uV | tail -1)
	[ -n "$name" ] || { echo "从 $MIRROR 找不到 busybox-static arm64" >&2; exit 1; }
	BUSYBOX_DEB=$WORK/$name
	echo "   $name"
	curl -fsS -o "$BUSYBOX_DEB" "$MIRROR/pool/main/b/busybox/$name"
fi
(cd "$WORK" && ar x "$BUSYBOX_DEB" 2>/dev/null; tar -xf data.tar.* 2>/dev/null) || true
BB=$WORK/usr/bin/busybox
[ -f "$BB" ] || BB=$WORK/bin/busybox
[ -f "$BB" ] || { echo "解不出 busybox" >&2; exit 1; }
cp "$BB" "$R/bin/busybox"
chmod 755 "$R/bin/busybox"
echo "   busybox $(du -h "$R/bin/busybox" | cut -f1)"

echo "== 3/6 装 /init"
install -m755 "$REPO/installer/payload/rescue-init" "$R/init"
mkdir -p "$R/dev" "$R/proc" "$R/sys"

echo "== 4/6 打 cpio"
( cd "$R" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 ) >"$WORK/initramfs.gz"

echo "== 5/6 内核准备成 U-Boot 能 unzip 的 Image.gz"
if [ -n "$KERNEL_DIR" ] && [ -f "$KERNEL_DIR/Image.gz" ]; then
	cp "$KERNEL_DIR/Image.gz" "$WORK/kernel.gz"
elif [ -f "$WORK/boot/Image" ]; then
	cp "$WORK/boot/Image" "$WORK/Image"
	gzip -9 -f "$WORK/Image"
	mv "$WORK/Image.gz" "$WORK/kernel.gz"
else
	k=$(ls "$WORK"/boot/vmlinuz-* | head -1)
	if file "$k" | grep -qi 'gzip'; then
		cp "$k" "$WORK/kernel.gz"
	else
		cp "$k" "$WORK/Image"; gzip -9 -f "$WORK/Image"; mv "$WORK/Image.gz" "$WORK/kernel.gz"
	fi
fi

echo "== 6/6 打包"
mkdir -p "$WORK/out"
cp "$WORK/kernel.gz" "$WORK/out/Image.gz"
cp "$WORK/initramfs.gz" "$WORK/out/initramfs.gz"
cp "$REPO"/out/cn9130-sophos-xgs87w-sfp10g.dtb "$WORK/out/" 2>/dev/null || true
[ -f "$WORK/out/cn9130-sophos-xgs87w-sfp10g.dtb" ] || {
	d=$(find "$REPO" -name 'cn9130-sophos-xgs87w-sfp10g*.dtb' | head -1)
	[ -n "$d" ] && cp "$d" "$WORK/out/"
}
tar --zstd -cf "$OUT" -C "$WORK/out" .
ls -lh "$OUT"
tar --zstd -tvf "$OUT" | sed 's/^/   /'
echo
echo "急救包好了。U 盘上它会在 /opt/xgs87/payload/xgs87-rescue.tar.zst 里，"
echo "菜单 2 的最后一级会用它：串口推 Image.gz + initramfs.gz，"
echo "起来后把 p2 的整盘影像走 HTTP 写进去。"