#!/bin/bash
# 编一个只含急救用得上的 applet 的静态 arm64 busybox，给 build-rescue.sh 用。
#
#   ./tools/build/build-rescue-busybox.sh                 # 产出 out/busybox-rescue
#   CROSS_COMPILE=aarch64-linux-gnu- ./tools/build/…      # 默认就是这个
#
# 为什么要自己编：Debian 的 busybox-static 有 ~390 个 applet、1.98 MB，而急救
# initramfs 只用得上 52 个。裁完 1.19 MB，initramfs 的 gzip 从 1.03 MB 掉到 0.60 MB。
#
# 两个 busybox kconfig 的坑（都在 board/busybox-rescue.config 头部写过）：
#   * 同一个符号在 .config 里出现两次，第二次被**静默忽略** → 片段必须就地替换，
#     不能 `cat >>`；
#   * 没有 olddefconfig 目标，oldconfig 要 tty → 用 script(1) 套一个伪终端。
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
BBVER=1.38.0
BBSHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2
FRAG=$REPO/board/busybox-rescue.config
OUT=$REPO/out/busybox-rescue
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

# rescue-init 真正会调的命令。少一个，急救系统就会在最要命的时候坏掉。
# （`[` 不单列：脚本里的 `[ ]` 走 ash 内建，不是独立 applet。）
NEEDED="sh ash mount umount mkdir sed dd sync ls cat tr wc cut rm sha256sum \
sleep reboot poweroff halt uname printf echo test grep tail head ip ifconfig \
dmesg ping wget ps free df hexdump expr sort uniq find chmod ln mv cp touch mknod \
basename dirname readlink hostname id kill env"

while [ $# -gt 0 ]; do
	case "$1" in
	--out)    OUT=$2; shift 2 ;;
	--mirror) MIRROR=$2; shift 2 ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 1 ;;
	esac
done
MIRROR=${MIRROR:-https://busybox.net/downloads}

for t in "$CROSS_COMPILE"gcc file python3 script; do
	command -v "$t" >/dev/null 2>&1 || { echo "缺 $t" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TB=$WORK/busybox-$BBVER.tar.bz2

echo "== 1/5 取 busybox $BBVER"
[ -f "$REPO/out/busybox-$BBVER.tar.bz2" ] && TB=$REPO/out/busybox-$BBVER.tar.bz2
if [ ! -f "$TB" ]; then
	curl -fsSL -o "$WORK/busybox-$BBVER.tar.bz2" "$MIRROR/busybox-$BBVER.tar.bz2" ||
		{ echo "下载失败：$MIRROR/busybox-$BBVER.tar.bz2" >&2; exit 1; }
	TB=$WORK/busybox-$BBVER.tar.bz2
fi
got=$(sha256sum "$TB" | cut -d' ' -f1)
[ "$got" = "$BBSHA256" ] || { echo "sha256 不对：$got" >&2; exit 1; }
echo "   $(du -h "$TB" | cut -f1)  sha256 ok"

echo "== 2/5 allnoconfig + 片段就地合入"
tar -xf "$TB" -C "$WORK"
cd "$WORK/busybox-$BBVER"
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" allnoconfig >/dev/null 2>&1
python3 - "$FRAG" .config <<'PY'
import re, sys
frag, cfg = sys.argv[1], sys.argv[2]
F = {}
for ln in open(frag):
    ln = ln.strip()
    m = re.match(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$", ln)
    if m:
        F[m.group(1)] = m.group(2)
        continue
    m = re.match(r"^# CONFIG_([A-Za-z0-9_]+) is not set$", ln)
    if m:
        F[m.group(1)] = None
out, seen = [], set()
for ln in open(cfg).read().splitlines():
    m = re.match(r"^(?:# )?CONFIG_([A-Za-z0-9_]+)(?:=(.*)| is not set)$", ln)
    if m and m.group(1) in F:
        s, v = m.group(1), F[m.group(1)]
        out.append(f"# CONFIG_{s} is not set" if v is None else f"CONFIG_{s}={v}")
        seen.add(s)
    else:
        if m:
            seen.add(m.group(1))
        out.append(ln)
for s, v in F.items():
    if s not in seen:
        out.append(f"# CONFIG_{s} is not set" if v is None else f"CONFIG_{s}={v}")
open(cfg, "w").write("\n".join(out) + "\n")
print(f"   片段 {len(F)} 个符号，其中 {len(F) - len([s for s in F if s in seen])} 个是新增")
PY
# oldconfig 要 tty，而且会把片段没写到的符号逐个问一遍。
# 这里用 pty 起它，**只在真的出现提示符时**才回一个空行取默认值
# （用 `yes "" | script …` 灌空行会无限灌下去，把机器灌死 —— 2026-11-26 试过）。
if ! python3 - "$CROSS_COMPILE" >"$WORK/oldconfig.log" 2>&1 <<'PY'
import os, pty, sys
cc = sys.argv[1]
argv = ["make", "ARCH=arm64", "CROSS_COMPILE=" + cc, "oldconfig"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
buf = b""
tail = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
    tail = (tail + d)[-200:]
    if b"?" in tail or tail.rstrip().endswith(b":"):
        os.write(fd, b"\n")
        tail = b""
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(buf)
sys.exit(os.waitstatus_to_exitcode(st))
PY
then
	echo "oldconfig 失败，日志尾巴：" >&2
	tail -15 "$WORK/oldconfig.log" >&2
	exit 1
fi
# 片段里写的每一个 =y 都必须在最终 .config 里 —— 少一个就是静默失效，
# 编出来的 busybox 就会缺 applet（`$((…))` 那次就是这么没的）。
miss=$(while IFS= read -r l; do grep -qxF "$l" .config || echo "$l"; done < <(grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$FRAG"))
[ -z "$miss" ] || { echo "片段里有行没生效：" >&2; echo "$miss" >&2; exit 1; }

echo "== 3/5 编"
script -qec "make ARCH=arm64 CROSS_COMPILE=$CROSS_COMPILE -j$JOBS" /dev/null </dev/null >"$WORK/build.log" 2>&1 || {
	echo "编译失败，日志尾巴：" >&2; tail -25 "$WORK/build.log" >&2; exit 1; }
file -b busybox | sed 's/^/   /'
grep -q 'aarch64' <<<"$(file -b busybox)" || { echo "不是 aarch64" >&2; exit 1; }
grep -q 'statically linked' <<<"$(file -b busybox)" || { echo "不是静态链接" >&2; exit 1; }

echo "== 4/5 核对 applet"
bad=0
for a in $NEEDED; do
	grep -qF "\"$a\"" include/applet_tables.h || { echo "   缺 applet: $a" >&2; bad=1; }
done
[ "$bad" = 0 ] || { echo "applet 不全，不产出" >&2; exit 1; }
echo "   $(grep -oE '^#define NUM_APPLETS [0-9]+' include/applet_tables.h)"

echo "== 5/5 装到 $OUT"
mkdir -p "$(dirname "$OUT")"
install -m755 busybox "$OUT"
ls -l "$OUT"
echo "   gzip -9: $(gzip -9c "$OUT" | wc -c) B"
if command -v qemu-aarch64-static >/dev/null 2>&1; then
	echo "   --list: $(qemu-aarch64-static "$OUT" --list 2>/dev/null | tr '\n' ' ')"
fi
