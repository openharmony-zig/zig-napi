# zig-napi 实现审计与完整修复方案

审计日期：2026-09-12。代码基线：`f71e6b7`。本轮未修改实现、既有测试或依赖；仅新增本报告，验证工程位于 `/tmp/zig-napi-audit.ZevIGo`。

## 结论与验证边界

当前实现存在可由 JS 输入触发的进程崩溃、错误释放、内存泄漏、跨环境句柄误用和 Promise 悬挂。建议先完成下述高优先级修复，再将当前 API 作为稳定接口对外承诺。现有转换重构文档的 `!T` 改造方向正确，但不足以覆盖所有权、类、异步终止和独立安装 CLI 等问题。

本次检查了转换层、值与资源包装、类、异步、AbortSignal、分配器、构建/CLI 的关键路径以及测试入口。不是对每条 sys 声明、TypeScript 生成器所有分支及每个平台 ABI 的逐行认证。

- 环境：macOS arm64、Zig 0.16.0、Node v22.23.2、pnpm 10.24.0。
- `zig build --summary all`：通过，但仅执行 `install`，不能据此证明泛型 API 已编译。
- `pnpm run test:node-matrix`：当前本机 Node 环境下 **82 个测试通过**；不是执行了 CI 的全部平台/Node 版本矩阵。
- 在独立子进程执行异常输入探针，崩溃不会中断整个审计；临时 addon 直接依赖当前仓库源码。
- 内存探针复用了仓库的原子计数分配器，统计实际未释放字节，未将 RSS 变化当成泄漏证据。
- 未在本机执行 OHOS/ArkVM、Windows、Linux、WASI、ReleaseFast 和完整 GC/并发压力矩阵；这部分列为修复后的验收项。

优先级：P1 表示应优先修复的崩溃、资源或关键功能错误；P2 表示泛型支持、工具链或验证完整性问题。下列“静态”结论不声称已完成相应场景的动态复现。

## 问题清单

| ID | 优先级 | 问题 | 证据 |
| --- | --- | --- | --- |
| F01 | P1 | 转换忽略 N-API 状态，异常后继续读取输出 | 崩溃及错误结果复现 |
| F02 | P1 | 数值窄化、符号转换和 u64 输出可 panic | 崩溃复现 |
| F03 | P1 | 递归转换失败及字符串枚举泄漏 | 分配器计数复现 |
| F04 | P1 | 缺少明确所有权，同步泄漏、异步错误释放 | 泄漏及崩溃复现 |
| F05 | P1 | 类构造器引用跨 napi_env 共用 | Worker 崩溃复现 |
| F06 | P1 | 静态方法和工厂构造语义错误 | 错误结果复现 |
| F07 | P1 | 类构造失败与 setter 缺少资源回收 | 分配器计数复现 |
| F08 | P1 | AbortSignal 破坏已有 native wrap 和 onabort | 崩溃及回调丢失复现 |
| F09 | P1 | 异步转换失败、Worker 取消未结束 Promise | 超时复现及源码确认 |
| F10 | P1 | TSFN 缺少环境关闭时的安全清理分支 | 静态代码＋官方契约 |
| F11 | P1 | Promise 混淆借用值和可结算 deferred | 两种崩溃复现 |
| F12 | P1 | 二进制包装缓存失效后的地址与长度 | detach 后仍读旧值复现 |
| F13 | P2 | 宣称支持的泛型组合实际无法编译 | 三种编译失败复现 |
| F14 | P1 | 分配器和异步 runtime 生命周期未充分隔离 | 静态代码确认，并发后果待压测 |
| F15 | P2 | CLI 新项目默认依赖仓库目录布局 | 静态包边界确认 |
| F16 | P2 | 默认构建及测试覆盖不足以发现以上问题 | 构建输出和现有测试确认 |

### F01：失败状态没有成为控制流的一部分

