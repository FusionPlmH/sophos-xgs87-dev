# tools/ — 按"在哪台机器上运行"分目录

> 最容易搞混的就是这一块：编 NPU 的模块不代表脚本在 NPU 上跑。
> 下面每一个脚本都标了**运行位置**和**产物给谁**。

```
tools/build/    在 PC 的 WSL 上跑（需要 x86_64 主机 + 交叉工具链）
tools/on-npu/   在 NPU 上跑
tools/on-x86/   在 x86 上跑
tools/on-pc/    在 Windows PC 上跑（串口工具）
```

## `build/` — 在 PC 上构建，产物分别给两台机器

| 脚本 | 运行位置 | 产物 → 装到 |
|---|---|---|
| `build-npu-net.sh` | PC / WSL | `mv88e6xxx.ko`（含两个 TCAM 修复）+ `mvpp2.ko`（`AGGR_TXQ_SIZE=512`）→ **NPU** |
| `build-npu-vntb.sh` | PC / WSL（`chroot /srv/npu`，qemu user-mode） | 6 个 vNTB 模块 → **NPU** |
| `build-x86-vntb.sh` | PC / WSL（amd64 原生） | `ntb*.ko` 四个 → **x86** |

```sh
# NPU 的网络模块（交叉编译，走完整源码树，不用 qemu）
./tools/build/build-npu-net.sh

# NPU 的 vNTB 模块（在 NPU 的 arm64 rootfs 里编，qemu user-mode）
./tools/build/build-npu-vntb.sh

# x86 的 NTB 栈
./tools/build/build-x86-vntb.sh
```

三条铁律（踩过的坑都在 [docs/20](../docs/20-lan-over-vntb.md) §20.9）：

- **不能用 `linux-headers` 包交叉编译**：包里的 `scripts/`（`fixdep`/`modpost`）是 aarch64 二进制，
  在 x86 主机上跑不了 → 必须用完整源码树 + `CROSS_COMPILE`。
- **`vermagic` 必须带 `+deb13-arm64`**：写进 `.config` 的 `CONFIG_LOCALVERSION`，
  不要用 `localversion` 文件（会和它叠加成两份）。
- **模块不压缩**：`xz -9` 的 64 MiB 字典超出内核解码器上限，会静默 `status 6` 不加载。

## `on-npu/` — 在 NPU 上跑

| 文件 | 说明 |
|---|---|
| `afalg_bench.c` | 走 AF_ALG 直接量内核 crypto：`check` 做已知向量校验，`bench <sec>` 测吞吐。用来比 EIP197（`safexcel-*`）和 ARMv8 crypto（`cbc-aes-ce`） |

```sh
# NPU 上
gcc -O2 -o afalg_bench afalg_bench.c
./afalg_bench check
./afalg_bench bench 5
```

## `on-x86/` — 在 x86 上跑

| 文件 | 说明 |
|---|---|
| `npu-console.sh` | 通过 x86 的 `/dev/ttyS2` 操作 NPU 控制台。`login` 分支自动登录；`'cmd'` 分支发一条命令并抓回显 |

```sh
# x86 上
sudo ./npu-console.sh login
sudo ./npu-console.sh 'uname -r'
WAIT=8 sudo ./npu-console.sh 'dmesg | tail'
```

⚠️ host 侧波特率必须是 **57600**（这颗 16550 的分频基准是标称值的两倍，软件 57600 = 线上 115200）。
⚠️ `/dev/ttyS2` **同一时刻只能有一个读者**，两个 `cat` 会把字节流切成乱码。

## `on-pc/` — 在 Windows PC 上跑（COM 口工具）

| 文件 | 说明 |
|---|---|
| `x86-console.py` | 走前面板 micro-USB / RJ45 串口（COM5 或 COM6，115200）跟 **x86** 控制台交互，UTF-8 安全 |
| `serial-capture.py` | 把 COM 口原始字节流录进日志文件（硬编了 COM5 与输出路径，改完再用） |
| `grub-unstick.py` | x86 卡在 GRUB 命令行时，发 ESC / Ctrl-C / `normal` 把它推回正常启动 |
| `netconsole-listen.py` | 收 UDP 6666 的 `netconsole` 日志（硬编了输出路径） |
| `redact.py` | 发布前把序列号、真实 MAC、UUID 抹掉 |

> `on-pc/` 里几个脚本的输出路径是写死的（`logs\...`），
> 换机器要改。

## 不在这个目录里的构建配方

- [modules/build.sh](../modules/build.sh) —— NPU 的 `clkfix.ko` / `spi-orion.ko`，
  在 **arm64 的 Debian 13 rootfs**（NPU 本机，或 PC 上的 `/srv/npu` chroot）里 `make`。
