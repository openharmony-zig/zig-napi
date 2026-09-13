# 第二轮隐藏风险修复验收

审计基线：`7343594`；交付分支：`fix/audit-2026-09-12`。本轮在上一轮修复后继续检查生命周期、失败回滚和内存放大；[上一轮报告](audit-repair-2026-09-12.md)中的验证结果是历史快照，不能替代本轮验证。

验收日期：2026-09-13。

按要求由 Claude CLI 的三个 `deepseek-flash[1M]` 子 agent 分别修复异步、转换资源、Worker/Class；主 agent 审查实现、独立复现、补测并统一集成。未推送、创建 PR 或发布。

## 审计范围与复现证据

| ID | 级别 | 基线问题与证据 | 修复要求 |
| --- | --- | --- | --- |
| H01 | P1 | Worker 环境终止时 TSFN finalizer 提前释放仍被任务/控制线程访问的 Operation；带与不带 AbortSignal 均可复现 SIGSEGV | 生产者、dispatcher、排队记录独立保活；关闭后只清理 native；Future 与 runtime 完整回收 |
| H02 | P1 | `Worker(...data=inputSlice).AsyncQueue()` 浅拷贝转换参数，导出调用结束释放参数后后台读取崩溃 | 默认捕获 native 数据；JS 句柄与其他资源使用显式借用契约 |
| H03 | P1 | 非空 Args 的 `TSFN.Err` 传入 native null 参数句柄，JS 引擎崩溃 | 错误分支只传 error；其他参数槽必须是有效 JS 值 |
| H04 | P1 | 参数前缀创建 Reference/TSFN，后续转换失败时未撤销；100 个 WeakRef 目标全部存活，TSFN 子进程不能自然退出 | 转换事务覆盖自动、手动和 Class 入口；成功调用转移资源，失败回滚；重入事务互不撤销 |
| H05 | P1 | 自定义 `removeEventListener` 抛异常，破坏 Promise 结算，任务永久 pending | 隔离清理异常，保留已有任务/监听器失败，保证可观察的终态 |
| H06 | P1 | fire-and-forget Worker.Queue 不清理 Owned 返回值；100 次遗留 1,900 字节 | 结果清理由统一销毁路径执行，包含无 Promise、取消与失败 |
| H07 | P2 | TSFN 错误文本排队后被调用方覆盖，收到 `xxxxxxxxxxxx` | 独立快照 message/code；投递失败和 null-env 排空均回收 |
| H08 | P2 | 监听器抛出 number/string/null/undefined 被吞掉，任务错误地成功 | 用可引用的 holder 保留原始抛出值，精确拒绝 |
| H09 | P2 | 省略可选 listener 报 InvalidArg，显式 undefined/null 正常 | 规范化缺省参数与嵌套 optional |
| H10 | P2 | 3,000 个小事件产生 9,008 次分配；JS 阻塞 300ms 时 RSS 增长约 148MiB；无监听器仍分配与投递 | 无监听器快速路径、事件数量上限与背压、记录复用；验证关闭/取消可唤醒阻塞生产者 |
| H11 | P2 | 只保存长度的类仍保活全部 init/factory 输入；100 × 64KiB 输入额外保留约 6.26MiB | 保留安全的默认借用策略；增加显式 transient 参数契约，支持及时释放 |
| H12 | P1 | 验收追加发现：实例方法把 receiver 计入已转换参数数；第一个 string 参数类型错误时清理未初始化 slice，隔离进程 SIGSEGV | 清理计数仅包含已成功转换的 JS 参数；补充首参错误及零参工厂重入回归 |
| H13 | P1 | WASM 并发 Worker 与 JS/GC 共用 Zig 的无锁 BrkAllocator；表现为 Promise finalizer 越界、存活块被覆盖，修复前压力复现 5/6 次失败 | 一个模块级原子锁保护共享页分配器；默认、Registry 与计数分配器采用同一安全入口；恢复 WASM GC 用例并验证并发块内容 |

H10 基线逻辑载荷约 198KB，RSS 放大主要来自小对象逐次 page_allocator 分配和无限积压，不能把整个峰值称为永久泄漏。实例回收后 H11 也能释放，属于不必要的长期保活。

## 验收状态

H01–H13 已落地修复。集成验收没有直接采用子 agent 的通过声明：退回补修了 finalizer 与排队记录的引用、跨原子变量的关闭竞争、队列计数丢更新/丢唤醒、控制线程启动失败时的等待死锁，以及每个废弃任务创建一个清理线程的问题。最终队列上限为每个任务 256 个事件，清理任务使用预分配的队列节点和每模块最多 4 个 helper 线程。

资源事务覆盖普通导出、手动 `NapiValue.As` / `Napi.from_napi_value*`、类 init/factory/method/字段构造/setter；零参工厂也隔离外层转换事务。成功进入业务体后资源归业务所有；失败的调用不能撤销另一个重入调用已经提交的资源。

WASM 的 GC 崩溃没有通过增加 skip 关闭问题。已确认根因是共享 allocator 的并发访问，未给 Promise 添加地址黑名单或掩盖错误；同步修复默认分配器、Registry 和测试 backing，并迁移示例的手动分配。另将 basic 示例 `TestFactory.format` 的堆字符串改为 `Owned` 返回，避免被“普通返回值借用”契约漏清理。

### 内存与性能实测

同机 Node 22.23.2/macOS arm64，3,000 个带短字符串的事件，JS 忙等 300ms。命令：`node node-test/audit/hidden-risk-memory.cjs`。RSS 为单次诊断样本，不作为跨机器 CI 阈值。

