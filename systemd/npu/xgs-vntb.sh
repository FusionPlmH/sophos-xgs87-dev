#!/bin/sh
# Bring up the PCIe endpoint + vNTB link towards the x86 host.
#
# Order matters: the endpoint controller must exist before pci_epf_vntb is
# loaded (the EPF driver needs it), and ntb_transport/ntb_netdev must come
# after the function has been started so an NTB device actually exists.
set -u

C=/sys/kernel/config/pci_ep
EPC=f2600000.pcie

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

modprobe ntb_transport transport_mtu=2048 2>/dev/null
modprobe ntb_netdev 2>/dev/null

echo "xgs-vntb: epc=$EPC start=$(cat "$C/controllers/$EPC/start" 2>/dev/null)" \
	"bars ctrl=$(cat "$N/ctrl_bar" 2>/dev/null)" \
	"db=$(cat "$N/db_bar" 2>/dev/null)" \
	"mw1=$(cat "$N/mw1_bar" 2>/dev/null)"
