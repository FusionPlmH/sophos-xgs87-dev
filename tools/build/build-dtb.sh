#!/bin/bash
# Build the board DTB from board/cn9130-sophos-xgs87w-sfp10g.dts.
#
# Needs a kernel tree only for the Marvell .dtsi files it includes and for
# include/dt-bindings; a sparse clone is enough and is fetched on first run.
#
#   ./tools/build/build-dtb.sh
#   LSRC=/path/to/linux ./tools/build/build-dtb.sh
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${OUT:-$REPO/out}
# Keep the sparse kernel clone inside the repo's out/ so this also works on a
# CI runner, where /srv does not exist and $HOME is not writable by root.
LSRC=${LSRC:-$OUT/linux-src}
DTS=${DTS:-$REPO/board/cn9130-sophos-xgs87w-sfp10g.dts}

if [ ! -d "$LSRC/arch/arm64/boot/dts/marvell" ]; then
	git clone --depth=1 --filter=blob:none --sparse \
		https://github.com/torvalds/linux.git "$LSRC"
	git -C "$LSRC" sparse-checkout set arch/arm64/boot/dts include/dt-bindings
fi

mkdir -p "$OUT"

# The .dts is preprocessed by hand: only the include paths matter, the rest of
# the kernel build system is not involved.
cpp -nostdinc -I "$LSRC/include" -I "$LSRC/arch/arm64/boot/dts" \
    -I "$LSRC/arch/arm64/boot/dts/marvell" -undef -D__DTS__ \
    -x assembler-with-cpp "$DTS" -o "$OUT/board.dts.pp"
dtc -I dts -O dtb -o "$OUT/cn9130-sophos-xgs87w-sfp10g.dtb" "$OUT/board.dts.pp"

ls -l "$OUT/cn9130-sophos-xgs87w-sfp10g.dtb"
cat <<EOM

Install on the NPU (bootcmd loads this exact filename from mmc 0:2):
    cp -a /boot/cn9130-sophos-xgs87w-sfp10g.dtb \\
          /boot/cn9130-sophos-xgs87w-sfp10g.dtb.bak
    cp $OUT/cn9130-sophos-xgs87w-sfp10g.dtb /boot/
    reboot
EOM
