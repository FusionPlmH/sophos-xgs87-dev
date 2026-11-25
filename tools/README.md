# tools/ — 按"在哪台机器上运行"分目录

> 最容易搞混的就是这一块：编 NPU 的模块不代表脚本在 NPU 上跑。
> 下面每一个脚本都标了**运行位置**和**产物给谁**。

```
tools/build/    在 PC 的 WSL 上跑（需要 x86_64 主机 + 交叉工具链）
tools/on-x86/   在 x86 上跑
tools/on-pc/    在 Windows PC 上跑（串口工具）
```

## `build/` — 在 PC 上构建，产物分别给两台机器

| 脚本 | 运行位置 | 产物 → 装到 |
|---|---|---|
| `build-npu-net.sh` | PC / WSL | 可选的 `mv88e6xxx.ko`（含两个 TCAM 修复）+ `mvpp2.ko`（`AGGR_TXQ_SIZE=512`）→ **NPU**；镜像默认用发行版原版 |
| `build-dtb.sh` | PC / WSL / CI | `out/cn9130-sophos-xgs87w-sfp10g.dtb` —— 先 `cpp` 预处理再 `dtc`；首次会稀疏 clone 一份 Linux 源码取 Marvell 的 `.dtsi` |
| `build-npu-vntb.sh` | PC / WSL（`chroot /srv/npu`，qemu user-mode） | 6 个 vNTB 模块 → **NPU** |
| `build-x86-vntb.sh` | PC / WSL（amd64 原生） | `ntb*.ko` 四个 → **x86** |
| `build-npu-kernel.sh` | PC / WSL（交叉编译） | **NPU 的 `Image`**。只有"必须编进 vmlinux"的选项才需要它；`PSTORE_CONSOLE` 那次用过，但 `ramoops` 已被证伪（每次复位都重跑 DDR scrub，[docs/11](../docs/11-operations.md) §11.1），现在排障走 netconsole，别再为它重编内核 |
| `build-rescue.sh` | PC / WSL / CI | `xgs87-rescue.tar.zst`（`Image.gz` + `initramfs.gz` + DTB，约 15 MB）→ **NPU 的 U-Boot 内存**，见 [docs/05](../docs/05-storage.md) §5.4 |
| `build-rescue-kernel.sh` | PC / WSL（交叉编译） | 裁剪版急救内核；产物交给 `build-rescue.sh --kernel`。**默认不用**：现在的急救包直接用 Debian 的 `Image`，这一条只在想再压 10 MB 时才需要 |

```sh
# NPU 的网络模块（交叉编译，走完整源码树，不用 qemu）
./tools/build/build-npu-net.sh

# NPU 的 vNTB 模块（在 NPU 的 arm64 rootfs 里编，qemu user-mode）
./tools/build/build-npu-vntb.sh

# x86 的 NTB 栈
./tools/build/build-x86-vntb.sh

# NPU 的整颗内核（只有编进 vmlinux 的选项才需要；约 12 分钟）
CONFIG_EXTRA="CONFIG_PSTORE_CONSOLE=y CONFIG_PSTORE_PMSG=y" ./tools/build/build-npu-kernel.sh
```

### 重编内核后模块要不要跟着重编？

看 `Module.symvers`：

```sh
md5sum $OBJ/Module.symvers $NPU_ROOT/usr/src/linux-headers-$KVER/Module.symvers
```

两边一致 ⇒ 导出符号的 CRC 没变 ⇒ **现有模块不用重编**（这次加 `CONFIG_PSTORE_*` 就是这种情况）。
不一致 ⇒ 所有自编模块都得重来，否则 `insmod` 报 `disagrees about version of symbol`。

三条铁律（踩过的坑都在 [docs/15](../docs/15-modules-and-kernel.md) §15.5）：

- **不能用 `linux-headers` 包交叉编译**：包里的 `scripts/`（`fixdep`/`modpost`）是 aarch64 二进制，
  在 x86 主机上跑不了 → 必须用完整源码树 + `CROSS_COMPILE`。
