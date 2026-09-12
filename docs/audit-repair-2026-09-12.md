# 实现审计修复与验收结果

日期：2026-09-12。审计基线：`f71e6b7`。交付分支：`fix/audit-2026-09-12`。

## 结论

[原始审计](implementation-audit-2026-09-12.md) 的 16 项问题（13 项 P1、3 项 P2）均已完成对应代码修复并纳入回归验证。本报告描述修复后的状态；原始报告保留问题复现和当时的证据，不代表当前代码仍然存在那些问题。

按用户要求，通过 Claude CLI 启动三个 `deepseek-flash[1M]` 子 agent，分别处理转换与所有权、异步与生命周期、类与二进制包装。子 agent 在隔离 worktree 提交，主 agent 逐项审查、补充独立复现、退回补修并统一集成。验收发现的外部指针溯源、runtime 地址稳定性、类 OOM 回滚、旧 Node 空缓冲区、WASM 事件顺序等问题亦已补修，未直接以子 agent 的完成声明代替验收。

这里的“完成”限定于下述实现和实际执行的验证，不等同于所有平台、所有分配失败点及任意用户 Zig 代码的安全认证。未执行远程推送、PR 或发布。

## 问题闭环

| ID | 已实施修复 | 回归证据 |
| --- | --- | --- |
| F01 | 转换入口改为 `!T`；检查 N-API 状态及类型；回调结果同样校验；保留原 JS 异常；补齐 `NapiValue.As` | 错误类型、缺参、getter/Proxy 抛错、回调错误结果及异常后恢复 |
| F02 | 整数输入统一检查范围、符号、有限性和整数性；u64 输出不再经过 i64；BigInt 提供精确整数路径 | 数值边界、NaN/Infinity、小数、枚举、TypedArray；三种优化模式结果一致 |
| F03 | 数组、固定数组、tuple、struct、optional、union 等转换失败按已初始化前缀回滚；枚举临时字符串释放 | 万次循环计数归零、嵌套转换失败、克隆分配失败注入 |
| F04 | 明确普通返回值借用、`Owned(T)` 返回值转移所有权；参数由调用边界释放；**参数转换中创建的 JS 资源（强引用、TSFN）按转换事务回滚**，原生函数入口处提交；异步输入独立克隆，输出及事件保留原 allocator | 同步/异步字面量、别名、堆返回值、未捕获参数；实际文件读取示例和 GC 后计数回基线；被拒绝调用的 WeakRef 回收与子进程自然退出 |
| F05 | 类构造器上下文按 env 隔离；弱引用及分版本清理路径；句柄不跨 env 复用 | 主线程和 Worker 同时加载、Worker 退出/终止及构造器回收 |
| F06 | 区分静态方法、实例方法及工厂；工厂绕过 init；支持值接收者；禁止无 init 类直接 JS 构造；检查 new target | 工厂、静态方法、值接收者、`.call({})`、ClassWithoutInit |
| F07 | 类转换参数保活到实例回收；明确字段所有权策略；setter 释放旧值且保留 allocator 来源；失败 init/factory 仅清理真实拥有的数据 | 构造失败、setter 循环、init/factory 逐分配点失败、实例只终结一次及 Owned 方法返回 |
| F08 | AbortSignal 使用独立 add/removeEventListener 注册，不覆盖 wrap/onabort；释放后保留的 JS 回调安全失效 | 原有监听器保留、多注册、预取消/运行中取消、恶意保留回调、注册抛错 |
| F09 | 预分配完成记录；返回转换失败和 Worker 取消进入拒绝终态；跨线程错误快照拥有文本，OOM 使用静态降级错误 | 结果转换失败、线程错误文本、取消及超时保护；WASM 完成记录与事件共用 FIFO |
| F10 | TSFN 的 null-env 排空路径只回收 native 数据；投递失败和正常交付使用明确的载荷所有权；错误投递改为单参数调用并拥有错误文本；`Ok`/`Err` 失败不再 panic | TSFN 正常投递、关闭/终止子进程及 native 清理单测；错误分支参数个数、借用文本、满队列/关闭释放与送达后计数归零 |
| F11 | 借用 `PromiseValue` 与可结算 Promise 分离；deferred 能力注册、原子结算状态、共享别名状态及 JS GC 回收 | 复制、重复结算、reject-after-resolve、外部 deferred、借用 Promise、结算状态及计数 |
| F12 | 二进制访问重新验证 backing store、边界和 detach；WASM DataView 写回不先覆盖 native 数据；兼容旧 Node 的空缓冲区误判 | TypedArray/DataView detach 后拒绝读取、零长度有效缓冲区、JS 重入后访问、WASM 写回 |
| F13 | 补齐固定数组、固定字符串、void 回调和泛型实例化；类型生成器解包 Owned/PromiseValue | 编译回归 fixture、运行时调用、示例构建及声明生成 |
| F14 | allocator 管理状态线程局部化；长期对象记录创建 allocator；runtime 用稳定堆地址、env/operation 引用和独立回收线程 | 嵌套 allocator、重入切换、OOM、并发环境、20 次 Worker-only runtime 退出再启动 |
| F15 | CLI 包内携带 Zig 源码和构建定义；默认使用已安装包；规范化路径；去除 shell 拼接；打包前清理过期源文件 | 实际 npm pack、独立目录安装、带空格路径创建、编译并加载 addon，验证结果为 5 |
| F16 | 默认构建实际编译 host addons；提供 check/test/test-unit；接入 4 组审计 fixture、原生单测和独立包 CI | 82 项既有 JS 测试扩展至 185 项；根目录测试命令真正执行编译和测试 |

