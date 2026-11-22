# 16 — EIP197 硬件加密引擎：激活成功，但结论是「不用」

> 这是整个项目里唯一一次**真正意义上的逆向/源码考古**：从 Marvell 的 4.14 BSP
> 和 MUSDK 源码反推，找出主线驱动在 CN9130 上失败的真正原因，打补丁、验证正确性、
> 并做完整的性能对比。

---

## 16.1 最后的真相：`UENG_INIT_STATUS` 根本不会置位

之前的结论是「IFPP 微码起不来」：

```
crypto-safexcel f2800000.crypto: FW(1) for PE 0 failed to start
```

对比两条线索后，发现判断错了：

| 来源 | 写固件后的动作 |
|---|---|
| **Marvell 4.14 BSP**（`linux-4.14.76-armada-18.12`） | 复位 → 开程序存储 → 写固件 → 关程序存储 → **清 SW_RESET，就结束了**＜br＞**不轮询任何状态位** |
| **主线 6.12** | 复位 → 写固件 → 写 `UENG_START_OFFSET\|UENG_DEBUG_RESET` → **`poll_fw_ready()` 等 `UENG_INIT_STATUS`** |

**这颗 CN9130 的 EIP197 永远不会把 `UENG_INIT_STATUS` 置位**，微码其实早就跑起来了。
主线把"等不到状态位"当成失败，于是整个 probe 被放弃。

补丁只有一行（见 [modules/safexcel-eip197/enable-fw-start.patch](../modules/safexcel-eip197/enable-fw-start.patch)）：

```diff
 static bool poll_fw_ready(struct safexcel_crypto_priv *priv, int fpp)
 {
+	/* patched: this SoC never raises UENG_INIT_STATUS */
+	return true;
 	int pe, pollcnt;
```

---

## 16.2 激活结果

打完补丁重建 `crypto_safexcel.ko` 后：

```
crypto-safexcel f2800000.crypto: EIP197:241(0,1,4,4)-HIA:230(2,6,6),PE:13b/332(alg:7ffdf000)/143/0/0
crypto-safexcel f2800000.crypto: TRC init: 15360d,80a (48r,256h)
→ /proc/crypto 注册了 96 个 safexcel 算法，selftest 全部 passed
```

前置条件（缺一不可）：

1. **固件**：用原厂 rootfs 里的 `ifpp.bin`(12272B) / `ipue.bin`(4080B)
2. **时钟**：`clkfix.ko` 打开 `CP110_GATE_EIP197`（safexcel 驱动自己不申请时钟）
3. **跳过状态位轮询**：上面的补丁

### 正确性验证

用自写的 AF_ALG 工具（[tools/afalg_bench.c](../tools/afalg_bench.c)），同一个程序、
同一 key/IV/明文，分别在硬件和软件后端跑：

```
hardware: 43c31fc8bfee68067bcf04081c17d37009994592e5b4325c21955e52464d892a
software: 43c31fc8bfee68067bcf04081c17d37009994592e5b4325c21955e52464d892a
=> MATCH ✅
```

**EIP197 算出来的密文和 ARMv8 CE 完全一致 —— 硬件是真的在工作**，不是表面成功。

---

## 16.3 性能对比（AES-256-CBC，16 KiB 缓冲，AF_ALG）

为排除 OpenSSL 引擎的干扰，用自写工具直接打 AF_ALG；并用
`SAFEXCEL_CRA_PRIORITY 400 > aes-ce 300` 强制选中硬件实现。

| 并发 | **EIP197** | **ARMv8 CE** | 结论 |
|---|---|---|---|
| 1 | 1.61 Gbps | **3.24 Gbps** | 软件快 2× |
| 2 | 3.09 Gbps | **6.32 Gbps** | 软件快 2× |
| 4 | 4.16 Gbps | **12.41 Gbps** | 软件快 3× |
| 8 | 4.53 Gbps（**饱和**） | — | 硬件到顶 |

**软件在任何并发下都更快，而且随核数线性扩展；EIP197 在 4.5 Gbps 附近饱和。**

原因：AF_ALG 是**同步单发**接口，每个请求都要 syscall + 描述符 + DMA + 中断。
EIP197 只有在**成批异步**投递时才有优势——原厂正是这么做的（MUSDK SAM 用户态环形队列），
所以 Marvell 才不用内核 crypto API。

---

## 16.4 结论：回退，保持软件加密

| 判定 | 依据 |
|---|---|
| 能否激活 | ✅ 能，且计算正确 |
| 是否值得用 | ❌ **不值得**：比 ARMv8 CE 慢 2–3× |
| 对本机是否有意义 | ❌ 更没必要：整机 L3 转发天花板 3.5–4.8 Gbps，而软件加密单核就有 3.24 Gbps、4 并发 12.4 Gbps，**加密永远不会是瓶颈** |

因此：

- 恢复原厂 `crypto_safexcel.ko`（probe 失败，不注册算法 → 系统加密走 ARMv8 CE）
- 补丁、基准工具留在仓库里，作为**可复现的实验记录**
- 若将来真要压榨硬件加密，正确路径是复刻原厂的 **MUSDK SAM**（用户态批量 ring），
  而不是修内核驱动

---

## 16.5 这次逆向用到的线索

| 线索 | 作用 |
|---|---|
| `MarvellEmbeddedProcessors/linux-marvell` `linux-4.14.76-armada-18.12` 分支的 `safexcel.c` | **决定性**：发现 4.14 根本不轮询状态位 |
| `MarvellEmbeddedProcessors/musdk-marvell` `modules/sam/mv_sam_uio.c` | 证实"内核 safexcel 可能没开时钟"，且 SAM 依赖 safexcel probe 成功 |
| `src/drivers/sam/safexcel/Firmware/` 只有 `api` | 证实 MUSDK 自己**不**加载固件，必须靠内核驱动 |
| 原厂 eMMC dump 的 `/usr/lib/firmware/inside-secure/eip197b/` | 提供与硬件配套的固件（与 GitHub 版本不同） |
| 主线驱动的 `eip197b_mrvl_data` 未设 `fw_little_endian` | 排除字节序假设（与 4.14 一致，都是大端） |
