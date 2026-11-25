#!/bin/sh
# Bring up the PCIe endpoint + vNTB link towards the x86 host.
#
# Order matters: the endpoint controller must exist before pci_epf_vntb is
# loaded (the EPF driver needs it), and ntb_transport/ntb_netdev must come
# after the function has been started so an NTB device actually exists.
#
# ⚠️ There is **no** way to reset the endpoint controller from inside Linux on
# this board, so do not try (2026-11-25, tested twice):
#
#   * dw-pcie sets suppress_bind_attrs, so /sys/bus/platform/drivers/dw-pcie
#     has no bind/unbind at all;
#   * `modprobe -r pcie_dw_plat` fails, and after the attempt the machine is
#     wedged: sshd accepts TCP but never sends a banner, the console is silent,
#     and only a power cycle brings it back.
#
# Two states therefore need an NPU reboot (or rebooting the x86, whose PERST#
# resets this end too):
#
#   1. the host asserted PERST#, which wipes the endpoint's DBI while configfs
#      still reports start=1 -- we believe we are armed and we are not, so the
#      host's probe times out with "Failed to configure doorbell";
#   2. a previous pci_epf_vntb probe failed, so the controller still counts the
#      BARs as taken.  The next probe asks for a "free" BAR, gets one with size
#      0 and dies with
#          pci_epf_vntb ...: Doorbell BAR set failed
#          pci_epf_vntb ...: Failed to initialize EPC
#      and every later configfs poke fails the same way.
#
# What *is* safe and useful is the soft path: reload the vNTB stack and rewrite
# the configfs function (that is what xgs-vntb-watch.sh does).  Keep the EPC
# armed whenever possible: stopping it without being able to re-create the
# function leaves the endpoint half-armed and kills the link.
set -u

C=/sys/kernel/config/pci_ep
EPC=${EPC:-f2600000.pcie}

case "${1:-}" in
"") ;;
-h | --help)
	echo "usage: $0"
	echo "arms the vNTB endpoint on the NPU (no options: there is no safe way to"
	echo "reset the endpoint controller from Linux, see the comment at the top)"
	exit 0
	;;
*)
	echo "usage: $0" >&2
	exit 2
	;;
esac

modprobe configfs 2>/dev/null
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

modprobe pci_ep_cfs 2>/dev/null
modprobe pcie_dw_plat 2>/dev/null

i=0
while [ ! -d "/sys/class/pci_epc/$EPC" ] && [ $i -lt 30 ]; do
	i=$((i + 1))
	sleep 1
done
if [ ! -d "/sys/class/pci_epc/$EPC" ]; then
	echo "xgs-vntb: no endpoint controller" >&2
	exit 1
fi

modprobe ntb_core 2>/dev/null
modprobe pci_epf_vntb 2>/dev/null

F=$C/functions/pci_epf_vntb/func1
[ -d "$F" ] || mkdir "$F" || exit 1
N=$F/pci_epf_vntb.0
[ -d "$N" ] || { echo "xgs-vntb: no $N" >&2; exit 1; }

echo 0x1957 > "$F/vendorid"
echo 0x0809 > "$F/deviceid"
echo 16     > "$F/msi_interrupts"
# 三个 BAR 号（ctrl=0 / db=2 / mw1=4）是 pci_epf_vntb 的**只读**属性：驱动按
# BAR_1/3/5 = BAR_RESERVED 那张表和 pci_epc_get_next_free_bar() 自己算出来，
# 不能写。以前这里 `echo 0 > $N/ctrl_bar` 之类三行每次启动都刷
# "cannot create .../ctrl_bar: Permission denied"，看上去像配置失败了，其实
# 什么也没发生。改成启动后把驱动算出来的值读回来打日志：真要错位时一眼能看见。
echo 4      > "$N/db_count"
echo 128    > "$N/spad_count"
echo 1      > "$N/num_mws"
echo 0x100000 > "$N/mw1"
echo 0x1957 > "$N/vntb_vid"
echo 0x080A > "$N/vntb_pid"
echo 0x10   > "$N/vbus_number"

[ -e "$C/controllers/$EPC/func1" ] || ln -s "$F" "$C/controllers/$EPC/func1"
echo 1 > "$C/controllers/$EPC/start"

# 武装失败的唯一可靠判据：function 没挂上控制器，或者 start 写不进去。
# 停在"start=1 但没有 function"最糟 —— 对端看到的设备是死的。
if [ ! -e "$C/controllers/$EPC/func1" ] ||
	[ "$(cat "$C/controllers/$EPC/start" 2>/dev/null)" != 1 ]; then
	echo "xgs-vntb: 端点没武装起来（func1/start 不对），把 EPC 停在 0" >&2
	echo 0 >"$C/controllers/$EPC/start" 2>/dev/null || true
	exit 1
fi

modprobe ntb_transport transport_mtu=2048 2>/dev/null
modprobe ntb_netdev 2>/dev/null

echo "xgs-vntb: epc=$EPC start=$(cat "$C/controllers/$EPC/start" 2>/dev/null)" \
	"bars ctrl=$(cat "$N/ctrl_bar" 2>/dev/null)" \
	"db=$(cat "$N/db_bar" 2>/dev/null)" \
	"mw1=$(cat "$N/mw1_bar" 2>/dev/null)"