NativeWrap、Class 和 External 均在解引用前验证 native 指针是否由本模块注册。额外使用地址 `1`、`8` 的外部 payload 进行隔离进程回归，防止“先读取 magic/tag 再判断归属”仍然崩溃。

## 2026-09-12 补充修复（回调转换所有权）

本轮补充审计（H03/H04/H07）针对“参数转换会创建 JS 资源”与“TSFN 错误投递”两处遗漏，修复位于 `src/napi/util/helper.zig`、`src/napi/value/function.zig`、`src/napi/wrapper/reference.zig`、`src/napi/wrapper/thread_safe_function.zig`、`src/napi/util/napi.zig`：

| ID | 已实施修复 | 回归证据 |
| --- | --- | --- |
| H03 | 错误优先 TSFN 的失败投递只传一个参数；参数槽预填 JS `undefined` 而非 native null；错误对象构造逐项检查状态 | `Args` 为 0/2 槽、`calleeHandled` true/false、不可转换载荷与回调抛错后继续投递；修复前同 fixture 复现 SIGSEGV |
| H07 | `Err` 把 message/code 复制进 `ErrorSnapshot` 后再入队，并在送达、满队列、关闭、null-env 排空各路径释放；快照分配失败降级为静态错误 | 借用栈缓冲被覆盖后仍收到原文；送达后计数归零 |
| H04 | 参数转换成为事务：转换期间创建的强引用与 TSFN 记入 `ConversionFrame`，失败时在原生参数清理前释放，原生函数入口处提交 | 第二个参数失败时 WeakRef 100/100 可回收、子进程自然退出；成功调用后 TSFN 仍可跨线程投递、引用仍被持有直到显式释放 |

类构造器/方法与手工调用 `Napi.from_napi_value*` 的代码尚未安装事务帧；需要同样的回滚语义时，使用 `Napi.ConversionFrame`：

```zig
var conversion = Napi.ConversionFrame{};
conversion.start(allocator);          // 与参数转换使用同一个 allocator
defer conversion.end();               // 归还簿记内存并恢复外层帧
defer conversion.rollbackUncommitted(); // 必须注册在原生清理 defer 之后，先于它执行
...                                   // 参数转换
conversion.commit();                  // 进入函数体前提交
```

转换代码创建 JS 资源时调用 `Napi.trackConversionResource`（或
`trackConversionReference`/`trackConversionCustom`）：没有活动帧时不登记，
已提交或未安装帧时登记是空操作。`trackConversionResource` 返回
`error.OutOfMemory` 表示没有任何登记位，调用方必须自行释放刚创建的资源并让转换失败。

## 实际验收

环境：macOS arm64、Zig 0.16.0（本机 OHOS 工具链）、pnpm 10.24.0。下列数量是实际执行结果，不是 CI 配置的计划数量。

