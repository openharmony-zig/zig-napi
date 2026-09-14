# 工程记忆

本文件保存转换、所有权、异步和 WASM 的长期约束，不是问题待办或修复验收报告。修改相关契约时同步更新；具体用法见 [API 文档](../website/src/content/api/overview.md)，行为以源码和正式测试为准。

本轮整理由 `fix/audit-2026-09-12` 的 `7e0f999` 提炼。已移除的分析、修复方案和验证记录仍可通过 `git ls-tree 7e0f999 docs/` 与 `git show 7e0f999:docs/<文件名>` 查阅，不在工作树重复归档。

## 转换与资源事务

- 转换失败必须进入 `!T` 控制流；先检查 N-API 状态，再读取输出。已有 JS pending exception 应原样传播，不能用零值、空串或新的错误掩盖失败。缺省参数规范化为 JS `undefined`。
- 整数转换先检查有限值、整数性、范围和符号，再做窄化；输入、输出及快慢路径保持一致。JS Number 不保证精确表达所有 64 位整数，精确值使用 BigInt。
- 数组、tuple、struct 等递归转换只清理成功初始化的前缀；实例 receiver 不计入已转换 JS 参数数。失败不能返回带未初始化 payload 的占位值。
- 转换事务覆盖普通导出、手动转换，以及类 init、factory、method、字段构造和 setter。失败先撤销新建的 JS 资源，再释放 native 参数；零参工厂也要隔离重入事务。
- 成功进入业务体后，Reference、ObjectRef、FunctionRef、TSFN 等资源的释放或转移由业务负责。外层失败不得撤销重入调用已提交的资源；不能以“业务函数已返回”推断资源未交给后台任务。

实现入口：[转换](../src/napi/util/napi.zig)、[调用帧与清理](../src/napi/util/helper.zig)、[函数包装](../src/napi/value/function.zig)。

## 所有权与二进制借用

- 普通导出的 JS 参数转换产生的 native 副本由调用作用域释放，仅在调用期间有效。需要跨调用或跨线程保存时显式深拷贝；裸 `napi_value`、Env 和其他 JS 句柄不能因此变成后台线程可操作的数据。
- 普通 native 返回值是借用，框架不释放字面量、输入别名或子 slice。新分配的返回值必须使用 `napi.Owned(T)` 并携带来源 allocator；嵌套 Owned 也在输出转换成功或失败后清理。
- `Owned.init` 不能接管调用作用域仍会释放的参数。`Owned.take()` 和结构体复制不会使原值失效；只能有一个释放 owner，其他别名不得再次 `deinit`。Reference 的复制同样不产生独立所有权。
- Async 和 Worker 默认捕获可支持的 native 数据副本；显式借用必须保证数据、资源与线程的存活期。Async descriptor 单次消费；需要同步处理捕获分配失败时使用 `tryFrom`。`.from` 通常通过错误描述符拒绝 Promise，但该描述符自身分配失败仍可能 panic。
- Buffer、ArrayBuffer、TypedArray、DataView 的指针和长度不能跨 JS 重入无条件缓存。回调可能 detach、transfer 或 resize backing store；后续访问重新查询并验证，长度运算检查溢出。Reference 只能防 GC，不能防 detach；合法零长度也不等于 detached。
- `Buffer.from` 转移输入所有权；不支持外部 Buffer 时复制回退仍会消费原输入，并可能同步调用 finalizer。不能假定释放一定延迟到 GC；需要保留原输入时使用复制接口。

实现入口：[Owned 契约](../src/napi/ownership.zig)、[Worker 捕获](../src/napi/wrapper/worker.zig)、[Buffer](../src/napi/wrapper/buffer.zig)、[二进制 API](../website/src/content/api/binary-data.md)。

## 类与环境隔离

