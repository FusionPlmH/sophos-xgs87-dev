#!/bin/sh
# Runs inside the chroot at the end of image/build.sh.
#
#   setup.sh <x86|npu> <full|lean|base>
set -eu

SIDE=$1
VARIANT=$2

echo "== setup.sh: side=$SIDE variant=$VARIANT"

case "$SIDE" in
npu) HOSTNAME=xgs87-npu; ARCH=arm64 ;;
x86) HOSTNAME=debian; ARCH=amd64 ;;
esac
echo "$HOSTNAME" > /etc/hostname
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > /etc/hosts
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
EOF
	# The two boot hooks arrive with image/overlay/npu (they land in
	# /etc/kernel/postinst.d and /etc/initramfs/post-update.d, already
	# executable); just make sure the directories exist.
	chmod 755 /etc/kernel/postinst.d/zz-xgs87-image \
		  /etc/initramfs/post-update.d/zz-xgs87-initrd
	systemctl enable xgs-ports-up xgs-vntb xgs-net-up xgs-dhcp xgs-nat xgs-netconsole
	# Debian ships an nftables.service that flushes the ruleset; our NAT lives in
	# its own table and is applied by xgs-nat.service instead.
	systemctl disable nftables.service >/dev/null 2>&1 || true
else
	systemctl enable systemd-networkd xgs-ntb xgs-ntb-watch xgs-ntb-stop xgs-netconsole
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
# It is the only forensic trace of a lockup (docs/20 §20.8), so it stays on --
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
for d in /etc/systemd/system/ssh.service.d /etc/xgs87 /etc/sysctl.d; do
	[ -d "$d" ] || continue
	find "$d" -type d -exec chmod 755 {} + 2>/dev/null || true
	find "$d" -type f -exec chmod 644 {} + 2>/dev/null || true
done

echo "== setup.sh done"