| 验收项 | 命令/方式 | 结果 |
| --- | --- | --- |
| Debug，Node 22.23.2 | `zig build test --summary all` | 185 项 JS + 28 项 Zig 单测通过 |
| ReleaseSafe，Node 22.23.2 | `zig build test -Doptimize=ReleaseSafe --summary all` | 185 项 JS + 28 项 Zig 单测通过 |
| ReleaseFast，Node 22.23.2 | `zig build test -Doptimize=ReleaseFast --summary all` | 185 项 JS + 28 项 Zig 单测通过 |
| Node 16.20.2 | 使用该版本 node 运行 `node-test/node_modules/ava/cli.js --serial`，工作目录 node-test | 173 项通过 |
| Node 24.12.0 | 同上，使用 Node 24；两项版本复验使用最终 ReleaseFast addon | 173 项通过 |
| WASM/emnapi，Node 22.23.2 | `zig build -Dtarget=wasm32-wasi -Dcpu=generic+atomics+bulk_memory`（本机 Zig 0.16 对 wasip1-threads 的写法），随后 `NAPI_RS_FORCE_WASI=error node node_modules/ava/cli.js --serial` | 170 项通过，15 项 native-only 测试显式跳过 |
| OHOS 编译 | 设置 `OHOS_NDK_HOME` 后执行 `pnpm run build:examples` | 6 个示例 × arm64/arm32/x64，共 18 个目标编译通过 |
| 独立 CLI 包 | `pnpm run test:cli-pack` | 1 项完整 pack/install/create/build/load 测试通过 |
| 静态检查 | `pnpm run lint`、`zig fmt --check`、`git diff --check` | 通过 |

补充修复（H03/H04/H07）后在本机 Node 22.23.2 上复验 Debug / ReleaseSafe / ReleaseFast 与 WASM/emnapi，结果如上表对应行（新增用例使计数从 173/24 变为 185/28，WASM 从 165+8 变为 170+15）。Node 16、Node 24、OHOS 与独立 CLI 包各行仍是上一轮记录，尚未用最终 addon 复跑；WASM 一行复用 CLI 生成的 `.wasi.cjs` 包装，只重新编译了 `.wasm`。

回归代码位于 `node-test/audit`、`node-test/napi/src/*_audit.zig`、`node-test/napi/__tests__/*-audit.spec.js`；原生测试入口为 `src/unit_tests.zig`；独立包测试为 `packages/zig-napi/test/pack.test.cjs`。验收日志保留于执行环境 `/tmp/zig-napi-repair.i5zUyW/final-*.log`，该临时目录不属于分支交付内容。