- 构造器和 JS 引用按 `napi_env` 管理，不能跨环境共用。unwrap 或 callback data 必须先验证指针来源，再解引用；读取未知指针上的 magic/tag 本身并不安全。
- 实例、静态方法与工厂使用不同入口；工厂直接包装已构造的完整 native 值，不再次运行用户 init。`ClassWithoutInit` 不开放普通 JS 构造。
- init/factory 参数默认 `.retained`，转换输入保活到实例销毁，允许字段借用其数据。业务 `deinit` 不得再次释放这些保活输入；自己分配的字段按显式 owner 清理。
- 不保存输入借用的类可声明 `pub const arg_ownership: napi.ArgOwnership = .transient;`，在调用结束释放参数。不能将其指针存入字段、Owned 或全局；长期数据必须深拷贝。
- 字段构造失败只回滚已初始化部分；setter 先完成新值转换，再替换并清理原 owned 字段，转换失败保留原值。

实现入口：[类包装](../src/napi/wrapper/class.zig)、[类与所有权 API](../website/src/content/api/classes-ownership.md)。

## 异步、取消与销毁

- 借用的 `PromiseValue` 与可结算 Promise 能力分开；结算状态共享，拒绝重复结算或操作不属于自己的 deferred。环境存活时，任务错误、结果转换失败和取消都必须有可观察终态。
- Promise 结算不代表生产者退出、宿主 completion 已调用或队列已排空。Operation、排队记录和 runtime 分别保活；不能因为提前 reject 就删除宿主仍持有的 async-work。
- TSFN finalizer 不代表生产者停止，也可能先于 null-env 队列排空。回调先检查空 env，再决定是否访问 wrapper context；空 env 路径只用记录自带的 allocator 清理 native 数据，不调用 JS。
- TSFN 的 `Ok`/`Err` 消费其拥有的 payload，入队失败、队列满或 closing 也要清理。排队错误文本独立快照；error-first 回调失败时只传 error，不能填入 native null 句柄冒充 JS 参数。
- AbortSignal 注册独立监听器，不占用或移除已有 wrap，也不覆盖 `onabort`。释放后保留的回调不能访问已销毁 context；移除监听器抛错不能破坏结算或覆盖原始失败。监听器抛出的对象和原始值（包括 `undefined`）保持身份。
- 取消是协作式，不保证停止任意用户代码。环境已关闭后仅安全回收 native；WASI 主动 dispose 则在 JS 仍可用时通过 teardown barrier 结算，再排空宿主回调。completion 保持在事件 FIFO 后，不能越过事件吞掉监听器异常。
- WASI 清理等待有界；排空超限时保留 context 并允许重试 dispose，不能强行销毁仍被宿主持有的对象。普通加载器 dispose 后为终态；需要独立实例和重新实例化时使用 deferred 入口。

实现入口：[异步状态机](../src/napi/async.zig)、[TSFN](../src/napi/wrapper/thread_safe_function.zig)、[Promise](../src/napi/value/promise.zig)、[AbortSignal](../src/napi/abort_signal.zig)、[加载器](../packages/zig-napi/bin/wasi-templates.cjs)。

## 内存与性能边界

- 长期对象捕获申请资源时的 allocator，并用它释放；临时 thread-local allocator 作用域不能替代跨线程所有权，也不能让实际 allocator 自动线程安全。共享 runtime 按环境和任务引用管理，单个环境退出不能破坏其他环境。
- WASM 自定义 allocator 必须使用 `napi.safePageAllocator()` 作为共享页来源，不绕过模块锁直用同一 `std.heap.page_allocator`；自定义元数据仍需自身同步。native 的 safePageAllocator 不增加该锁。
- Zig 页分配与 emnapi C 分配有各自的边界和并发保护，修改时两条路径一起检查。wasm32 当前单次请求保护上界约为 1 GiB − 64 KiB，还需计入元数据和对齐；不是总线性内存上限。超限 realloc/resize/remap 失败须保留旧数据，大 realloc 复制也可能延长锁持有时间。
- 当前每任务最多积压 256 个事件；无监听器走快速路径。线程版使用原子 wait/notify，取消、关闭及释放槽位唤醒等待者；非线程版在宿主线程有序 inline 派发，不能等待自身事件循环来消费队列。
- 事件数量上限不等于固定字节上限，仍需限制单事件载荷和并发任务数；复用队列记录也不等于载荷零分配。
- native 延迟清理每模块最多 4 个 helper 线程，清理队列本身无容量上限。任务长期不退出可能占满 helper；线程启动失败会保留节点，等待后续提交重试，不保证固定回收时延。
- 分开统计逻辑存活字节、WASM 线性内存容量、RSS、CPU 和墙钟耗时。逻辑释放不等于线性内存缩小或 RSS 下降；降低积压、降低 CPU 也不等于吞吐或延迟一定改善。

