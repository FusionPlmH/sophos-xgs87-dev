#!/bin/sh
# 生成"这台机器真正用到的内核模块"清单 —— 裁剪 /lib/modules 前用。
#
#   SSH_KEY=~/.ssh/id_xgs_ed25519 ./module-whitelist.sh root@host
#
# 做法：在目标机上拿 lsmod，再对每个模块跑 `modprobe --show-depends` 求
# 依赖闭包（闭包很重要：lsmod 里有 mv88e6xxx，缺了它依赖的 dsa_core 之类，
# 清单看着还行，实际一 modprobe 就炸）。最后补上"平时不加载、但启动 /
# U 盘 / 维护路径一定会用"的模块。
#
# 输出是模块名（不带 .ko），一行一个；同时打印清单内外的体积对比。
# 清单里找不到 .ko 的名字说明那个模块是编进内核的（=y），不需要文件，正常。
set -eu

TARGET=${1:?usage: [SSH_KEY=keyfile] $0 [user@]host}

SSH() {
	ssh ${SSH_KEY:+-i "$SSH_KEY"} \
		-o BatchMode=yes -o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=8 "$TARGET" "$@"
}

# 平时不加载、但启动/维护路径会用到的（USB 启动、ESP、eMMC、串口控制台）。
EXTRA="usb_storage uas vfat fat nls_cp437 nls_iso8859-1 nls_ascii
sdhci sdhci_pci cqhci mmc_block mmc_core
ahci libahci libata scsi_mod scsi_common
xhci_hcd xhci_pci usbcore usb_common usbhid hid
ext4 jbd2 mbcache crc16
overlay squashfs loop
netconsole configfs"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LIST=$WORK/whitelist

echo "== 在 $TARGET 上求依赖闭包"
SSH 'for m in $(lsmod | awk "NR>1{print \$1}"); do
	modprobe --show-depends "$m" 2>/dev/null
     done | awk "/^insmod/{print \$2}" |
     xargs -r -n1 basename | sed "s/\.ko.*//" | sort -u' </dev/null |
	grep -v '^$' > "$LIST" || true

echo "== 闭包里 $(wc -l < "$LIST") 个模块；补上启动/维护路径需要的"
for m in $EXTRA; do echo "$m" >> "$LIST"; done
sort -u -o "$LIST" "$LIST"
echo "== 合计 $(wc -l < "$LIST") 个"

echo "== 体积对比（在 $TARGET 上按真实 .ko 文件算）"
SSH 'set -eu
k=$(uname -r); d=/lib/modules/$k
total=$(find $d -name "*.ko*" -printf "%s\n" | awk "{s+=\$1} END{print s+0}")
n=$(find $d -name "*.ko*" | wc -l)
keep=0; hit=0; miss=0
while read -r m; do
  [ -n "$m" ] || continue
  f=$(find $d -name "$m.ko*" 2>/dev/null | head -1)
  if [ -n "$f" ]; then keep=$((keep+$(stat -c %s "$f"))); hit=$((hit+1))
  else miss=$((miss+1)); fi
done
echo "  全部: $((total/1024/1024)) MiB / $n 个 .ko"
echo "  清单: $((keep/1024/1024)) MiB（找到 $hit 个 .ko，$miss 个编进了内核）"' < "$LIST"

echo "== 清单"
cat "$LIST"
