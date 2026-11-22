# 11 · 路线图

按"投入产出比"排序。每一步都有明确的完成标志（DoD），做完一步就能用。

## Phase 0 — 已完成的基线（本仓库）

- [x] 摸清硬件（x86 + NPU + 交换机 + 存储）
- [x] 拿到 NPU root shell（ttyS2，空密码）
- [x] 完整备份 NPU rootfs / U-Boot / env / 设备树 / 内核 config
- [x] 交换机端口点亮（U-Boot `mvswitch`），面板口 1G link 验证通过
- [x] NPU eth0 ↔ 交换机 10G 链路 + SSH 打通
- [x] 文档化

**DoD**：本仓库内容完整，能照着复现。

## Phase 1 — 让这台机器"好用"（1–2 天）

- [ ] x86 插 USB 千兆网卡，接面板口 4 → x86 有 1G 独立链路
- [ ] NPU 上 `ser2net` 代理 ttyS0（远端能看 NPU console）
- [ ] x86 上写一个 `npu-supervise` 小服务：
      - 串口抓 NPU boot log
      - 需要时自动 `reboot` + 敲空格进 U-Boot + `sw_init`
      - 暴露一个 HTTP/CLI 接口
- [ ] 把 NPU 的临时网络配置写成持久化（`/etc/network/interfaces`）

**DoD**：拔掉显示器/串口，纯远程也能管理整机；x86 能跑容器。

## Phase 2 — 备份与救砖（1–2 天）

- [ ] MCP2210 工具：从 x86 读/写 NPU SPI NOR（先只读备份，验证 md5）
- [ ] 验证"U-Boot 刷坏后能救回来"的完整流程（可以先在备份镜像上做 CRC 校验）
- [ ] 写 `restore.md`：分步骤的恢复手册

**DoD**：能在不拆机的情况下恢复 NPU 的 U-Boot。

## Phase 3 — OpenWrt on NPU（1–2 周）

- [ ] 确认 88E6193X 在 mainline `mv88e6xxx` 的支持（先试 6393X ID）
- [ ] 写 DTS：DSA 节点（4 口 + SFP + CPU 口）
- [ ] 编译带 `CONFIG_NET_DSA` / `CONFIG_MV88E6XXX` 的 OpenWrt（CN9130 已有官方目标）
- [ ] 装到 p1，`bootcmd` 切到 `bootcmd_emmc1`
- [ ] 验证：4 口 + SFP 都能收发，VLAN、bridge、DHCP、NAT
- [ ] LED（PCA9555）跑起来

**DoD**：从 p1 起 OpenWrt，4 个口能跑满 1G，SFP 能插模块。

## Phase 4 — x86 ↔ NPU 高速链路（1 周）

- [ ] 内核打开 `CONFIG_NTB` + `CONFIG_NTB_EPF` + `CONFIG_NTB_NETDEV`
- [ ] DT：`pcie@f2600000` → `snps,dw-pcie-ep`，`addr_space` 256 MB，去掉 `dma-coherent`
- [ ] 三个补丁：1 MiB BAR 对齐 / 去 dma-coherent / MSI 优先
- [ ] `transport_mtu=2048`，HZ=1000
- [ ] 实测 iperf3（目标 ≥600 Mbps 双向）

**DoD**：`ntb0` 在两端都 up，x86 能通过 NPU 上网。

## Phase 5 — 上层玩法（持续）

- [ ] 方案一落地：x86 跑 Docker 服务栈
- [ ] 端口镜像 + IDS（可选）
- [ ] A/B 升级 + 自动回滚
- [ ] 性能/功耗长期观测

## 风险与回滚

| 风险 | 缓解 |
|---|---|
| 刷坏 U-Boot | Phase 2 先做好 MCP2210 救援 |
| 刷坏 OpenWrt | 原厂 p2/p3 保留，`bootcmd_emmc3` 一键回退 |
| 改 DT 起不来 | 串口常备，U-Boot 里 `setenv bootcmd` 立即切回 |
| 交换机配乱 | 断电重启，重新跑 `sw_init` |

## 待办速查（GitHub Issues 建议）

1. `hardware: confirm SFP port speed capability`
2. `switch: verify 88E6193X DSA support`
3. `x86: MCP2210 SPI-NOR tool`
4. `npu: persistent network config`
5. `link: NTB bring-up`
6. `leds: PCA9555 mapping`
