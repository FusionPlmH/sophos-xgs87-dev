#!/usr/bin/env python3
"""Run npu-uboot.py on the x86 over the x86 console (COM6).

Uploads tools/on-x86/npu-uboot.py to /tmp on the x86 via base64, then runs
it and prints the captured output.  The x86 console helper is x86-console.py.

Example:
    python tools/on-pc/npu-uboot-run.py --cmd 'mmc list' \
        --cmd 'ext4ls mmc 0:3 /boot' --cmd 'ext4ls mmc 0:2 /'
"""
import argparse
import base64
import pathlib
import shlex
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
X86_CONSOLE = HERE / "x86-console.py"
ON_X86 = HERE.parent / "on-x86" / "npu-uboot.py"


def run_x86(port, user, password, cmd, timeout):
    p = subprocess.run(
        [sys.executable, str(X86_CONSOLE), "--port", port, "--user", user,
         "--password", password, "--timeout", str(timeout), cmd],
        capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    return p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM6")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="P@ssw0rd")
    ap.add_argument("--timeout", type=float, default=170.0)
    ap.add_argument("--skip-upload", action="store_true")
    ap.add_argument("--wait", type=float, default=90.0)
    ap.add_argument("--pre", action="append", default=[])
    ap.add_argument("--cmd", action="append", default=[])
    ap.add_argument("--p3", action="store_true")
    ap.add_argument("--login", action="store_true")
    ap.add_argument("--login-user", default="root")
    ap.add_argument("--login-pass", default="openwrt123")
    a = ap.parse_args()

    if not a.skip_upload:
        b64 = base64.b64encode(ON_X86.read_bytes()).decode()
        up = "echo %s | base64 -d > /tmp/npu-uboot.py; chmod +x /tmp/npu-uboot.py; echo UPLOAD_OK" % b64
        if run_x86(a.port, a.user, a.password, up, 60) != 0:
            return 1

    args = ["python3", "/tmp/npu-uboot.py", "--wait", str(a.wait)]
    for c in a.pre:
        args += ["--pre", c]
    for c in a.cmd:
        args += ["--cmd", c]
    if a.p3:
        args.append("--p3")
    if a.login:
        args += ["--login", "--login-user", a.login_user,
                 "--login-pass", a.login_pass]
    remote = "echo %s | sudo -S -p '' %s" % (
        shlex.quote(a.password), shlex.join(args))
    return run_x86(a.port, a.user, a.password, remote, a.timeout)


if __name__ == "__main__":
    sys.exit(main())
