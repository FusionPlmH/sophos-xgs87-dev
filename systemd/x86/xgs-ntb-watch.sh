#!/bin/sh
# 一直盯着 vNTB 这条链路 —— 这里才是"恢复"的地方，xgs-ntb-up.sh 只是开机的第一次尝试。
#
# 为什么必须常驻：上电顺序不受我们控制
#   * BIOS 扫 PCIe 时 NPU 的端点常常还没武装（NPU 自己上电到 vNTB 就绪 ~12 s）；
#   * host 重启会先拉 PERST# 把 NPU 一起复位，两边同时起来；
#   * NPU 单独重启 / 进 U-Boot / 换镜像，链路就是会消失又出现。
# 一次性脚本只要抢在"端点还没出现"那一瞬间跑完就 exit 1，然后**再没人管**：症状是
# lspci 里有 1957:0809、却没有 eth0，只能人工登进去敲命令（2026-11-25 上电后就是这样，
# 而这台机器唯一的网络就是这条链路，等于把自己关在门外）。
#
# 恢复动作按代价从低到高排成一条梯子，全部在真机上验证过：
#
#   peer-down  接口在、carrier=1，但对端 PING_CD 秒不答 —— 绝大多数情况是对端
#              重启过。端点那边的 BAR 分配被硬件清掉了，我们这边的 pci_dev 还
#              记着老地址，probe 写门铃写到一个不存在的地址上 → -110，dmesg 里
#              还会带一条 AMD-Vi 的 IO_PAGE_FAULT。**只有重枚举能救**，重装协议栈
#              连试两次都是 -110（2026-11-25 实测）。
#   0. 端点在、**没有驱动** → 后台再写一次 `.../ntb_hw_epf/bind`（每 BIND_CD 秒）
#      ntb_hw_epf 的 probe 失败之后**内核不会重试**，函数就那样光秃秃地挂在总线上
#      （lspci 正常、BAR 都分配好了、链路 8GT/s x2），看着完全没事但没有 eth0。
#   0b. 还是没驱动，而且挂了 REENUM_AFTER 秒 → **remove + rescan**（REENUM_CD 冷却）
#      实测不会复位 NPU；probe 会在内核里卡几十秒，所以 bind / remove 都放后台，
#      绝不让监视线程跟着卡住。
#   1. 端点在、有驱动、没 netdev → 重跑 xgs-ntb-up.sh（PLUMB_CD 秒一次，不碰 PCIe）
#   2. 接口在但 carrier 不是 1 → 重新 up + 补地址（PLUMB_CD 秒一次）
#   3. 总线上没有端点 → plain `/sys/bus/pci/rescan`（RESCAN_CD 秒一次，不碰已知设备）
#   4. 1/2 连着 STACK_AFTER 秒都没好 → 卸掉本机 NTB 协议栈再装（STACK_CD 冷却）：
#      对端只重启了 vNTB、硬件没复位时 QP 会停在老状态，只有这一档有用。
#   5. 端点连着 RETRAIN_AFTER 次都没出现 → toggle 根端口 Link Disable 重训链路
#
# ⚠️ remove+rescan 只在**端点没有驱动**或**对端已经不答了**的时候做 —— 那两种
#    状态下内核手里的设备要么是空的、要么已经是坏的，remove 不会破坏任何正在工作
#    的东西。有驱动、carrier=1、对端也答得上的设备永远不碰。
set -u

export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

INTERVAL=${INTERVAL:-5}
PEER=${PEER:-10.234.56.1}
BIND_CD=${BIND_CD:-8}			# 重试 ntb_hw_epf bind 的冷却
REENUM_AFTER=${REENUM_AFTER:-20}	# 端点挂着没驱动多久就重枚举
REENUM_CD=${REENUM_CD:-90}		# 重枚举的冷却
PLUMB_CD=${PLUMB_CD:-8}
RESCAN_CD=${RESCAN_CD:-5}
STACK_AFTER=${STACK_AFTER:-45}		# 多久没好就开始重装协议栈
STACK_CD=${STACK_CD:-60}		# 重装协议栈的冷却
PING_CD=${PING_CD:-25}			# carrier=1 但对端不通多久判定链路不可用
RETRAIN_AFTER=${RETRAIN_AFTER:-12}
RETRAIN_CD=${RETRAIN_CD:-180}
WATCH_LOG=${WATCH_LOG:-/var/log/xgs-ntb-watch.log}
# shellcheck disable=SC1091
[ -r /etc/default/xgs-ntb-watch ] && . /etc/default/xgs-ntb-watch

log() {
	echo "xgs-ntb-watch: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t xgs-ntb-watch "$*"
}

