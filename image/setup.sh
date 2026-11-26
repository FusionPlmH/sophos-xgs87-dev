#!/bin/sh
# Runs inside the chroot at the end of image/build.sh.
#
#   setup.sh <x86|npu> <full|lean|base>
set -eu

SIDE=$1
VARIANT=$2

echo "== setup.sh: side=$SIDE variant=$VARIANT"

case "$SIDE" in
npu) HOSTNAME=xgs-debian-npu; ARCH=arm64 ;;
x86) HOSTNAME=xgs-debian-x86; ARCH=amd64 ;;
esac
echo "$HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > /etc/hosts
# A real /etc/fstab: without the root entry systemd-fsck and initramfs-tools
# cannot tell what "/" is, so the image ended up with no e2fsck in the initramfs
# and no boot-time fsck at all.  The NPU always boots p2 by device name
# (bootargs_deb: root=/dev/mmcblk0p2), so keep the entry in the same terms.
if [ "$SIDE" = npu ]; then
	printf '/dev/mmcblk0p2\t/\text4\tdefaults,noatime,errors=remount-ro\t0 1\n' \
		> /etc/fstab
fi
# There is no `locales` package in the image (nothing reads translations here),
# but C.UTF-8 is built into glibc, so the console still copes with UTF-8 names.
printf 'LANG=C.UTF-8\n' > /etc/locale.conf