实现入口：[页分配器](../src/napi/util/allocator.zig)、[C 分配器](../src/sys/emnapi_alloc.zig)、[异步队列与清理](../src/napi/async.zig)。

## WASM 与分发契约

| CLI 目标 | Zig 目标特征 | 产物 / Node 加载器 |
| --- | --- | --- |
| `wasm32-wasip1-threads` | `wasm32-wasi`，启用 atomics | `*.wasm32-wasi.wasm` / `*.wasi.cjs` |
| `wasm32-wasip1` | `wasm32-wasi`，不启用 atomics | `*.wasm32-wasip1.wasm` / `*.wasip1.cjs` |

- 两种 flavor 分别构建和选择，不能静默回退导致测试错误产物。优化模式同样传入实际产物目录，不能只更改构建参数。
- 仓库当前锁定的 emnapi / core / runtime 为 `2.0.0-alpha.5`，是预发布版，不是 2.0 正式版或“上游最新”的持续声明；版本以 [锁文件](../pnpm-lock.yaml) 为准。升级需联动 ABI、静态库、JS plugins 与加载器生命周期。
- 线程版采用 basic archive + emnapi JS async-work/TSFN plugins，不是 napi-rs 的 pthread/libuv 组合；对齐的是宿主可观察能力，不是 Rust/Tokio 或所有 Node-API 的逐项等价。
- 浏览器线程版需要 SharedArrayBuffer 与 COOP/COEP。非线程版在宿主线程执行任务，定时器不能抢占正在同步执行的代码；取消依赖开始前状态、回调和协作检查点。
- 非线程 deferred 入口接受预编译 `WebAssembly.Module`，不接受原始 bytes；独立实例各自管理生命周期，单例复用与 dispose 后重建遵循该入口契约，不能套用普通加载器行为。
- initial/max/stack 配置需满足模块实际最小内存、导入内存类型及分配器增长空间约束。取消固定的大链接下限，不代表普通加载器默认初始页数或进程 RSS 已下降。
- CLI 发布包必须包含独立安装所需的 Zig 源码与构建定义，默认脚手架不能依赖仓库目录布局。加载器从统一模板生成；分发路径覆盖真实 pack → 安装 → 创建 → 构建 → 加载，以及带空格路径，避免 shell 字符串拼接。

实现入口：[WASI 构建](../src/build/napi-build.zig)、[CLI](../packages/zig-napi/bin/zig-napi.js)、[生成模板](../packages/zig-napi/bin/wasi-templates.cjs)、[Node/WASM 构建 API](../website/src/content/api/build-node.md)。

## 维护入口与证据边界

- 回归按能力归类，保留在 [Node 正式测试](../node-test/napi/__tests__) 的 contracts、conversion、classes、async、resource-lifecycle 等套件、[WASM 测试](../node-test/wasm)、[CLI 测试](../packages/zig-napi/test) 和 [Zig 单测](../src/unit_tests.zig)，不另建按审计轮次命名的测试副本。
- 修改契约时同步调用方、示例、声明和测试；公开泛型要实际实例化，不能只凭模块导入或空构建判定可用。崩溃探针放独立进程，内存检查用计数基线，自然退出不能用强制退出掩盖残留句柄。
- 编译通过不等于目标宿主运行通过；OHOS 编译不替代 ArkVM 真机，native Node 版本验证不替代 WASM，浏览器运行不替代 workerd 部署。CI 配置、跳过用例、有限压力测试都不能充当尚未执行的平台验收或“零隐藏风险”证明。
