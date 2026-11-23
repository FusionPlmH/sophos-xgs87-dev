#!/bin/bash
# 交叉编一个"只够急救用"的 arm64 内核 + 配套模块。
#
#   ./tools/build/build-rescue-kernel.sh --src /path/linux-6.12.117 --out out/rescue-kernel
#
# 产物：out/rescue-kernel/Image.gz、out/rescue-kernel/modules/（ntb_* 等）
# 然后交给 build-rescue.sh --kernel out/rescue-kernel 打进急救包。
#
# 为什么要自己编：Debian 的 Image 解压后 37.7 MB（gz 13.7 MB），里面绝大部分
# 是急救用不到的驱动。裁剪后的预期：Image ~9 MB、gz ~3.5 MB。
#
# ⚠️ 自编内核必须同时编 kernel/npu 的模块（vermagic 要一致），不能混用 Debian 的。
# ⚠️ 打好的包**必须先在一台真机上启动验证过**再当默认急救路径用。
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
SRC=
OUT=$REPO/out/rescue-kernel
CROSS=${CROSS:-aarch64-linux-gnu-}
JOBS=$(nproc 2>/dev/null || echo 2)

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
[ -n "$SRC" ] || { echo "--src <kernel source> is required" >&2; exit 1; }
[ -d "$SRC" ] || { echo "$SRC 不存在" >&2; exit 1; }
mkdir -p "$OUT"

echo "== 1/5 配置"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig >/dev/null
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$SRC" "$SRC/.config" \
	"$REPO/board/rescue-kernel.config" >/dev/null
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig >/dev/null

echo "== 2/5 编内核（-j$JOBS）"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image modules >/dev/null

echo "== 3/5 装模块到 $OUT/modules"
rm -rf "$OUT/modules"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" \
	INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 modules_install >/dev/null
KVER=$(ls "$OUT/modules/lib/modules" | head -1)

echo "== 4/5 编 kernel/npu 的 ntb 模块（必须和这个内核配套）"
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" \
	M="$REPO/kernel/npu" KBUILD_EXTRA_SYMBOLS= modules >/dev/null || true
make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" \
	M="$REPO/kernel/npu" INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 modules_install >/dev/null || true

echo "== 5/5 打包"
gzip -9 -c "$SRC/arch/arm64/boot/Image" >"$OUT/Image.gz"
echo "$KVER" >"$OUT/kver"
ls -lh "$OUT/Image.gz"
du -sh "$OUT/modules"
echo
echo "  下一步： ./tools/build/build-rescue.sh --npu … --kernel $OUT"
echo "  ⚠️ 先在一台真机上启动验证过再当默认路径用。"