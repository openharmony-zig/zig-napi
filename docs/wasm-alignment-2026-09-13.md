# WASM 对齐与验收（2026-09-13）

结论：本轮确认的问题已修复并完成独立验收；修改整合在原分支。已验证能力、实现差异和未覆盖的运行环境分别列出，不作“与 napi-rs 全部 API 完全等价”或“零隐藏风险”的承诺。

## 范围与基线

本轮在 `fix/audit-2026-09-12` 上继续，起点为 `23f993f`。实施由 Claude CLI 启动的 `deepseek-flash[1M]` 执行；主会话负责派单、代码审查、独立复现、验收和整合提交。不是“升级版本号即完成”，也不把 Zig API 与 Rust/Tokio 的全部能力等同。

核对并锁定：

| 上游 | 本轮基线 |
| --- | --- |
| napi-rs 源码 | `39bd1205e480a453a2da2601a760bde5a71ed016` |
| emnapi 源码 | `ca282f418104016b17b9661af98c9791301f819c` |
| `emnapi` / `@emnapi/core` / `@emnapi/runtime` | `2.0.0-alpha.5`，**预发布版**，不是 2.0 正式版 |
| `@napi-rs/wasm-runtime` | `1.2.4` |
| `@napi-rs/cli` | `3.9.1` |