- **`vermagic` 必须带 `+deb13-arm64`**：写进 `.config` 的 `CONFIG_LOCALVERSION`，
  不要用 `localversion` 文件（会和它叠加成两份）。
- **别手工 `xz -9`**：它的 64 MiB 字典超出内核 xz 解码器上限，`insmod` 会静默 `decompression
  failed with status 6`。`make modules_install` 自己产出的 `.ko.xz` 是好的 —— 镜像里
  `/lib/modules/*/updates/` 那四个 `ntb_*.ko.xz` 就是（Debian 内核 `CONFIG_MODULE_COMPRESS_XZ=y`
  + `MODULE_DECOMPRESS=y`，实测能加载）。中招的只有"手工压一遍放进去"。

## `on-x86/` — 在 x86 上跑

| 文件 | 说明 |
|---|---|
| `npu-console.sh` | 通过 x86 的 `/dev/ttyS2` 操作 NPU 控制台（默认 115200）。`login` 分支自动登录；`'cmd'` 分支发一条命令并抓回显 |
| `npu-uboot.py` | `npu-console.sh` 的 Python 版：termios 直连 `/dev/ttyS2`，启动窗口内空格打断 `bootdelay`，识别 `=>`/`U-Boot 20`/`Hit any key`，然后 `--cmd`/`--pre`/`--p3`/`--login` 下发；`--log` 落盘（默认 `/tmp/npu-uboot.log`） |
| `uboot-probe.sh` | 早期 shell 探针：在启动窗口狂发空格并录全程，用来判断 U-Boot 是否出提示符 |
| `mcp2210-nor.py` | **救砖工具**：x86 上经 `/dev/hidraw0`（MCP2210）读/写 NPU 的 4 MiB SPI NOR。先整片双遍 dump + manifest，`env-write` 只写 64 KiB env，`mtd0-restore`（需 `--unsafe-mtd0 --commit`）只重写 U-Boot/TF-A 区里有差异的 64 KiB 块；`flash-write --offset 0x3F0000` 是 env 坏到连备份都解析不了时的出口（只认显式区间，自己守 64 KiB 对齐 + 不许越 mtd0）。自动 hold/release NPU（GP0/3/5，AMDA0200 为 `0xFFD7`/`0xFFFF`），GP0 作 CS。详见 [docs/14](../docs/14-rescue.md) |
| `test_mcp2210_nor.py` | 无硬件的 MCP2210 + MX25L3205D 模拟测试：`python -m unittest discover -s tools/on-x86 -p 'test_*.py' -v` |
| `mrvl-uart.py` | **BootROM UART 恢复通道**（不经过 TF-A/BL31/CP MSS，是 NPU 固件跑不完时唯一能在 RAM 里执行代码的手段）：狂发 `BB 11 22 33 44 55 66 77` 等 BootROM 回 `0x15`，再 XMODEM-128 送载荷、`EOT` 收 `0x06`。`sudo python3 mrvl-uart.py --file /tmp/hb.bin` |
| `mk-hb.py` | 生成 20 字节"心跳桩"（`movz/movk → x0=0xF0512000`，死循环写一个字符），用来验证上面那条通道通不通：`python3 mk-hb.py --out /tmp/hb.bin [--at 0x48] [--char Z]`。**看得到字符 ⇒ 通道可用** |
| `x86-linkoff-test.sh` | 判决实验：把 x86 到 NPU 的 PCIe 链路**彻底关掉**（Link Disable，不是 remove/rescan），干看 45 秒，判断 x86 是否在干扰 NPU 启动。带 `trap` 保证恢复链路。`sudo ./x86-linkoff-test.sh` |

```sh
# x86 上
sudo ./npu-console.sh login
sudo ./npu-console.sh 'uname -r'
WAIT=8 sudo ./npu-console.sh 'dmesg | tail'
```