位置：[object.zig](../src/napi/value/object.zig#L39)、[string.zig](../src/napi/value/string.zig#L62)、[function.zig](../src/napi/value/function.zig#L225)、[napi.zig](../src/napi/util/napi.zig#L514)。

`Object.from_napi_value` 忽略属性读取状态，随后使用尚未初始化的 `napi_value`。字符串读取失败后长度仍为 0，返回空串且不设置错误。`Function.Call` 只对 union 返回值检查 `last_error`，普通数值转换失败会返回默认值。自动转换对多个包装类型直接调用 `from_raw`，没有验证声明的类型。

现有 addon 上的复现：

```js
const a = require('./node-test/napi/__tests__/binding');
a.roundtripStr(123);          // 返回 ""
a.roundtripStr();             // 返回 ""
a.call0(() => 'oops');        // 返回 0
a.indexmapPassthrough(123);   // 声明为 napi.Object，实际返回 123
a.translatePoint({ get x() { throw new Error('getter boom'); }, y: 2 }, 1, 2);
// 最后一项在独立进程触发 SIGSEGV
```

修复：统一 `from_napi_value*` 为可失败接口；每次 N-API 调用先检查状态，再使用输出；所有类型走一致的校验，包括普通参数、包装类型、可选值和回调结果。`Object.Get/GetNamed`、`Array.Get`、字符串复制等接口也必须可失败。已有 JS pending exception 应原样传播，不再次创建错误覆盖它。输出转换、模块初始化与属性写入也纳入状态检查，不能只修输入层。

验收：getter/Proxy 抛错保持原异常对象；非法参数产生 TypeError 且 native 业务函数调用次数为 0；回调返回错误类型必须返回 Zig error/JS exception；正常调用随后仍可成功。

### F02：数值范围检查缺失，快慢路径不一致

位置：[napi.zig](../src/napi/util/napi.zig#L255)、[number.zig](../src/napi/value/number.zig#L19)、[array.zig](../src/napi/value/array.zig#L111)。

读取 i32/u32/i64 后直接 `@intCast` 到目标类型；u64 快速输出却先转成 i64。TypedArray 转换也直接使用 `@intCast`/`@intFromFloat`。这些操作不能代替对外输入校验。

复现：现有 `validateEnum(256)` 的 u8 enum tag 转换触发 SIGABRT；临时 addon 的 `fn(u64) u64` 接收 `-1`、返回 `maxInt(u64)` 均触发 SIGABRT。后者发生在输出快速路径。

修复：建立共享、可失败的数字转换器，快慢路径使用同一规则。推荐严格模式拒绝非有限值、非整数到整数和越界值；如需兼容 Node 的 i32/u32 截断规则，提供显式转换策略并测试。enum 先用足够宽的数值验证，再查枚举成员。u64 转 JS Number 时不要窄化到 i64；精确 64 位整数使用 BigInt 接口，并明确 Number 的安全整数边界。

验收：覆盖每种宽度的 min/max/min−1/max+1、负数到无符号、NaN、Infinity、小数、2^53 边界和 TypedArray 跨类型转换；Debug/ReleaseSafe/ReleaseFast 的对外结果一致。

### F03：递归失败没有回滚，枚举临时字符串没有释放

位置：[array.zig](../src/napi/value/array.zig#L57)、[object.zig](../src/napi/value/object.zig#L39)、[napi.zig](../src/napi/util/napi.zig#L105)。

数组、tuple、struct 转换不跟踪已成功初始化的元素；外层发现 `last_error` 后，当前失败参数不会放入清理列表，其内部已申请资源也没有释放。`enumFromString` 分配字符串后，无论匹配是否成功都不释放。

100 次调用的计数结果：

| 探针 | 未释放字节增量 |
| --- | ---: |
| `{ text: 'abc', count: 'bad' }` 转 struct | 300 |
| 两元素 struct 数组，第二个 count 非法 | 5400 |
| 合法字符串枚举 `'A'` | 100 |

修复：成功转换一个字段后才增加初始化计数，失败时 `errdefer` 只清理已初始化部分；容器自身也回收。匹配枚举使用临时缓冲并 `defer free`。union 转换失败不能返回含 `undefined` payload 的假值；任何候选尝试都须拥有自己的回滚边界。若继续“首个匹配分支”语义，应明确同形状分支的规则，不无条件重新执行 getter。

验收：成功和失败均重复运行至少 10,000 次，计数分配器回到基线；覆盖嵌套数组、tuple、optional、union 和分配失败点。

### F04：同步与异步缺少统一的所有权契约

位置：[function.zig](../src/napi/value/function.zig#L79)、[async.zig](../src/napi/async.zig#L369)、[async.zig](../src/napi/async.zig#L849)、[napi.zig](../src/napi/util/napi.zig#L219)。

- 同步返回值转换后没有 owned return 清理路径；100 次返回新分配的 19 字节字符串，增加 1900 字节。
- 只要返回 Async，就关闭所有参数的清理，而 descriptor 只销毁它捕获的 `Input`；未捕获的三字节参数调用 100 次泄漏 300 字节。
- Async 完成后无条件递归释放 input/result 的 slice；返回字面量 `"literal"` 触发 SIGBUS。`Async(Result(i32))` 返回含字面量 message 的 `.err` 也触发 SIGBUS。
- `DeinitState` 只有 128 项，且以地址和长度猜测所有权，不能正确表达超过容量的别名、子 slice 或静态存储。这部分为静态风险，不能靠扩大常量解决。

修复：引入显式的 owned/borrowed 值、携带 allocator 的所有权 token 和一次性 move。普通借用返回值仅复制为 JS 值；新分配返回值经 `Owned(T)` 一类接口在转换后释放。Async 只接管显式移入的资源；未移入参数由当前调用作用域清理。异步捕获的临时借用数据必须克隆或禁止。错误消息也区分借用常量和动态所有权。不能简单地给所有同步返回值加 `defer free`，那会把字面量、输入别名和 JS 管理内存一并释放。

验收：字面量、分配结果、输入原样返回、输入子 slice、多个别名、超过 128 项、失败结果、未捕获参数和 schedule 失败均只有明确 owner 释放一次。

### F05：类构造器引用跨环境污染

位置：[class.zig](../src/napi/wrapper/class.zig#L31)、[class.zig](../src/napi/wrapper/class.zig#L234)、[class.zig](../src/napi/wrapper/class.zig#L518)。

每个泛型类只有一个全局 `cached_constructor_ref`。另一个 Worker 加载同一 addon 会覆盖它，随后主线程工厂在自己的 env 中使用 Worker 的构造器引用；没有配套引用清理。

复现：主线程加载临时 addon，Worker 加载并发 ready 消息，再在主线程调用 `Class.make(5)`，触发 SIGABRT，V8 报 `Cannot create a handle without a HandleScope`。

修复：构造器缓存归属于 addon 的每个 env；通过 callback data/模块上下文获取，不使用单一全局引用。注册一次、按环境释放。若使用 instance data，避免覆盖同 env 中其他模块的数据；低 N-API 版本使用可兼容的 callback data 和 cleanup hook。

验收：主线程和至少两个 Worker 同时创建实例/调用工厂，反复启动、退出、终止 Worker，互不干扰且引用全部释放。

### F06：类静态方法和工厂执行路径错误

位置：[class.zig](../src/napi/wrapper/class.zig#L165)、[class.zig](../src/napi/wrapper/class.zig#L234)、[class.zig](../src/napi/wrapper/class.zig#L450)。

静态非工厂方法也无条件 unwrap `this`，但它的 `this` 是构造器，因此直接返回 null。工厂先将字段转换成 JS，再调用普通构造器；这会重复执行自定义 init，且字段顺序不一定等于 init 参数顺序。`ClassWithoutInit` 构造路径只填零，工厂结果被丢弃。

复现：`Class.twice(3)` 返回 `undefined`，预期 6；`NoInit.make(42).value` 返回 0，预期 42。源码还把 `self: T` 判为实例方法后又明确 compileError，与网站支持表不一致。

修复：静态、实例和工厂 callback 分开实现；仅实例方法 unwrap 并验证接收者。工厂直接把已构造的 T 移入带正确 prototype 的实例，用内部受控构造通道避免再次调用用户 init。`ClassWithoutInit` 在运行时阻止普通 JS 构造。明确 `*T` 工厂返回的转移/销毁责任；支持值 receiver 或同步收窄文档/API 声明。

验收：工厂保留所有字段且 init 不重复执行；覆盖字段顺序不同于 init、无 init、多参数 init、静态方法、错误工厂和错误 receiver。

### F07：类字段替换和构造失败泄漏

位置：[class.zig](../src/napi/wrapper/class.zig#L141)、[class.zig](../src/napi/wrapper/class.zig#L168)、[class.zig](../src/napi/wrapper/class.zig#L343)。

构造中途失败只销毁 InstanceData 外壳；已转换参数/字段未释放。setter 成功后直接覆盖原值，没有释放原字段。自定义 init/工厂也缺少明确的输入转移契约，不能一概补 defer。

复现：100 次 `new TextClass('abc', 'bad')` 泄漏 300 字节；同一个实例反复设置三字节字符串 100 次，增加 300 字节。

修复：默认字段构造按初始化计数回滚；setter 先完成新值转换，再原子替换并释放旧 owned 字段，失败时保留旧值。自定义 init 默认借用参数，需要保留时显式 clone/move。由 F04 的所有权机制保证异常与成功路径都不重释放。

验收：构造成功/失败、setter 成功/失败、对象 GC、自定义 deinit 均回到资源基线；业务 deinit 执行恰好一次。

### F08：AbortSignal 对其他状态具有破坏性

位置：[abort_signal.zig](../src/napi/abort_signal.zig#L128)、[abort_signal.zig](../src/napi/abort_signal.zig#L164)。

`ensureStack` 调用 `napi_remove_wrap` 后直接把已有指针当作 AbortRegistrationStack；不验证归属。对其他 wrapped 对象调用 bind 会解释错误内存。`installOnAbort` 覆盖 `signal.onabort`，破坏业务监听器，也可能被后续业务赋值覆盖。wrap 成功后安装回调失败时，现有 errdefer 还可能留下指向已销毁 stack 的 wrap。

复现：传入 `new Class(1)` 调用绑定触发 SIGSEGV；真实 AbortSignal 原有 `onabort` 在绑定并 release 后不再执行，计数为 0。

修复：校验 AbortSignal 能力；使用 `addEventListener('abort', ...)`/`removeEventListener`，监听函数使用独立 native context，并安全管理其生命期，不占用或移除信号对象的其他 wrap。所有注册步骤事务化；release 删除自己的监听和引用。AbortSignal-like 对象不能调用已释放 callback context，失败路径也不能留下悬空 native data。

验收：已有 onabort、多个监听器、同 signal 多任务、重复取消、已取消 signal、错误 wrapped 对象、监听安装失败及 release 后手工调用保留回调都安全。

### F09：异步完成失败和取消会遗留 pending Promise

位置：[async.zig](../src/napi/async.zig#L492)、[async.zig](../src/napi/async.zig#L731)、[worker.zig](../src/napi/wrapper/worker.zig#L117)、[worker.zig](../src/napi/wrapper/worker.zig#L157)。

Async 将结果转换错误 `catch null`，销毁 operation 后不 resolve/reject。controller 的 completion 入队失败被吞掉。Worker 取消后状态为 Cancelled，完成回调没有结算分支；queue/cancel 状态也被忽略。

复现：Async 返回已标记删除的 ObjectRef，转换失败后与 300ms timer 竞争得到 `timeout`；立即取消 Worker 的 Promise 同样得到 `timeout`。源码对应路径不会在更晚时补结算。

修复：显式状态机 `created → queued → running → settling → settled/closed`。结果转换失败映射到 reject；取消在 env 存活时 reject AbortError；queue/create 失败同步返回错误并回收。completion 通道失败要有可执行的清理机制；环境已关闭时只完成 native 清理，不调用 JS。一次任务最多结算一次。

验收：成功、runner 抛错、Result.err、转换失败、排队失败、队列满、执行前取消、执行中取消和环境关闭均有确定终态；不能用忽略错误规避悬挂。

### F10：TSFN 没有处理环境关闭的合法回调形式

位置：[thread_safe_function.zig](../src/napi/wrapper/thread_safe_function.zig#L93)、[async.zig](../src/napi/async.zig#L807)。

普通 TSFN 与 Async dispatcher 均直接用传入 env 创建/调用 JS 值，没有 env 为空时的纯 native 清理分支；Async dispatcher finalizer 为空，正常 completion 之外的 operation 回收不完整。事件与参数只是浅拷贝，动态 payload 的借用/转移责任也不清楚。

Node 官方明确允许关闭时以空 env/JS callback 排空队列，因此这是合法生命周期路径的缺失，不是要求防御任意非法指针。[官方契约](https://nodejs.org/api/n-api.html#asynchronous-thread-safe-function-calls)

修复：队列元素携带独立清理上下文；空 env 时只释放 native payload。TSFN finalizer 负责最终 owner 的释放，保证生产线程停止后才销毁上下文。`closing`、abort、queue-full 的所有权转移有明确分界；最后一次 release 后不继续访问可能已销毁的 Self。不能只在 callback 顶部 return，那会泄漏队列元素。

验收：带未消费事件终止 Worker、abort 后有排队事件、队列满、回调抛错、不同 payload 所有权和进程退出；无崩溃、泄漏、重复释放和后台线程遗留。此项本轮为静态确认，未完成强制退出压力复现。

### F11：Promise 包装没有保护 deferred 的有效性

位置：[promise.zig](../src/napi/value/promise.zig#L24)、[promise.zig](../src/napi/value/promise.zig#L49)。

`from_raw` 创建一个 `deferred = undefined` 的 Promise，但它仍暴露 Resolve/Reject。已有 status 字段在结算前没有检查，第一次结算释放 deferred 后，第二次仍使用同一地址。

复现：对同一 Promise 连续 Resolve 两次触发 SIGSEGV；接收 JS `Promise.resolve(1)` 后调用包装的 Resolve 也触发 SIGSEGV。

修复：拆分借用 `PromiseValue` 与拥有 `Deferred` 的 promise capability。只有创建方能够结算；deferred 可空，成功结算后置空。禁止复制产生独立可结算别名，必要时共享状态记录。所有 Resolve/Reject/Abort 路径使用同一状态检查。

验收：重复 resolve、resolve 后 reject、JS 传入 Promise 的错误使用和状态共享都返回可控错误，不进入 N-API 使用失效 deferred。Node 的 deferred 在成功结算时即被释放。[官方定义](https://nodejs.org/api/n-api.html#napi_resolve_deferred)

### F12：TypedArray/DataView 的缓存无法跨 JS 重入保证有效

位置：[typedarray.zig](../src/napi/wrapper/typedarray.zig#L122)、[typedarray.zig](../src/napi/wrapper/typedarray.zig#L216)、[dataview.zig](../src/napi/wrapper/dataview.zig#L98)。

包装保存 data/len，`asSlice()` 不检查 backing ArrayBuffer 是否被 detach。即使最初参数合法，调用 JS 回调后也可能失效。

复现：包装 Uint8Array 后调用回调，回调用 `structuredClone(buffer, { transfer: [buffer] })` detach 原 buffer，包装仍读出旧首字节 123。此次没有观察到内存被重新分配后的崩溃，不能声称已动态证明 UAF，但缓存已经与 JS 有效性不一致。

修复：明确 slice 仅在“不发生 JS 重入且 backing store 不变”的借用区间有效；安全访问器重新查询有效性及指针/长度，发现 detach 返回错误。跨线程默认复制到 native owned 内存。Reference 只能防止 GC，不能单独防止 detach。长度乘法/加法同时改成 checked arithmetic。需要支持 resizable/shared buffer 时另设契约及同步限制。

验收：回调内 detach/transfer、GC、零长度、byte offset/length 溢出和不同宽度视图；禁止对旧 slice 继续访问。

### F13：泛型覆盖存在可编译性空洞

位置：[array.zig](../src/napi/value/array.zig#L45)、[string.zig](../src/napi/value/string.zig#L70)、[function.zig](../src/napi/value/function.zig#L233)。

三个最小导出分别编译失败：

```zig
pub fn fixed(input: [2]i32) i32 { return input[0]; }
// array.zig:52: type 'type' does not support indexing，代码写成 T[i] = ...

pub fn fixed(input: [2]u8) u32 { return input[0]; }
// string.zig:70: expected type '[2]u8', found '[]u8'

pub fn call(callback: napi.Function(struct {}, void)) !void {
    try callback.Call(.{});
}
// napi.zig:661: type 'void' does not support '@hasField'
```

修复：固定数组创建 `var result: T` 后填充；明确长度必须匹配还是截断/补齐，推荐普通数组严格匹配，二进制转换需要其他规则时另设 API。固定字符串按 UTF-8 字节/UTF-16 code unit 边界处理，不把 slice 强转成数组。回调 Return 为 void 时检查 call 状态后直接成功返回。另补审 UTF-16 输出路径：当前调用只接收 `[]const u8` 的 String.New，需要真正的 UTF-16 constructor。

验收：每项承诺的输入/输出类型都至少实例化一个可运行导出，不能只生成 d.ts 或导入模块。

### F14：分配器和共享 runtime 的生命周期耦合

位置：[allocator.zig](../src/napi/util/allocator.zig#L39)、[class.zig](../src/napi/wrapper/class.zig#L50)、[native_wrap.zig](../src/napi/wrapper/native_wrap.zig#L176)、[async.zig](../src/napi/async.zig#L91)。

finalizer 为释放 payload 临时改写全局 allocator，后台线程同时调用 globalAllocator 会读到其他操作的 allocator；递归清理也不总是使用申请资源时的 allocator。共享 threaded runtime 只注册一个 env 的 cleanup hook，该 env 的关闭会设置全局 cleanup_requested，使其他 env 新任务受到影响。这些为代码路径确认，实际并发概率和目标平台表现未做压力复现。

修复：每个 owned resource 保存 allocator，递归释放显式传 allocator/owner context，不切换全局变量。限制 operation allocator 的作用域并阻止跨异步存活。runtime 要么按 env 持有，要么显式管理使用它的 env 集合与 operation 引用，某个 env 关闭只影响本 env 任务。不要仅换成 threadlocal allocator，因为申请和释放可能跨线程。

验收：两种不同计数 allocator 并发运行，资源由原 allocator 释放；多 env 活跃时终止其中一个，其余仍能提交任务；最后一个 owner 关闭后 runtime 释放一次。

### F15：CLI 默认新项目在 npm 独立安装布局下不成立

位置：[zig-napi.js](../packages/zig-napi/bin/zig-napi.js#L10)、[zig-napi.js](../packages/zig-napi/bin/zig-napi.js#L369)、[package.json](../packages/zig-napi/package.json#L23)、[模板 zon](../packages/zig-napi/templates/node-addon/build.zig.zon)。

默认 zig-napi dependency path 由 CLI package 向上两层推导。仓库中是项目根，但 npm 安装后通常是 node_modules 或安装容器，那里没有本库 build.zig。发布文件列表也不包含根 Zig 库。`--zig-napi` 可绕过，但默认新建流程不完整。本轮未安装或发布远程包，结论来自当前包布局和模板替换逻辑。

修复：发布 CLI 默认生成固定版本 archive URL 与正确 ZON hash，或在 npm 包内携带完整且可寻址的 Zig 源码；`--zig-napi` 保留为本地开发覆盖。生成器不能默默依赖 monorepo 的目录结构。同步校正 README 中旧的 package filter 名称。

验收：从本地 `npm pack` 产物安装到干净目录，执行 new → install → build → require，流程完全不引用源仓库。Windows 同时验证空格路径和参数传递。

### F16：当前“通过”信号覆盖不足

位置：[build.zig](../build.zig)、[strict.zig](../node-test/napi/src/strict.zig)、[node-addon.yml](../.github/workflows/node-addon.yml)。

根构建只声明模块，没有真正实例化全部公共 API，也没有接入 Zig unit tests。现有 strict 测试借助单分支 union 做类型检查，未覆盖同类型普通参数，因此掩盖了 F01 的差异。Node 测试里的 Worker 场景只是部分功能加载，未覆盖跨环境类工厂和销毁。

修复：增加明确的 `zig build check`/`zig build test` 入口，编译公共 API 探针并执行必要的单元测试；加入进程隔离的崩溃探针、计数分配器、异常注入和多环境生命周期测试。修复后的负向用例要断言具体异常和 native 不被调用，而不只断言“不崩溃”。

验收：上述 16 项均有对应的自动检查；平台矩阵保留，但每个 job 必须实际实例化被承诺的 API。

## 分阶段实施方案

各阶段都应提交独立、可评审的代码及对应回归测试。表中顺序是依赖关系，不意味着后面的崩溃问题可以长期保留。

| 阶段 | 具体交付 | 覆盖问题 | 完成条件 |
| --- | --- | --- | --- |
| 0：固定证据 | 最小 addon、JS 子进程 runner、计数 allocator、失败点注入、显式 check/test 入口 | F16、全部回归入口 | 本报告已复现问题在修复前稳定失败；不依赖业务样例的偶然组合 |
| 1：错误与转换 | 可失败的全部输入/输出转换，checked status，pending exception 传播，数字策略，递归回滚，固定类型支持 | F01–F03、F13 | 异常输入不执行 native；getter 原样抛错；无局部泄漏；泛型探针可编译 |
| 2：资源所有权 | Owned/Borrowed 与 allocator context、调用资源作用域、明确 capture/move、返回值迁移 | F04、F07、F14 的 allocator 部分 | 申请/释放配对；静态内存不释放；别名不重释放；分配失败可恢复 |
| 3：类与环境 | env 级 constructor/context、静态/实例/工厂分流、内部工厂构造、事务 setter | F05–F07 | 多 Worker 工厂无句柄串用；字段与构造副作用正确；GC 回收可验证 |
| 4：异步与取消 | Deferred 独立状态、Async/Worker 终态、TSFN shutdown/finalizer、独立 Abort listener、runtime owner 计数 | F08–F11、F14 的 runtime 部分 | 每条失败/取消路径结算或环境关闭清理；无悬挂和重复释放 |
| 5：二进制边界 | 可失败借用访问、detach/transfer 规则、线程输入复制、长度溢出检查 | F12 | JS 重入后重新验证；不访问已失效 backing store |
| 6：交付闭环 | npm 独立模板、示例迁移、d.ts/网站同步、完整 CI 矩阵 | F15–F16 | 干净安装可构建；所有已支持平台均运行对应验证 |

### 推荐的接口与迁移决策

1. **错误模型**：先采用 `!T` 统一控制流；错误 payload 存放在显式调用作用域，保留参数/字段路径、期望类型、实际类型和原始 pending exception。若短期保留 last_error，也必须保存/恢复调用帧以处理 JS 重入；不能把 threadlocal 当作最终隔离方案。
2. **包装层**：自动导出只使用安全、可失败的转换。底层 raw 包装如需保留，明确其调用前置条件，与 safe constructor 分开命名。
3. **所有权模型**：借用值不释放；owned 值含 allocator 和独占释放权；输入临时分配属于调用作用域。JS 句柄与 native 内存分别管理。结果转换是否复制和是否移交给 JS 必须由类型/操作表达。
4. **类模型**：默认字段构造转移字段 owner；自定义 init 默认借用参数并显式保留。工厂只执行一次用户逻辑，返回的 native 实例直接包装。
5. **异步模型**：`.from` 明确接管哪些输入；提供显式 owned capture/clone API。裸 napi_value/Env 不能作为后台线程可操作值；需要 JS 操作时通过 dispatcher 回到所属环境。
6. **兼容性**：Get/复制/转换返回 `!T` 会破坏 Zig 源码兼容，应在变更记录中明确迁移到 `try`。所有权 API 同时迁移本仓库示例，不能保留已知会错误释放的旧实现作默认 fallback。
7. **版本门控**：使用 type tag、instance data、cleanup API 时核对所选 N-API 版本；不要为修复而悄悄提高全部用户的最低版本。OHOS 的行为差异放到平台适配层，避免靠同一段启发式猜测 ABI。

### 最终验收矩阵

| 维度 | 必须覆盖 |
| --- | --- |
| 转换 | 普通/union/optional、嵌套 object/array/tuple、所有数字边界、字符串编码、getter/Proxy 异常、回调错误返回 |
| 内存 | 成功与失败循环、每个 allocator 失败点、字面量/owned/alias/subslice、部分构造、setter、最终 GC |
| Promise | resolve/reject/转换失败、重复结算、借用 Promise、cancel、queue 失败、env closing |
| 并发 | 主线程＋多个 Worker、类 factory、取消与完成交错、TSFN 队列关闭、不同 allocator、最后 owner 销毁 |
| 二进制 | 非法类型、detach/transfer、offset/length 溢出、空视图、后台 capture |
| 编译 | 每种公开签名正向实例化、不支持签名的可读诊断、d.ts 与运行时一致 |
| 平台 | 现有 Node CI 版本/OS 组合、Debug＋ReleaseSafe；核心边界追加 ReleaseFast；OHOS ArkVM/目标架构与 WASI |
| 分发 | npm pack 干净安装、CLI new/build、Node require、平台命名及 WASI loader |

完成标准：已复现的所有崩溃和泄漏都有稳定回归；所有失败路径能解释由谁清理、由谁结束 Promise；不以吞错误、返回零值、禁用安全检查或仅增加去重表容量通过测试。

## 复核入口

既有测试：

```sh
zig build --summary all
pnpm run test:node-matrix
```

临时验证工程（审计机器上的路径，不属于正式修复）：

```sh
cd /tmp/zig-napi-audit.ZevIGo
zig build --summary all
node run-probes.cjs
zig build -Dsource=fixed.zig --summary failures
zig build -Dsource=fixed_string.zig --summary failures
zig build -Dsource=callback_void.zig --summary failures
```

最后三个命令在当前基线上预期编译失败。`fixture.zig` 包含类、内存、Promise、取消、detach 和 AbortSignal 最小导出，正常构建产物为 `zig-out/node/audit.darwin-arm64.node`。崩溃探针必须在子进程执行，不要直接载入承载开发服务的 Node 进程。

以上是审计与修复设计，未宣称实现已经修复，也未将没有运行的目标平台测试标记为通过。