find_epf() {
	local d
	for d in /sys/bus/pci/devices/*; do
		[ -r "$d/vendor" ] || continue
		[ "$(cat "$d/vendor" 2>/dev/null)" = 0x1957 ] || continue
		[ "$(cat "$d/device" 2>/dev/null)" = 0x0809 ] || continue
		PCI_DEV=$d
		return 0
	done
	return 1
}

pci_driver() {
	local d
	# readlink -f prints the path unchanged when the last component is not a
	# symlink (or does not exist), so a device with *no* driver would answer
	# "driver" here and look bound to something else.  Check first.
	[ -e "$1/driver" ] || return 0
	d=$(readlink -f "$1/driver" 2>/dev/null) || return 0
	echo "${d##*/}"
}

# 让内核把 probe 再跑一遍。probe 失败过一次之后没有任何东西会重试它，
# 而端点晚一小步武装就足以让它失败（见文件头第 0 档）。
#
# probe 在端点不响应时会在内核里卡几十秒（读 BAR 的 config cycle 超时），
# 所以一律扔后台 + 加锁，绝不让监视线程跟着卡住。
BIND_LOCK=/run/xgs-ntb-bind.lock

pci_bind_bg() {
	[ -e "$BIND_LOCK" ] && return 1
	: >"$BIND_LOCK"
	(
		timeout 45 sh -c "echo ${PCI_DEV##*/} > /sys/bus/pci/drivers/ntb_hw_epf/bind" 2>/dev/null
		rm -f "$BIND_LOCK"
	) >/dev/null 2>&1 &
	return 0
}

# 重枚举 = remove + rescan。这一档是必须的，不是"更狠的 bind"：
# 对端重启之后，端点那边的 BAR 分配被硬件清掉了，而我们这边的 pci_dev 还记着
# 老地址 fc000000/fc100000/fc200000。于是 probe 去写门铃写到一个已经不存在的
# 地址上，超时 -110，日志里还能看到 AMD-Vi 的 IO_PAGE_FAULT：
#     ntb_hw_epf 0000:03:00.0: Failed to configure doorbell
#     ntb_hw_epf 0000:03:00.0: probe with driver ntb_hw_epf failed with error -110
# 只有让内核重新读一遍 config space、把 BAR 重新写下去，端点才会重新认这些地址。
# 2026-11-25 实测：NPU 重启后单靠 bind/重装协议栈都救不回来，remove+rescan 一跑
# 就 `qp 0: Link Up`；而且它**不会**复位 NPU（操作前后 NPU uptime 连续）。
reenumerate() {
	local bdf=${PCI_DEV##*/}
	log "重枚举 $bdf（remove + rescan）"
	(
		echo 1 >"/sys/bus/pci/devices/$bdf/remove" 2>/dev/null
		sleep 2
		echo 1 >/sys/bus/pci/rescan 2>/dev/null
	) >/dev/null 2>&1 &
}

ntb_iface() {
	local n dev drv
	for n in /sys/class/net/*; do
		dev=${n##*/}
		[ "$dev" = lo ] && continue
		drv=$(ethtool -i "$dev" 2>/dev/null | sed -n 's/^driver: //p')
		[ "$drv" = ntb_netdev ] && { echo "$dev"; return 0; }
	done
	return 1
}

# plain rescan 放后台：这个写操作在极端情况下会阻塞几分钟（见文件头），不能让它
# 把监视线程一起卡住。
plain_rescan() {
	( echo 1 > /sys/bus/pci/rescan ) >/dev/null 2>&1 &
}

reload_stack() {
	log "重装本机 NTB 协议栈"
	modprobe -r ntb_netdev 2>/dev/null || true
	modprobe -r ntb_transport 2>/dev/null || true
	modprobe -r ntb_hw_epf 2>/dev/null || true
	sleep 1
	WAIT=10 /usr/local/sbin/xgs-ntb-up.sh >>"$WATCH_LOG" 2>&1 || true
}

retrain_link() {
	local port= cur off on tmp bus sec
	tmp=${PCI_DEV##*/}
	bus=$(printf '%d' "0x$(echo "$tmp" | cut -d: -f2)") || return 1
	for p in /sys/bus/pci/devices/*; do
		[ -r "$p/secondary_bus_number" ] || continue
		sec=$(cat "$p/secondary_bus_number" 2>/dev/null)
		[ "$sec" = "$bus" ] && { port=$p; break; }
	done
	[ -n "$port" ] || { log "找不到根端口"; return 1; }
	cur=$(setpci -s "${port##*/}" CAP_EXP+10.w 2>/dev/null) || return 1
	[ -n "$cur" ] || return 1
	off=$(printf '%04x' $(( 0x$cur | 0x10 )))
	on=$(printf '%04x' $(( 0x$cur & 0xffef )))
	log "重训链路 ${port##*/}（$cur -> $off -> $on）"
	setpci -s "${port##*/}" CAP_EXP+10.w="$off" 2>/dev/null || return 1
	sleep 2
	setpci -s "${port##*/}" CAP_EXP+10.w="$on" 2>/dev/null || return 1
}

