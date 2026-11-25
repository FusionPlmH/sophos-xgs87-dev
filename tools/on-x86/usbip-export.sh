#!/bin/sh
# 把 x86 上的一个 USB 设备"反射"给 NPU（USB/IP）。
#
#   sudo ./usbip-export.sh list                 # 本机有哪些 USB 设备 / 哪个已导出
#   sudo ./usbip-export.sh export 1-1.3         # 导出（NPU 才能 attach）
#   sudo ./usbip-export.sh unexport 1-1.3       # 收回（x86 重新拿到这个设备）
#   sudo ./usbip-export.sh status               # 已导出的清单
#
# NPU 那一端（一条命令，NPU 上要有 usbip）：
#   sudo modprobe vhci-hcd
#   sudo usbip attach -r 10.234.56.2 -b <busid>
#   sudo usbip detach -p 00          # 用完断开，否则 x86 拿不回来
#
# 为什么 NPU 能用：它是 USB/IP 的 *客户端*，内核里的 vhci-hcd 是一个**虚拟**主控
# ——不需要 NPU 板子上有 USB 硬件（这台机器的 CN9130 上一个 USB 主控都没有）。
# 数据走 vNTB 的 TCP：1.2 Gbit/s 的链路远快于 USB 2.0 的 480 Mbit/s，所以瓶颈
# 永远在设备侧。
#
# ⚠️ 导出期间设备**只在 NPU 上可见**，x86 上的驱动已经解绑（hidraw / ttyUSB /
# sdX 都会消失）。忘了 unexport 的话，x86 上那些工具会报"找不到设备"。
#
# ⚠️ 需要先在两台机器上装 usbip（镜像里已经带了；老系统用
#    `apt install usbip usb.ids`）。内核模块 usbip-host(服务端) / vhci-hcd(客户端)
#    都是 Debian 内核自带的模块。
set -u

die() { echo "usbip-export: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

# 服务端要 usbip-host；没有它就 bind 不了。daemon 自己不会去 modprobe 它。
load_server() {
	modprobe usbip-core 2>/dev/null || true
	modprobe usbip-host 2>/dev/null || die "modprobe usbip-host 失败（这个内核带了 USBIP_HOST 吗？）"
	command -v usbipd >/dev/null 2>&1 || die "没有 usbipd（apt install usbip）"
	if ! ss -ltn 2>/dev/null | grep -q ':3240 '; then
		usbipd -D || die "usbipd 起不来"
		# 它 fork 到后台，给一秒让 socket 真的 listen
		i=0
		while [ "$i" -lt 20 ]; do
			ss -ltn 2>/dev/null | grep -q ':3240 ' && return 0
			i=$((i + 1)); sleep 0.1
		done
		die "usbipd 启动了但 3240 没在监听"
	fi
}

cmd=${1:-list}
case "$cmd" in
list)
	load_server
	echo "== 本机 USB 设备（busid 是 export 要的参数）"
	usbip list -l | sed 's/^/  /'
	echo
	echo "== 已经导出的"
	_exported=$(usbip list -r 127.0.0.1 2>/dev/null | sed -n '3,$p')
	if [ -n "${_exported// /}" ]; then
		printf '%s\n' "$_exported" | sed 's/^/  /'
	else
		echo "  （无）"
	fi
	;;

export)
	[ $# -ge 2 ] || die "用法：$0 export <busid>（busid 从 list 里抄，例如 1-1.3）"
	busid=$2
	load_server
	usbip bind -b "$busid" || exit 1
	echo
	echo "NPU 上执行："
	echo "  sudo modprobe vhci-hcd"
	echo "  sudo usbip attach -r $(ip -4 -br a show eth0.200 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1 || echo 10.234.56.2) -b $busid"
	;;

unexport)
	[ $# -ge 2 ] || die "用法：$0 unexport <busid>"
	usbip unbind -b "$2" || exit 1
	echo "已收回；x86 会在 1-2 秒内重新枚举这个设备（hidraw/sdX 会回来）"
	;;

status)
	usbip port 2>/dev/null | sed 's/^/  /'
	;;

-h | --help)
	sed -n '2,30p' "$0"
	;;

*)
	die "不认识的子命令 '$cmd'（list / export / unexport / status）"
	;;
esac