⚠️ host 侧波特率：当前 Debian 内核用 **115200** 就是线上 115200；只有老 `image/` 产出的系统
那颗 16550 报 `base_baud 115200`、晶振两倍，才要 host **57600**（见 [docs/10](../docs/10-console.md) §10.3）。
`npu-console.sh` / `npu-uboot.py` 的默认值都是 115200，老系统用 `BAUD=57600`。
⚠️ `/dev/ttyS2` **同一时刻只能有一个读者**，两个 `cat` 会把字节流切成乱码。

## `on-pc/` — 在 Windows PC 上跑（COM 口工具）

| 文件 | 说明 |
|---|---|
| `x86-console.py` | 走前面板 micro-USB / RJ45 串口（COM5 或 COM6，115200）跟 **x86** 控制台交互，UTF-8 安全；`--script FILE` 把文件里每一行当一条命令依次发过去（用来把文件分块推到 x86） |
| `npu-console.py` | NPU 的 CH340（`--port COM7`，`--baud 115200`）直连控制台；`--interrupt` 空格停 autoboot，`--send CMD` 依次下发 |
| `npu-cmd.py` | 命令从 x86 的 `ttyS2` 发、回显从 PC 的 CH340（COM7，只收）读；不需要先登录 x86 shell |
| `npu-listen.py` | 只读监听 NPU 控制台，给 BootROM/TF-A 的冷启动打时间戳（默认 60 s，`--raw` 全量打印） |
| `npu-uboot-run.py` | 把 `on-x86/npu-uboot.py` base64 传到 x86 的 `/tmp` 再执行，全程经 COM6 转发、回显并落盘——PC 侧一条命令驱动 NPU 控制台 |
| `serial-capture.py` | 把 COM 口原始字节流录进日志文件（`--port`，默认 `logs/x86-console.log`，`--out` 可改） |
| `grub-unstick.py` | x86 卡在 GRUB 命令行时，发 ESC / Ctrl-C / `normal` 把它推回正常启动 |
| `netconsole-listen.py` | 收 UDP 6666 的 `netconsole` 日志（`--bind` / `--out`，默认 `logs/npu-netcon.log`） |
| `redact.py` | 发布前把序列号、真实 MAC、EUI-64 链路本地地址、UUID 抹掉 |
| `module-whitelist.sh` | 从真机 `lsmod` 求依赖闭包，算出"这台机器真正用到的内核模块"和它们的体积（裁 `/lib/modules` 前的第一步）。`SSH_KEY=~/.ssh/id_xgs_ed25519 sh module-whitelist.sh root@host` |

> 这些脚本不再写死本机路径：日志默认落在当前目录的 `logs/` 下。
> 真机专属的值（序列号、用户名……）不要写进仓库，`redact.py --list <文件>` 从仓库外读。

### 为什么需要 `module-whitelist.sh`

`/lib/modules` 是瘦身之后最大的一块：NPU 上 **75 MiB / 4359 个 .ko**，而实测这台机器
实际加载的模块求完依赖闭包只有 **110 个、2 MiB**。真按白名单裁，NPU 的 rootfs 能再小
约 70 MiB（409 → ~340 MiB）。没直接做进构建，是因为少数路径（USB 启动、少见文件系统）
的模块不在 `lsmod` 里，得先在真机 + 维护 U 盘上各验一遍。

## `check-docs.py` — 文档自检（改文档后必须跑）

```sh
python3 tools/check-docs.py
```

两件事：所有 `§NN.x` 章节引用必须能在某份文档里找到对应标题；所有相对 Markdown 链接必须指向
真实文件。失败会逐条打印 `MISSING` / `BROKEN LINK` 并以非零码退出。文档改名或拆分后最容易
留下的就是这两类残骸。

发布前跑一遍 [tools/check-hygiene.sh](check-hygiene.sh)：它只认“设计里就该出现的”MAC
和示例网段，发现别的就报错——防止真实 MAC / 内网地址 / Windows 用户路径又混进来。