bad_since=0
stack_at=0
rescan_at=0
plumb_at=0
bind_at=0
reenum_at=0
retrain_at=0
peer_bad_since=0
no_dev=0
state=init
PCI_DEV=

log "开始盯着 vNTB（每 ${INTERVAL}s 一拍，对端 ${PEER:-none}）"

while :; do
	now=$(date +%s)

	ifc=$(ntb_iface) || ifc=
	car=
	[ -n "$ifc" ] && car=$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)

	if [ -n "$ifc" ] && [ "$car" = 1 ]; then
		new=up
		if [ -n "$PEER" ]; then
			if ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; then
				peer_bad_since=0
				bad_since=0
			else
				if [ "$peer_bad_since" = 0 ]; then
					peer_bad_since=$now
					# 从第一次 ping 不通就开始计时，别等到判定 peer-down 才起算
					bad_since=$now
					log "$ifc carrier=1 但对端 $PEER 不通"
				fi
				# carrier 还挂着但对面已经不答了 = 链路其实已经不可用。
				# 留 PING_CD 秒纯粹是别把偶尔丢一个包当成故障。
				if [ $((now - peer_bad_since)) -ge "$PING_CD" ]; then
					new=peer-down
				fi
			fi
		fi
	elif [ -n "$ifc" ]; then
		new=no-carrier
	elif find_epf; then
		if [ -n "$(pci_driver "$PCI_DEV")" ]; then
			new=no-netdev
		else
			new=unbound
		fi
	else
		new=no-device
	fi

	# peer_bad_since 只在"carrier 还挂着"时才有意义；接口没了/换状态就清掉，
	# 否则下次链路回来时会把老时间戳当成"已经不通很久了"。
	case "$new" in
	up | peer-down) ;;
	*) peer_bad_since=0 ;;
	esac

	if [ "$new" = up ]; then
		no_dev=0
	else
		[ "$bad_since" = 0 ] && bad_since=$now

		case "$new" in
		peer-down)
			# carrier=1 但对端没了：绝大多数情况是对端重启过 —— 它那边的 BAR
			# 分配被硬件清掉了，我们这边还记着老地址。重装协议栈救不回来
			# （2026-11-25 实测连试两次都是 -110），只有重枚举能救。
			no_dev=0
			if find_epf && [ $((now - reenum_at)) -ge "$REENUM_CD" ]; then
				reenum_at=$now
				bad_since=$now
				reenumerate
			elif [ $((now - stack_at)) -ge "$STACK_CD" ]; then
				stack_at=$now
				bad_since=$now
				reload_stack
			fi
			;;
		no-carrier|no-netdev)
			no_dev=0
			if [ $((now - bad_since)) -ge "$STACK_AFTER" ] &&
				[ $((now - stack_at)) -ge "$STACK_CD" ]; then
				# 补管道补不回来（对端只重启了 vNTB、硬件没复位时 QP 会停在
				# 老状态），整条重装。这一档**不**重置 bad_since 之外的东西，
				# 因为它自己就是把时钟重置掉。
				stack_at=$now
				bad_since=$now
				log "$new 已经 ${STACK_AFTER}s，重装本机 NTB 协议栈"
				reload_stack
			elif [ $((now - plumb_at)) -ge "$PLUMB_CD" ]; then
				plumb_at=$now
				log "$new（${PCI_DEV##*/}${ifc:+ $ifc}），重跑 xgs-ntb-up.sh"
				WAIT=10 /usr/local/sbin/xgs-ntb-up.sh >>"$WATCH_LOG" 2>&1 || true
			fi
			;;
		unbound)
			no_dev=0
			if [ $((now - bad_since)) -ge "$REENUM_AFTER" ] &&
				[ $((now - reenum_at)) -ge "$REENUM_CD" ]; then
				reenum_at=$now
				bad_since=$now
				reenumerate
			elif [ $((now - bind_at)) -ge "$BIND_CD" ]; then
				bind_at=$now
				log "端点在（${PCI_DEV##*/}）但没有驱动，后台重试 ntb_hw_epf bind"
				pci_bind_bg || log "上一轮 bind 还没回来，等它"
			fi
			;;
		no-device)
			no_dev=$((no_dev + 1))
			if [ $((now - rescan_at)) -ge "$RESCAN_CD" ]; then
				rescan_at=$now
				log "总线上没有端点，plain rescan"
				plain_rescan
				sleep 2
				find_epf && new=no-netdev
			fi
			if [ "$no_dev" -ge "$RETRAIN_AFTER" ] &&
				[ $((now - retrain_at)) -ge "$RETRAIN_CD" ]; then
				retrain_at=$now
				no_dev=0
				retrain_link || log "重训失败"
			fi
			;;
		esac
	fi

	if [ "$new" != "$state" ]; then
		log "状态 $state -> $new"
		state=$new
	fi
	sleep "$INTERVAL"
done