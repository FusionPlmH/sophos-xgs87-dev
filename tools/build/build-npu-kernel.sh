#!/bin/bash
# Build the NPU's kernel Image from the full Debian source tree.
#
# Only needed for options that live inside vmlinux (pstore's console/pmsg
# backends, filesystems, ...).  Everything that is a module is built separately
# by build-npu-net.sh / build-npu-vntb.sh.
#
# Cross-compiled on the PC: Debian's linux-headers package ships aarch64
# fixdep/modpost binaries, which cannot run on an x86 host, so the full tree is
# required (it builds those for the host with the host compiler).
#
#   ./tools/build/build-npu-kernel.sh
#   CONFIG_EXTRA="CONFIG_FOO=y" ./tools/build/build-npu-kernel.sh
#
# The resulting Image is 44 MB and takes about 12 minutes with -j16.
# Modules do NOT have to be rebuilt afterwards as long as the ABI-relevant
# options are untouched -- verify with:
#   md5sum $OBJ/Module.symvers $NPU_ROOT/usr/src/linux-headers-$KVER/Module.symvers
# Both sides must match, otherwise existing .ko files will refuse to load.
set -eu

SRC=${SRC:-/srv/lsrc-deb/usr/src/linux-source-6.12}
OBJ=${OBJ:-/srv/kbuild}
NPU_ROOT=${NPU_ROOT:-/srv/npu}
KVER=${KVER:-6.12.117+deb13-arm64}
ARCH=arm64
CROSS=aarch64-linux-gnu-

mkdir -p "$OBJ"

if [ ! -f "$OBJ/.config" ]; then
	cp "$NPU_ROOT/boot/config-$KVER" "$OBJ/.config"
	# The Debian ABI suffix must live in CONFIG_LOCALVERSION: a localversion
	# file would stack on top of it, and LOCALVERSION= on the command line is
	# dropped by olddefconfig.
	sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"+deb13-arm64\"/" "$OBJ/.config"
fi

# Extra options, one per line in $CONFIG_EXTRA ("CONFIG_X=y CONFIG_Y=m").
for kv in ${CONFIG_EXTRA:-}; do
	k=${kv%%=*}
	# accept both "# CONFIG_X is not set" and "CONFIG_X=..."
	sed -i "/^${k}=/d;/^# ${k} is not set$/d" "$OBJ/.config"
	echo "$kv" >> "$OBJ/.config"
done

make -C "$SRC" O="$OBJ" ARCH=$ARCH CROSS_COMPILE=$CROSS olddefconfig
grep -E '^CONFIG_LOCALVERSION' "$OBJ/.config"

echo "=== building Image"
make -C "$SRC" O="$OBJ" ARCH=$ARCH CROSS_COMPILE=$CROSS -j"$(nproc)" Image

ls -l "$OBJ/arch/arm64/boot/Image"
printf 'vermagic: %s\n' "$(strings "$OBJ/arch/arm64/boot/Image" | grep -m1 -E '^[0-9.]+\+deb13-arm64')"

cat <<EOM

Install on the NPU:
    cp -a /boot/Image /boot/Image.pre-\$(date +%F)
    cp Image /boot/Image            # bootcmd loads /boot/Image on mmc 0:2

Roll back by copying the backup back, or from U-Boot:
    run bootcmd_emmc3               # vendor system on p3
EOM