Node 16 的有效空 ArrayBuffer 被底层误判为 detached 已动态复现；该版本底层使用 backing store 数据指针是否为空来判断，见 [Node v16.20.2 官方实现](https://github.com/nodejs/node/blob/v16.20.2/src/js_native_api_v8.cc#L2985-L2996)。兼容分支仅用于旧 Node 的歧义结果，通过构造 JS view 进一步辨别；此分支依赖标准 `Uint8Array` 内建未被替换。现代 Node、WASM 和 OHOS 不走此 Node 版本兼容分支。

## 必须同步迁移的 API 契约

1. 手动调用 `Napi.from_napi_value*`、`NapiValue.As(T)`、值读取/复制等可失败接口，需要 `try` 或明确处理错误。不要将捕获到的错误替换成未初始化值继续执行。旧的部分 `New`/`from_raw` 便捷入口仍为可信输入或不可恢复失败接口；不应拿来校验外部输入。
2. 整数转换不再隐式截断小数、负数或越界值。JS Number 仍有 IEEE-754 精度边界；需要完整 64 位整数时使用 BigInt，而不是假设所有 u64 都可精确表示。
3. 新分配的返回值使用 `napi.Owned(T).init(value, allocator)`；普通值视为借用。Owned 的 allocator 必须与分配来源一致。嵌套 owned 字段也会在转换完成或失败后释放。
4. JS 转换参数由 wrapper 管理。普通函数不能保存参数指针供调用结束后使用；异步框架克隆其捕获输入。类 init/factory 的借用参数由框架保活到实例回收，用户 deinit 不能再次释放这些借用字段；需要自己管理时应显式克隆。
   参数转换中**创建**的 JS 资源（`Reference`/`ObjectRef`/`FunctionRef`、TSFN）属于转换事务：调用在进入原生函数前被拒绝时由框架释放，进入原生函数后归函数体所有，函数体必须自行 `Unref`/`Delete` 或最终 `release()`/`abort()`。TSFN 常在转换成功后被交给其他线程，因此框架不会在成功返回后回收它。
   `Reference(T)` 是值类型，复制只复制句柄而不复制所有权：任何一份副本 `Unref`/`Delete` 都会删除同一个引用，请为每个引用保留唯一所有者，共享时传递 `GetValue` 得到的借用值。
5. 用户构造器/工厂必须完整初始化 T。带自定义 deinit 的类，对归属不明的资源字段 setter 会拒绝更新；应声明明确的字段所有权或在业务方法中处理替换。不要将实例仍然拥有的字段重新包装为 Owned 返回。
6. `Promise.New`、`Worker.AsyncQueue` 等创建操作需要处理失败；只读 JS Promise 使用 `PromiseValue`。重复结算和无效 deferred 会报错，不能作为可复制的独立能力使用。
7. 优先使用 `Async.tryFrom`、可失败排队接口。Async 描述符是一次性所有权，调度后不可再次独立消费其拷贝；兼容 `.from` 在无法分配错误描述符的极端 OOM 下仍可能 panic。
8. 使用 `tryFromRaw`/`tryAsSlice` 检查二进制包装。拿到的 slice 仅在下一次 JS 重入前有效；重入后必须重新取值，不能保存旧地址继续访问。
9. 长期资源使用其捕获 allocator；应用配置的默认 allocator 必须满足线程安全和生命周期要求。线程局部 operation override 不会自动赋予底层 allocator 线程安全性。

10. 错误优先 TSFN（`ThreadSafeFunctionCalleeHandled = true`）的失败投递只有一个参数：成功投递为 `(null, ...args)`，失败投递为 `(err)`，其余槽位被省略而不是传入占位值。`calleeHandled = false` 没有错误槽，`Err` 仍会调用回调但参数为 `undefined`。`Ok`/`Err` 一律转移载荷所有权（满队列、关闭、分配失败同样如此），错误文本在入队时被复制。

更详细的示例与契约已同步至网站的 Conversion、Ownership、Functions、Async Runtime、Binary Data、Primitive Values 和 Objects 文档；历史转换重构计划已标记为历史设计。

## 保留限制与发布前门禁

- 未在 OHOS/ArkVM 实机执行测试；18 个编译目标通过不代表 ArkVM 的 GC、取消、线程和 ABI 行为已认证。发布前须补充真机功能与销毁压力测试。
- 本机 Windows MSVC 交叉构建因缺少可用 MSVC libc/SDK 失败，未取得 Windows 运行结果；Linux、Node 12/14/18/20 的完整最终矩阵亦未在本次本机验收中执行。已有 CI 矩阵保留，新回归随矩阵运行；Node 12 缺少原生 AbortController 的用例显式跳过。未远程触发或声称这些 CI 已通过。
- WASM 的 8 项跳过涉及 native 线程/runtime、进程关闭或原生文件 IO 计数，不应把 WASM 通过理解为这些路径已覆盖。
- Zig 不强制线性所有权。手动复制 Owned、重复消费 Async 描述符、重复拥有重叠切片、返回 undefined 字段、绕过 wrapper 使用原始 sys 指针，仍属于调用方违反契约，框架不能普遍修复。
- 取消是协作式的；忽略取消的用户任务不保证立即停止。环境已关闭时 native 清理不能再调用 JS，也不承诺让已经销毁环境内的 Promise 可被观察到结算。
- 转换事务只覆盖安装了事务帧的入口：目前是 `Function.New` 生成的导出函数回调。类构造器/方法与直接调用 `Napi.from_napi_value*` 的代码尚未安装事务帧，需要时可使用 `Napi.ConversionFrame`（见“补充修复”一节的 helper 说明）；在它们安装之前，这些入口里被拒绝的参数仍会保留其创建的引用/TSFN。
- 事务在进入原生函数体的时刻提交：之后创建的引用与 TSFN 归函数体所有，框架不再追踪。函数体必须显式 `Unref`/`Delete` 或最终 `release()`/`abort()`；成功调用后“丢弃”一个引用参数仍然会永久保留该 JS 对象。
- `Reference(T)` 是值类型，复制副本之间没有共享的“已取走”状态；框架无法检测同一句柄的多副本所有权，这属于调用方契约。
- `Err` 会复制错误的 message/code（每次入队一次小分配）；这是错误文本在跨线程队列中存活所必需的代价。
- 验证包含计数分配器、失败注入、万次转换循环、GC 和 Worker 子进程，但不是无限时长压力测试或每个 N-API 返回值的故障注入。建议发布门禁保留完整平台矩阵，并补充长时间并发/环境重建压力测试。

## 集成与回滚

全部修复、回归、示例迁移和文档位于同一交付分支，保留分工提交及主 agent 验收补修提交，便于追踪。不要单独合入转换入口而遗漏示例和调用方迁移，也不要独立回退 Owned 而保留新清理逻辑。

尚未合入主分支时，可直接不合并此修复分支；若后续已合入，按整体合并提交执行可审计的 revert，并同步回退 API 调用方迁移。不要通过删除测试、隐藏异常或恢复不检查状态的旧路径来规避失败。