依据：[napi-rs 加载器源码](https://github.com/napi-rs/napi-rs/blob/39bd1205e480a453a2da2601a760bde5a71ed016/cli/src/api/templates/load-wasi-template.ts)、[napi-rs WASI 构建](https://github.com/napi-rs/napi-rs/blob/39bd1205e480a453a2da2601a760bde5a71ed016/crates/build/src/wasi.rs)、[emnapi 发布记录](https://github.com/toyobayashi/emnapi/releases)。

## 审计中确认的问题与处理

| 问题 | 修复与验收重点 |
| --- | --- |
| emnapi 2 已移除旧 basic-MT 静态库；原构建直接失败 | 改用真实可用的 basic archive 与 emnapi 2 JS async-work/TSFN plugins，校验安装包版本与库路径 |
| threaded/non-threaded 目标混淆 | 两种 CLI 目标均映射 Zig `wasm32-wasi`；通过 atomics 区分共享内存、worker 导出与产物名，严格指定测试 flavor，不允许静默回退 |
| emnapi 2 环境 ABI 变化 | 对接 `emnapi_create_env` / `emnapi_delete_env`，去除不兼容旧内部实现 |
| Worker 栈切换使用普通 Zig 函数会被函数尾声恢复 | 无栈帧汇编切换独立栈和 TLS；真实 Worker 曾复现 stack-canary 崩溃，修复后重测；未关闭 canary |
| 多个 Worker 同时发送事件会破坏 C 堆 | 独立复现 `c.malloc.Header.get → unreachable`；为共享 C 分配入口提供一致的同步，覆盖混合 JS/Zig 分配和并发事件 |
| 极大长度和对齐会导致两套 BrkAllocator 的 size-class 越界 | C 分配入口和 `safePageAllocator` 均增加边界防护；失败返回 null/false，保留旧 realloc/resize/remap 的有效数据；修正 calloc 溢出、POSIX 对齐及 valloc 页对齐 |
| 满队列忙等消耗额外 CPU | 线程版采用有界 `memory.atomic.wait32` 与 notify；取消、关闭和释放槽位均可唤醒 |
| 无线程版超过 256 条事件会阻塞自身事件循环 | 同一宿主线程内有序派发，避免等待一个无法运行的消费者 |
| 销毁前取消不等于 Promise 已结算 | pre-teardown barrier 在 JS 仍可用时结算；区分运行中、已结束未派发、已有待派发事件 |
| 提前结算越过事件导致异常身份丢失 | completion 保持在事件 FIFO 后；对象与原始值的 thrown identity 均有回归 |
| barrier 遍历与 retire 竞争、pending 发布后计数 | 加锁认领 intrusive registry 节点，保持所有权；发布前计数，失败和投递精确平衡 |
| 提前删除宿主仍持有的 async-work | barrier 结算不夺走宿主 completion 的释放责任 |
| dispose 直接终止池被误判成 Worker 崩溃 | 正常池关闭前移除该池的 exit 崩溃检测；运行期间的真实错误仍会报告 |
| 固定大链接内存、非法内存配置、无界 pool 输入 | 取消强制大链接下限；保留可配置 initial/max/stack 与早期错误提示，校验池参数和增长空间 |
| 模板、现有构建、打包路径不一致 | 统一生成源；实际 npm pack 后安装、脚手架、原生/WASM 构建及加载验证 |
| 优化模式验收参数未传入 Node test 子进程，可能实际测试默认产物 | CI 改用 `ZIG_NAPI_WASM_ARTIFACT_ROOT`；独立重新验证真实 ReleaseSafe / ReleaseFast 产物 |

审查沿用了工程规范中的所有权、释放时序及内存边界检查；没有修改上游 Rust 代码。

## 能力边界

| 能力 | 线程版 | 非线程版 |
| --- | --- | --- |
| CLI 目标 | `wasm32-wasip1-threads` | `wasm32-wasip1` |
| 产物 / Node 加载器 | `*.wasm32-wasi.wasm` / `*.wasi.cjs` | `*.wasm32-wasip1.wasm` / `*.wasip1.cjs` |
| Node 与真实浏览器 | 验收覆盖 | 验收覆盖 |
| 多 Worker 真并行 | emnapi JS Worker pool | 无；任务运行在宿主线程 |
| 浏览器跨域隔离 | SharedArrayBuffer 要求 COOP/COEP | 不需要；验收特意不设置隔离头 |
| deferred 预编译 Module、独立实例、dispose 后重建 | 不适用 | 验收覆盖 |
| 字符串、TypedArray、异常、Promise、事件、取消 | 验收覆盖 | 验收覆盖；取消不能靠定时器抢占正在同步运行的宿主任务 |

非线程任务在 `checkCancelled` / `emit` 等检查点响应取消；回调内取消和开始前取消可验证。任务已经完成后的迟到取消不改写既有结果。不能把这一限制写成“支持与真实线程等价的定时抢占”。

与 napi-rs 的重要实现差异：napi-rs 线程目标使用 C pthread/libuv 组合；当前 Zig 0.16 WASI libc 的 pthread 路径不能直接支持该组合，因此本项目采用 basic archive + emnapi 2 JS plugins。对齐的是这里列出的宿主可观察能力与生命周期契约，不是 Rust/Tokio 或所有 Node-API 的逐项等价认证。

## 独立验收记录

环境：macOS arm64，Zig 0.16，Node 22.23.2；额外 Node 16.20.2 / 24.12.0；Chrome 152.0.7977.83。

| 验收项 | 结果 |
| --- | --- |
| WASM 线程版完整 AVA | 211 通过，39 原生专属跳过 |
| WASM 非线程版完整 AVA | 211 通过，39 原生专属跳过 |
| ABI + 并发／C 与 Zig 分配边界（Debug） | 7 通过、0 跳过，包含独立小堆 OOM 产物 |
| ABI + 分配器回归（ReleaseSafe / ReleaseFast） | 每种 6 通过；各 1 个 OOM 专项因未传小堆路径跳过，该项已在 Debug 独立覆盖 |
| 原生 Debug / ReleaseSafe / ReleaseFast | 每种 239 原生 JS + 11 WASI 生命周期回归 + 30 Zig 单测通过 |
| Node 16 / Node 24 原生 | 各 239 通过；没有将它们计为 WASM 运行支持声明 |
| 真实 Chrome | 两种 flavor 各 1,024 条事件、异常身份、取消、dispose；线程版另测 32 并发任务，非线程版无 COOP/COEP 并验证回调内取消 |
| deferred 浏览器入口 | 预编译 Module、拒绝 bytes、独立实例、单例复用、dispose 后重新实例化通过 |
| 加载器单测 + 真实离线打包构建 | 29 + 2 通过；含 128 页初始内存 + 1 MiB 自定义栈的真实构建与加载 |
| 全新 npm pack → 安装 → 脚手架 → 构建加载 | 1 通过，覆盖原生与 WASM，不依赖工作区包路径凑巧可用 |
| OHOS | 6 示例 × 3 架构 = 18 目标编译通过；未运行真机 |
| 工程检查 | lint、Zig 格式检查、网站构建、锁文件离线 frozen install 通过；生成后格式化与模板一致性已核对 |

生命周期用例是按适用能力验证：线程版的“生产者已返回但 completion 尚未进入宿主回调”窗口，在非线程同步执行路径不存在；后者由 inline 事件与回调内取消用例覆盖。没有把不适用的执行窗口说成实际运行过。

另对原来立即崩溃的 **4 Worker × 每个 512 条事件** 场景独立连续运行 12 轮，均保持顺序、`pending=0` 并自然退出。进程退出验收不使用强制 `process.exit()` 掩盖残留句柄；异常卡死由父进程期限判失败。

### 性能与内存样本

同一脚本，3,000 条事件，首个监听器阻塞 JS 300 ms，独立子进程运行。下表是本机样本，不是跨平台吞吐保证，也没有设置容易波动的耗时断言。

| 指标 | 修改前 | 最终样本 |
| --- | --- | --- |
| 线程版 CPU（user + system） | 652.01 ms | 411.80 ms，约下降 36.8% |
| 线程版墙钟耗时 | 343.42 ms | 366.99 ms；不宣称延迟下降 |
| 队列高水位 / 上限 | 原有上限 256 | 实测 256 / 256 |
| 线程版逻辑 live bytes：峰值 → GC 后 | 10,140 → 0 | 10,203 → 0 |
| 线程版进程 RSS（结束时） | 155,435,008 B | 158,728,192 B；不宣称 RSS 下降 |

最终样本中，不传监听器只产生 4 次框架分配、队列高水位为 0；非线程监听器路径不积压线程事件队列。线性内存容量与 RSS 单独记录，不能用“逻辑释放到 0”推断 WASM 内存已经缩小或全部归还操作系统。

可复验入口：

```sh
pnpm install --frozen-lockfile
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1-threads
node packages/zig-napi/bin/zig-napi.js build --cwd node-test --target wasm32-wasip1
NAPI_RS_FORCE_WASI=error ZIG_NAPI_WASI_FLAVOR=wasi pnpm --filter zig-napi-node-test run test:run
NAPI_RS_FORCE_WASI=error ZIG_NAPI_WASI_FLAVOR=wasip1 pnpm --filter zig-napi-node-test run test:run
node --test node-test/wasm/abi.test.cjs node-test/wasm/concurrency.test.cjs
node --test packages/zig-napi/test/wasi-loader.test.cjs packages/zig-napi/test/wasi-pack.test.cjs
node node-test/wasm/queue-benchmark.cjs --flavor=both --json
pnpm run test:cli-pack
```

浏览器验收：安装 `playwright-core` 与 Chrome，设置 `PLAYWRIGHT_MODULE` 为该模块入口路径后运行 `node node-test/wasm/browser.mjs`。OOM 专项需要单独的小 maximum 构建，通过 `ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT` 指向；CI 已提供完整构建步骤。

## 不应过度推断的事项

- emnapi 2 当前选用的是 alpha 版本，已锁版本；未来升级仍需重跑 ABI、并发和销毁验收。
- 默认普通加载器仍使用上游风格的 4000 初始页配置；移除强制链接下限不等于默认进程 RSS 已下降。逻辑 live bytes、WASM 线性内存容量和 RSS 分开统计。
- wasm32 两套分配器的单次请求保护上界约为 **1 GiB − 64 KiB**，还需计入对齐和分配元数据，因此实际有效载荷略小。超限返回分配失败；这不等于总线性内存上限，许多较小分配仍可使用配置允许的总空间。大 realloc 的复制仍可能延长共享 C 分配器临界区，不保证恒定延迟。
- 浏览器验证了 deferred loader 的预编译 Module 与生命周期，但没有运行 workerd 部署。
- 本机验证及 OHOS 18 目标编译不替代 Linux/Windows CI 运行或 ArkVM 真机测试。没有声称这些外部执行环境已经验收。
- 有限回归和压力测试不能证明不存在任何隐藏风险，也不等于所有分配失败位置或无限运行时长都经过验证。
