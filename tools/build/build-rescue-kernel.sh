#!/bin/bash
# 交叉编一个"只够急救用"的 arm64 内核：tinyconfig 打底 + board/rescue-kernel.config。
#
#   ./tools/build/build-rescue-kernel.sh --src /path/linux-6.12 --out out/rescue-kernel
#   ./tools/build/build-rescue-kernel.sh --src … --fmt lzma
#
# 产物：Image、Image.$FMT、kver、drivers-builtin
# 之后：./tools/build/build-rescue.sh --npu out/debian-npu.tar.zst --kernel out/rescue-kernel
#
# 2026-11-25 实测（16 核，约 2 分钟）：
#   Image 5,265,416 B ｜ gz 2,132,290 ｜ lzma -9 1,625,874
#   Debian 的 Image 37,732,288 B（gz 13,684,970）—— 小 8.4 倍
#   急救包 15.96 MB → 2.69 MB，串口推送 27 分钟 → 约 4.5 分钟
#
# 这个内核里串口 / eMMC / 面板口驱动**全部编进去**，initramfs 里一个模块都不用带。
#
# ⚠️ 必须 tinyconfig 打底。「defconfig 再关几十项」编出来是 40.6 MB / gz 12.3 MB，
#    比 Debian 的还大 —— 因为 arm64 defconfig 自带 2800 多个 =y。
# ⚠️ kernel/npu/ 的 ntb_* 模块编不进 vanilla 内核（依赖 Marvell 厂商 API
#    ntb_get_dma_dev），所以这里不编模块，PCI/vNTB 也不要：急救走面板口。
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=
OUT=$REPO/out/rescue-kernel
FMT=gz
CROSS=${CROSS:-aarch64-linux-gnu-}
JOBS=$(nproc 2>/dev/null || echo 2)

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--fmt) FMT=$2; shift 2 ;;
	-h|--help) sed -n '2,22p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$SRC" ] || { echo "--src <kernel source> is required" >&2; exit 1; }
[ -d "$SRC" ] || { echo "$SRC 不存在" >&2; exit 1; }
case "$FMT" in
gz|lzma) ;;
*) echo "--fmt 只认 gz 或 lzma" >&2; exit 1 ;;
esac
mkdir -p "$OUT"

echo "== 1/5 tinyconfig"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" tinyconfig >/dev/null

echo "== 2/5 合上 board/rescue-kernel.config"
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$SRC" "$SRC/.config" \
	"$REPO/board/rescue-kernel.config" >/dev/null
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig >/dev/null

# merge_config + olddefconfig 会**静默丢掉**依赖不满足的行（PSTORE 和
# MMC_BLOCK 都这么丢过一次），所以逐行核对一遍。
echo "== 3/5 核对片段有没有被悄悄丢掉"
dropped=0
while IFS= read -r line; do
	case "$line" in CONFIG_*=y) ;; *) continue ;; esac
	grep -qx "$line" "$SRC/.config" || { echo "   丢了: $line" >&2; dropped=$((dropped + 1)); }
done <"$REPO/board/rescue-kernel.config"
echo "   $(grep -c '=y$' "$SRC/.config") 个 =y，掉了 $dropped 项"

echo "== 4/5 编内核（-j$JOBS）"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image 2>&1 | tail -3

echo "== 5/5 压缩打包"
cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
case "$FMT" in
gz)   gzip -9 -c "$OUT/Image" >"$OUT/Image.gz" ;;
lzma) lzma -9 -c "$OUT/Image" >"$OUT/Image.lzma" ;;
esac
make -s -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" kernelrelease >"$OUT/kver"
# 告诉 build-rescue.sh：驱动都在内核里，别再往 initramfs 塞模块
: >"$OUT/drivers-builtin"

printf '  Image       %9d\n' "$(stat -c %s "$OUT/Image")"
printf '  Image.%-5s %9d\n' "$FMT" "$(stat -c %s "$OUT/Image.$FMT")"
echo "  kernelrelease $(cat "$OUT/kver")"
echo
echo "  下一步： ./tools/build/build-rescue.sh --npu out/debian-npu.tar.zst --kernel $OUT"