# --- units and scripts, straight from the repository ------------------------
# common/ is the same on both machines (root partition growth on first boot).
install -m755 /opt/xgs87/systemd/common/*.sh /usr/local/sbin/
install -m644 /opt/xgs87/systemd/common/*.service /etc/systemd/system/
install -m755 /opt/xgs87/systemd/"$SIDE"/*.sh /usr/local/sbin/
install -m644 /opt/xgs87/systemd/"$SIDE"/*.service /etc/systemd/system/
systemctl enable xgs87-growroot
mkdir -p /etc/systemd/network
for f in /opt/xgs87/systemd/"$SIDE"/*.network; do
	[ -e "$f" ] && install -m644 "$f" /etc/systemd/network/
done

if [ "$SIDE" = npu ]; then
	# Everything the x86 and the switch need is in the units; the modules are
	# what needs building.
	cat > /etc/modules-load.d/xgs87-hardware.conf <<'EOF'
spi-orion
clkfix
# i2c-dev exposes /dev/i2c-1 (mv64xxx on the SFP cage bus).  Without it the
# i2c-tools in this image cannot see anything: measured 2026-11-25, the SFP
# EEPROM answers at 0x50/0x51 only after `modprobe i2c-dev`.
i2c-dev
EOF
	# The two boot hooks arrive with image/overlay/npu (they land in
	# /etc/kernel/postinst.d and /etc/initramfs/post-update.d, already
	# executable); just make sure the directories exist.
	chmod 755 /etc/kernel/postinst.d/zz-xgs87-image \
		  /etc/initramfs/post-update.d/zz-xgs87-initrd
	systemctl enable xgs-ports-up xgs-vntb xgs-vntb-watch xgs-net-up xgs-dhcp xgs-nat xgs-netconsole \
		xgs-watchdog
	# Debian ships an nftables.service that flushes the ruleset; our NAT lives in
	# its own table and is applied by xgs-nat.service instead.
	systemctl disable nftables.service >/dev/null 2>&1 || true
else
	systemctl enable systemd-networkd xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole
	# k10temp is the only CPU temperature sensor this SoC exposes and Debian does
	# not load it by itself: without it the x86 side has no hwmon at all, so
	# nothing watches the CPU (measured 2026-11-25: 40.8 C once loaded).
	cat > /etc/modules-load.d/xgs87-hardware.conf <<'EOF'
k10temp
fam15h_power
EOF
fi

# --- out-of-tree modules ----------------------------------------------------
# full keeps dkms, so a later kernel upgrade rebuilds the modules by itself.
# lean builds them once with plain make and purges the toolchain again.
TOOLCHAIN=
if [ "$VARIANT" = lean ]; then
	# Installed here rather than through build.sh's --include: mmdebstrap marks
	# everything in that list manual, and manual packages are never
	# autoremoved -- so the only reliable purge list is the dpkg delta.
	dpkg-query -W -f='${binary:Package}\n' | sort > /tmp/xgs87-pkgs.before
	apt-get install -y --no-install-recommends build-essential "linux-headers-$ARCH" >/dev/null
	dpkg-query -W -f='${binary:Package}\n' | sort > /tmp/xgs87-pkgs.after
	TOOLCHAIN=$(comm -13 /tmp/xgs87-pkgs.before /tmp/xgs87-pkgs.after | tr '\n' ' ')
fi

if [ "$VARIANT" = full ] || [ "$VARIANT" = lean ]; then
	PKG=xgs87-$SIDE
	VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' /opt/xgs87/kernel/"$SIDE"/dkms.conf)
	# Inside the chroot uname -r is the *host* kernel, so ask the tree which
	# kernel is actually installed here.
	KVER=$(ls /lib/modules | sort -V | tail -1)
	if [ ! -d "/lib/modules/$KVER/build" ]; then
		echo "== no headers for $KVER, skipping the module build" >&2
	elif [ "$VARIANT" = full ]; then
		mkdir -p /usr/src/$PKG-$VER
		cp /opt/xgs87/kernel/"$SIDE"/*.c /opt/xgs87/kernel/"$SIDE"/Makefile \
		   /opt/xgs87/kernel/"$SIDE"/dkms.conf /usr/src/$PKG-$VER/ 2>/dev/null || true
		cp /opt/xgs87/kernel/"$SIDE"/*.h /usr/src/$PKG-$VER/ 2>/dev/null || true
		dkms add "$PKG/$VER"
		dkms build "$PKG/$VER" -k "$KVER"
		dkms install "$PKG/$VER" -k "$KVER" --force
		echo "== dkms: $(dkms status "$PKG")"
	else
		SRC=/usr/src/$PKG-$VER
		mkdir -p "$SRC"
		cp /opt/xgs87/kernel/"$SIDE"/*.c /opt/xgs87/kernel/"$SIDE"/Makefile "$SRC"/
		cp /opt/xgs87/kernel/"$SIDE"/*.h "$SRC"/ 2>/dev/null || true
		make -C "$SRC" KDIR=/lib/modules/"$KVER"/build -j"$(nproc)"
		# Not `make -C $SRC modules_install`: our Makefile has no such target,
		# the kernel tree's does the install.
		make -C /lib/modules/"$KVER"/build M="$SRC" modules_install
		depmod -a "$KVER"
		echo "== module: $(modinfo -k "$KVER" -F filename ntb_core)"
	fi
fi

# --- initramfs --------------------------------------------------------------
# Regenerate on both sides, not just the NPU.  The kernel package built its own
# initramfs during mmdebstrap, i.e. before image/overlay was copied in, so
# without this the image ships an initramfs with no fsck in it and every boot
# logs "Warning: fsck not present, so skipping root file system" -- measured on
# the x86, first boot of the 762 MB image on 2026-11-25.
KVER=${KVER:-$(ls /lib/modules 2>/dev/null | sort -V | tail -1)}
INITRD=
if [ -n "$KVER" ]; then
	mkdir -p /boot
	# -v so the build log shows which hooks actually ran; the fsck hooks are
	# the difference between "a damaged root is repairable at boot" and "it
	# is not".
	update-initramfs -u -k "$KVER" -v 2>&1 |
		grep -E 'Calling hook|^W:|^E:' || true
	INITRD=/boot/initrd.img-$KVER
fi
# Do not trust the hook to have done it: verify, and do not depend on
# unmkinitramfs here (qemu-built images may not have it).
if [ -n "$INITRD" ] && [ -f "$INITRD" ] && command -v cpio >/dev/null 2>&1; then
	if ! { zstd -dc "$INITRD" 2>/dev/null || cat "$INITRD"; } |
		cpio -t 2>/dev/null | grep -qxE '(usr/)?sbin/fsck'; then
		echo "== warning: $INITRD contains no fsck, so a damaged root could" \
			"only be repaired offline. Look at" \
			"etc/initramfs-tools/conf.d/10-xgs87-fstype.conf and" \
			"etc/initramfs-tools/hooks/xgs87-e2fsck in image/overlay/common," \
			"then run 'update-initramfs -u' on the target." >&2
	fi
fi

# --- fixed boot filenames ---------------------------------------------------
# U-Boot's bootcmd_deb loads /boot/Image and /boot/initrd.img by fixed name.
# The kernel postinst hooks create them, but a rootfs tar is unpacked by the
# installer without running those hooks, so materialize them here first.  A
# hardlink keeps the image from carrying a second 36 MB kernel or 34 MB initrd;
# the tar preserves hardlinks.  The postinst hooks still update them later.
if [ "$SIDE" = npu ]; then
	if [ -n "$KVER" ] && [ -f "/boot/vmlinuz-$KVER" ] && [ ! -e /boot/Image ]; then
		ln -f "/boot/vmlinuz-$KVER" /boot/Image 2>/dev/null ||
			cp -f "/boot/vmlinuz-$KVER" /boot/Image
	fi
	if [ -n "$KVER" ] && [ -f "/boot/initrd.img-$KVER" ] && [ ! -e /boot/initrd.img ]; then
		ln -f "/boot/initrd.img-$KVER" /boot/initrd.img 2>/dev/null ||
			cp -f "/boot/initrd.img-$KVER" /boot/initrd.img
	fi
	# bootcmd_deb also loads the board DTB by fixed name.  The installer used to
	# be the only thing that put it there, so any other install path (a plain
	# tar unpack) produced an unbootable machine.  Ship it in the image.
	_dtb=/opt/xgs87/board/cn9130-sophos-xgs87w-sfp10g.dtb
	if [ -f "$_dtb" ] &&
		! cmp -s "$_dtb" /boot/cn9130-sophos-xgs87w-sfp10g.dtb; then
		cp -f "$_dtb" /boot/cn9130-sophos-xgs87w-sfp10g.dtb
	fi
fi

# --- accounts ---------------------------------------------------------------
# The only login account in the image.  There is deliberately no usable root
# account: root stays uid 0 for the system, but it has no password and cannot
# log in over ssh, so everything is done as admin through sudo.
useradd --create-home --shell /bin/bash --groups sudo admin
echo "admin:P@ssw0rd" | chpasswd
# useradd 建的家目录权限取决于当时的 umask 和 uid 分配，装完就出现过
# "/home/admin: change directory failed: Permission denied"（home 进去了没权限，
# 或者 /home 本身不是 755）。这里显式钉死，别让它再依赖 useradd 的心情。
chmod 755 /home
install -d -o admin -g admin -m 0755 /home/admin
chown -R admin:admin /home/admin
# ping 默认不带 setuid，非 root 会 "missing cap_net_raw+p" —— 维护脚本里的
# find_npu 就是被这个坑过（明明通却报 NPU 不可达）。
if command -v setcap >/dev/null 2>&1; then setcap cap_net_raw+ep /usr/bin/ping 2>/dev/null || true; fi
passwd -l root
# 维护 U 盘是 live 系统：插上去的人已经有物理访问权，控制台直接用 root 更省事
# —— 今天实机上一半的坑都是 sudo 提示和串口输出交错造成的（密码被当成命令、
# 提示被内核刷屏冲掉）。装进内置盘的系统仍然锁 root，admin + sudo 不变。
if [ "${XGS_LIVE_ROOT:-0}" = 1 ]; then
	echo 'root:P@ssw0rd' | chpasswd
	sed -i 's/^root:x:/root:/' /etc/shadow 2>/dev/null || true
fi
cat > /etc/ssh/sshd_config.d/10-xgs87.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
EOF

# --- housekeeping -----------------------------------------------------------
# The x86's FCH HD-audio controller has no codecs behind it; loading the driver
# only produces probe errors.  Nothing on this appliance uses audio.
printf 'blacklist snd_hda_intel\n' > /etc/modprobe.d/xgs87-no-audio.conf
systemctl enable systemd-timesyncd ssh

# lean: the compiler only had to build the modules once.  Dropping it is where
# the ~380 MiB go; because nothing here can then rebuild them, the kernel is
# held -- /opt/xgs87/kernel/<side>/install.sh (or kernel/<side>/install.sh on a
# clone) installs dkms + headers on the device and rebuilds when the user does
# want to move to a newer kernel.
if [ "$VARIANT" = lean ]; then
	if [ -n "$TOOLCHAIN" ]; then
		apt-get purge -y $TOOLCHAIN >/dev/null
	fi
	apt-get autoremove -y >/dev/null
	rm -rf /usr/src/xgs87-* /tmp/xgs87-pkgs.*
	if command -v gcc >/dev/null 2>&1; then
		echo "== lean: warning, compiler left behind:" >&2
		dpkg -l 'gcc*' 'cpp*' 'make' 'libc6-dev' 2>/dev/null | awk '/^ii /{print "   " $2}' >&2
	fi
	# `dpkg-query -W 'linux-image-*'` also drags in the virtual
	# linux-image-generic and the -unsigned variants, which apt-mark cannot
	# hold; ask dpkg -l for the packages that are really installed.
	HELD=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii /{print $2}')
	if [ -n "$HELD" ]; then
		apt-mark hold $HELD >/dev/null
	fi
	echo "== lean: held $(apt-mark showhold | tr '\n' ' ')"
fi

: > /etc/machine-id
rm -f /etc/ssh/ssh_host_*
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt
find /var/log -type f -exec truncate -s0 {} +

# --- keep the journal, bound the journal ------------------------------------
# It is the only forensic trace of a lockup (docs/20 §11.1), so it stays on --
# 248 MB of it piled up on the live x86 -- and the timers that maintain things
# this image does not have are masked: no keyboard or monitor, no man pages,
# no LVM (e2scrub), no XFS, and no unattended apt run (updates are deliberate
# on an appliance whose kernel package may be held).
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/xgs87.conf <<'EOF'
[Journal]
SystemMaxUse=64M
SystemKeepFree=256M
EOF
systemctl mask getty@tty1.service man-db.timer dpkg-db-backup.timer \
	e2scrub_all.timer xfs_scrub_all.timer \
	apt-daily.timer apt-daily-upgrade.timer >/dev/null

# /tmp in RAM (what DietPi does by default): nothing here wants a temp file on
# eMMC, and the payload scripts stream rather than write.
if [ -e /usr/lib/systemd/system/tmp.mount ]; then
	mkdir -p /etc/systemd/system/tmp.mount.d
	printf '[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev,size=128M,nr_inodes=1m\n' \
		> /etc/systemd/system/tmp.mount.d/size.conf
	systemctl enable tmp.mount >/dev/null
fi

# image/overlay comes from a Windows checkout, so everything in it arrives
# mode 0777 -- systemd warns about world-writable drop-ins and keeps going.
# net.conf is *sourced* by root, so it must not be writable by anyone else.
for d in /etc/systemd/system/ssh.service.d /etc/xgs87 /etc/sysctl.d /etc/default; do
	[ -d "$d" ] || continue
	find "$d" -type d -exec chmod 755 {} + 2>/dev/null || true
	find "$d" -type f -exec chmod 644 {} + 2>/dev/null || true
done

# Last, and deliberately after every apt run above: dhcpcd 10 hands DNS to
# systemd-resolved as soon as it finds it, but nothing ever adds br-wan to
# resolved, so /etc/resolv.conf ends up on the 127.0.0.53 stub with no upstream
# -- no DNS at all, which also takes NTP and apt down with it.  Drop resolved
# and leave a plain /etc/resolv.conf for dhcpcd to rewrite.
if [ "$SIDE" = npu ]; then
	apt-get purge -y systemd-resolved >/dev/null 2>&1 || true
	rm -f /etc/resolv.conf
	: > /etc/resolv.conf
fi

echo "== setup.sh done"