| 指标 | 基线 | 修复后 |
| --- | ---: | ---: |
| 无监听器：全程 native 分配次数 | 9,008 | 8 |
| 有监听器：阻塞窗口内 native 逻辑存活字节 | 198,378 | 18,298 |
| 有监听器：阻塞窗口内分配次数 | 9,008 | 520 |
| 有监听器：全程分配次数 | 9,008 | 3,265 |
| 有监听器：阻塞窗口 RSS 增量 | 147.91MiB | 2.97MiB |
| 有监听器：完整耗时（含 300ms 阻塞） | 316.4ms | 327.5ms |
| 有监听器：实际交付事件数 | 3,000 | 3,000 |

有界队列牺牲部分生产者提前运行的空间，样本中完整耗时略增；没有据此宣称吞吐加速。记录复用消除了记录本身的逐次分配，字符串载荷仍需复制，不能宣称“每个事件零分配”。两组运行在 GC 后均保留 920 字节的初始化 runtime/env 基线；预热后的重复任务和环境关闭回归要求回到各自基线。

类策略对照（同样只保存长度，100 × 64KiB 输入）：默认 retained 保留 6,560,800 字节；显式 transient 仅保留 5,600 字节实例数据。释放实例并 GC 后，两者增量均为 0。默认仍保留安全借用行为，优化必须显式声明不借用输入。

### 验证矩阵

最终集成代码的实际执行结果如下；没有把配置中的平台矩阵当作已通过的验证。

| 验收项 | 结果 |
| --- | --- |
| `zig build test --summary all`，Node 22.23.2 Debug | 239 项 JS + 30 项 Zig 通过 |
| 同上，`-Doptimize=ReleaseSafe` | 239 项 JS + 30 项 Zig 通过 |
| 同上，`-Doptimize=ReleaseFast` | 239 项 JS + 30 项 Zig 通过 |
| Node 16.20.2，最终 ReleaseFast addon | 239 项 JS 通过 |
| Node 24.12.0，最终 ReleaseFast addon | 239 项 JS 通过；同步回滚测试在让出事件循环前取样，避免计入其他对象的 GC |
| WASM/emnapi：CLI 构建 `wasm32-wasip1-threads`，强制 WASI 运行 | 200 项通过、39 项显式跳过 |
| WASM 并发分配与 Worker/Promise GC | 2 项专项测试连续 3 轮通过；不再跳过该 GC 路径 |
| OHOS：6 个示例 × arm64/arm32/x64 | 18 个目标编译通过；未运行 ArkVM 真机 |
| CLI 独立 pack/install/create/build/load | 1 项完整流程通过 |
| 网站构建、类 metadata / TypeScript 隐藏配置项 | 通过 |
| `pnpm run lint`、`zig fmt --check`、`git diff --check` | 通过 |

WASM 的 39 项跳过主要是直接使用 native 线程、Node Worker 环境销毁、原生 runtime/IO 和部分原生 GC/WeakRef 计数路径；它们不能由 WASM 的通过数量代替。Linux、Windows、ArkVM 真机及其余 Node 版本的完整运行矩阵未在本机执行，仍是发布门禁。

回归入口：`node-test/audit/__tests__/hidden-risk.spec.js`，以及三个 `*-audit.spec.js` 和对应 Zig fixture。原生测试入口 `src/unit_tests.zig`。临时验收日志在 `/tmp/zig-napi-hidden-repair.wWL814/`；该临时目录不属于交付内容。

## 生命周期契约与边界

- Node 的 TSFN finalizer 不代表 native 生产者已停止，也不保证 null-env 队列已排空。[Node v22.23.2 官方实现](https://github.com/nodejs/node/blob/v22.23.2/src/node_api.cc)中先调用用户 finalizer，再清理余下队列；队列记录不能依赖已经释放的 wrapper 上下文。
- Reference/TSFN 成功转换并交给 native 业务体后，业务体负责释放或转移资源。框架不能通过“函数返回了”推断资源没有交给后台线程。Reference 的原始拷贝、Owned 的多重拥有和无效指针别名不具备自动安全保证。
- Worker 默认捕获是 native 数据所有权策略，不是让 JS 句柄可以在后台任意使用。显式借用资源必须满足线程与存活期要求。类 transient 模式要求业务不保存转换输入的借用指针；需要长期数据应显式克隆。
- WASM 自定义分配器应使用 `napi.safePageAllocator()` 作为页来源，不得在其他路径绕过锁直接调用同一个 `std.heap.page_allocator`。自定义分配器自己的数据结构仍须线程安全；仅锁共享页来源不能代替它的内部同步。native 目标的 safePageAllocator 直接返回原页分配器，不增加锁。
- 取消仍是协作式。关闭环境中已不存在可观察的 JS Promise；此时要求 native 安全回收，不要求调用已销毁的 JS 环境来结算。
- 有界事件数量不等于任意载荷大小均有固定字节上限；应用仍须限制单事件大小和同时运行的任务数量。
- 本机 macOS 测试及 OHOS 编译不能替代 ArkVM 真机、Linux 和 Windows 的运行验证，也不等于全量 N-API 失败注入或无限时长压力测试。
- 清理线程创建遇到系统资源耗尽时，节点保持可达并等待后续成功启动的 helper，不会丢失或提前释放任务；如果始终没有后续提交且线程始终无法启动，清理会延迟到进程退出。长时间不退出的用户任务也可能占满 4 个 helper；队列并不保证固定清理时延。
- WASM 队列满时使用原子检查/轮询；它有内存上限，但不等于没有 CPU 开销。需要真机与目标宿主测量负载、取消和长时间并发行为。
