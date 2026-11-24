#!/bin/sh
# 历史判决实验（保留用于复现/排除）：x86 的 PCIe 链路到底有没有在干扰 NPU 的启动？
#
# 2026-11-25 的最终结论：真正的复位源是 x86 侧 xgs-ntb-up.sh 的 remove/rescan
# 循环，不是 NPU 的 CP0 MSS/供电。这个脚本仍可用于"把链路彻底关掉再观察"，
# 但不要把它的旧结论（"x86 无罪 ⇒ 一定在 NPU"）当成现在的诊断。
#
#   sudo ./x86-linkoff-test.sh
#
# 做法：先确认 NPU 正在自己循环，然后**彻底关掉**这条 PCIe 链路（Link Disable，
# 不是 remove/rescan —— 后者本身就会重置端点，是我们要排除的动作），干看 45 秒，
# 再恢复。
#
# 判读：
#   仍然大量 BootROM、但没有 "Starting CP0 MSS" → x86 无罪，问题在 NPU 自己
#   出现 "Starting CP0 MSS" 或 "U-Boot"            → x86 的 PCIe 确实在干扰
#   一条 BootROM 都没有                            → NPU 卡死了，断电重来
#
# 为什么用 Link Disable 而不是 remove/rescan：`echo 1 > .../remove` 会重新拉
# PERST#，而 PERST# 本身就是"复位端点"的动作 —— 用它做实验会把因果搞反
# （2026-11-25 那次 2 秒自复位循环就是这么自己坑自己的）。
set -u

TTY=${TTY:-/dev/ttyS2}
PORT=${PORT:-0000:00:03.1}
BASE_SECS=${BASE_SECS:-8}
TEST_SECS=${TEST_SECS:-45}
LINKCTL_OFF=0010          # Link Control: Link Disable = 1
LINKCTL_ON=0000

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "要用 root：sudo $0"
command -v setpci >/dev/null 2>&1 || die "缺 setpci：apt install pciutils"
[ -e "/sys/bus/pci/devices/$PORT" ] || die "找不到根端口 /sys/bus/pci/devices/$PORT"

npu_present() {
	# ⚠ 绝对不要用 `lspci` 判断：读这个端点的配置空间会把 x86 直接搞重启
	# （2026-11-25 实机验证过 —— 端点正在 3.2 s 一轮地复位，主机在它抖动的窗口里
	# 读 config space 会触发致命错误）。sysfs 里的存在性检查不碰硬件。
	[ -e /sys/bus/pci/devices/0000:03:00.0 ] && echo present || echo absent
}

restore_link() {
	setpci -s "$PORT" CAP_EXP+10.w=$LINKCTL_ON 2>/dev/null
	echo 1 > /sys/bus/pci/rescan 2>/dev/null
	echo "== 链路已恢复；端点 $(npu_present)"
}
trap restore_link EXIT INT TERM

count() { tr -d '\000' < "$1" | grep -a -c "$2" 2>/dev/null || true; }

# Kernel 往 ttyS0（也就是我们自己的控制台）刷日志会把抓包搅乱
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

echo "== 0. 现状（只用 sysfs，不读端点配置空间）"
echo "   NPU 端点    : $(npu_present)  (/sys/bus/pci/devices/0000:03:00.0)"
echo "   根端口      : $PORT"

echo "== 1. 先关掉 PCIe 链路（这一步在任何探测之前做）"
setpci -s "$PORT" CAP_EXP+10.w=$LINKCTL_OFF || die "setpci 写失败"
sleep 2
echo "   端点 $(npu_present)（期望 absent）"

echo "== 2. 干看 ${TEST_SECS}s（这期间完全不碰 PCIe，也不读 config space）"
timeout "$TEST_SECS" dd if="$TTY" of=/tmp/linkoff-test.log bs=1 count=3000000 status=none 2>/dev/null
n=$(count /tmp/linkoff-test.log "BootROM")
cp0=$(count /tmp/linkoff-test.log "Starting CP0 MSS")
ub=$(count /tmp/linkoff-test.log "U-Boot")
echo "   BootROM=$n  Starting CP0 MSS=$cp0  U-Boot=$ub"

echo "== 3. 结论"
if [ "$n" -eq 0 ]; then
	echo "   ✗ 一条 BootROM 都没有：NPU 卡死了（连看门狗都没跑）。断电重来一次。"
	exit 1
elif [ "$cp0" -gt 0 ] || [ "$ub" -gt 0 ]; then
	echo "   ⚠ 关键：关掉 PCIe 之后 NPU 走到了「启动 CP0 MSS」/ U-Boot。"
	echo "     ⇒ x86 的 PCIe 链路确实在干扰 NPU 启动（很可能是主机枚举端点把它打断了）。"
	echo "     下一步方向：Comphy lane 配置、PERST# 时序，或者干脆让 x86 在这个阶段不碰 PCIe。"
	echo "   --- 抓到的关键行："
	tr -d '\000' < /tmp/linkoff-test.log | grep -a -E "Starting CP0 MSS|U-Boot|BL31" | head -5
	exit 0
else
	echo "   ✓ NPU 仍在同一处失败（BL31 前，没有 Starting CP0 MSS）。"
	echo "     ⇒ x86 无罪，问题在 NPU 自己（CP0 MSS / 供电 / PMIC）。转硬件方向。"
	echo "   --- 最后几行："
	tr -d '\000' < /tmp/linkoff-test.log | tr -c '[:print:]\n' '.' | tail -4
	exit 0
fi
