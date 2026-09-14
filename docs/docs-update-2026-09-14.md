# 首页构建流程与近期能力文档细化

## 交付范围

- 起点：`docs/astro-kami` 的 `ad8ff52`；继续当前分支，不修改原生运行时或依赖，不推送、不部署。
- DS Flash 经 Claude CLI 实施，主负责人规划、源码核对、独立验收及整合提交。
- 首页：保留现有布局与英文内容体系，以 kami 暖纸/墨蓝样式重做 Build pipeline，补全 OpenHarmony、原生 Node、WASI 与独立类型声明步骤。使用响应式语义 HTML，手机端不缩小一整张流程图，不增加运行时脚本。
- 文档：新增 WASM Runtime 指南，细化两种 WASI 模式、产物、加载、取消、实例销毁、内存与排障；补充异步、所有权、转换及二进制视图的具体用法。保留已有 15 篇文档的地址和 120 个标题锚点。
- 样式按 kami `SKILL.md`、`CHEATSHEET.md`、图示/写作规范实施；流程维护资产保留 HTML、PNG 与 prompt 三件套。静态源码与线上响应式组件使用同一事实关系，截图不作为客户端必需下载。

## 分工与事实边界

两个 `deepseek-flash[1m]` 会话分别负责正文及导航元数据、首页流程及相关站点测试。二者不提交、不并行构建；全部完成后由主负责人顺序验证两种部署基础路径。

源码依据：`packages/zig-napi/bin/wasi-templates.cjs`、`packages/zig-napi/bin/zig-napi.js`、`packages/zig-napi/templates/node-addon/index.js`、`src/build/napi-build.zig`、`src/napi/`，以及 `node-test/napi/`、`node-test/wasm/` 和 CLI loader/pack 用例。

不可混淆的边界：

- 当前固定 emnapi `2.0.0-alpha.5` 是预发布版本，不宣称稳定 2.0 或当日最新版本。
- 线程模式使用 emnapi JavaScript worker pool，非线程模式在宿主 JavaScript 线程执行；不是完整 napi-rs/Rust/Tokio 等价实现。
- 公共模板通过 `NAPI_RS_WASI_FLAVOR=wasm32-wasi|wasm32-wasip1` 严格选模式；仓库测试的 `ZIG_NAPI_WASI_FLAVOR=wasi|wasip1` 不是包的公共环境变量。
- CLI 解析后的初始内存默认 4000 页，也传给 deferred 模板；模板直接调用时的 1024 页默认不等于 CLI 产物默认。链接器最小页数由数据与栈决定，不是对所有模块固定 257 页。
- 单次分配保护上限不等于总内存上限；逻辑释放不保证线性内存或 RSS 下降。
- 非线程模式不能依靠 JavaScript timer 抢占同步执行；销毁要等待异步清理，不能把 Promise 已拒绝等同于原生所有者已释放。
- 浏览器跨源隔离依据 [MDN crossOriginIsolated](https://developer.mozilla.org/en-US/docs/Web/API/Window/crossOriginIsolated)；本次不宣称已验证 workerd 部署、真机 ArkVM 或全部浏览器。

## 验收门槛

1. 对照实际 API 与测试审查代码示例、默认值、参数顺序和生命周期；对新增可执行示例进行独立运行或编译验证。
2. 根路径 `/` 与子路径 `/zig-napi/` 分别构建、静态测试、真实 Chrome 测试；所有原有用例保留，新增流程图与 WASM 文档覆盖。
3. 独立核对原 120 个标题 ID 保留；检查新增文档的导航、分页、目录和内部链接。
4. 查看 320/375/1280px 流程与受影响页面，验证字号、无页面横向溢出、键盘访问与无 JavaScript 阅读。
5. 文档页继续零 JavaScript，流程不引入额外脚本或必须下载的导出 PNG；工作区 lint、格式与 `git diff --check` 通过。

## 验收结果

过程证据目录：`/tmp/zig-napi-docs-polish.GBLbsN/`。两组 Claude CLI 会话的初始化记录均为 `deepseek-flash[1m]`；实现及返修由 DS 完成，主负责人未修改站点实现或原生代码。

### 交付内容

- 首页改为可选择、可访问的 HTML 构建流程，列出 OpenHarmony `.so`、Node `.node`、双模式 WASI `.wasm` 和独立 `.d.ts` 步骤；四个入口均指向对应指南，支持部署 base。
- 保留 kami 配色与页面结构，删去流程中的长命令和底层说明，将这些内容放到指南。流程实测高度：1280px 宽为 369px，375px 宽为 816px，320px 宽为 880px；最小字号 12px，无页面横向溢出。
- 新增 `wasm-runtime.md`：两种模式和产物、固定预发布依赖、CLI 与配置、Node/浏览器/延迟加载、取消和销毁、内存边界、排障、验证命令及平台限制。
- 补充 Async Runtime 的调度差异、取消检查点、销毁屏障、完整 Zig/JS 进度示例；补充 Binary Data 的安全捕获和复制回退所有权。Node 构建页、Overview、导航及维护 README 同步更新。
- 图示维护三件套为 `website/public/diagrams/build-pipeline/{index.html,index.png,prompt.md}`，PNG 从 HTML 导出为 2400×1382；首页不加载该 PNG 或旧 SVG。旧 SVG 留作历史/其他引用，本次未删除。

### 独立验收矩阵

| 检查 | 根路径 `/` | 子路径 `/zig-napi/` |
| --- | --- | --- |
| `website:build`，含 `astro check` | 通过，19 个 Astro 页面 | 通过，19 个 Astro 页面 |
| `website:test` | 135 通过，0 失败/跳过 | 135 通过，0 失败/跳过 |
| `website:test:browser` | 256 检查，0 失败 | 256 检查，0 失败 |
| 浏览器证据 | 61 次页面加载，68 张截图 | 61 次页面加载，68 张截图 |
| 旧标题锚点独立核对 | 原 120 个均保留 | 原 120 个均保留 |

19 个 Astro 页面为首页、16 篇文档、Overview 兼容别名和 404；额外维护 HTML 作为 public 资源复制，不计入文档路由。两种模式均显式传入一致的 `SITE_BASE_PATH`；最后恢复根路径 `website/dist`。

真实浏览器为 Chrome `152.0.7977.83`。检查包括全站初始 HTML、导航、目录、分页、内部链接、刷新/历史、无 JS 阅读、四个代码标签、键盘与复制成功/失败、未知页面、reduced motion、窄屏溢出。主负责人另查看流程 320/375/1280px 的实际宿主页面截图，以及 WASM、异步、二进制数据、Node 构建、Overview 的代码与表格区域；补充截图位于 `leader-visual/`，没有用自动断言替代视觉审查。

### 示例与运行时回归

- 按文档命令在隔离临时目录创建项目，仅把 Zig 依赖指向当前本地源码、复用已安装依赖；线程版 Debug、非线程版 ReleaseFast 均构建成功。
- 抽取文档的 Node loader 示例执行，输出 `5` 并等待销毁。浏览器将生成的 `.wasm` 按文档要求部署在加载器旁，通过 Vite 解析依赖；普通非线程加载与延迟独立实例示例分别输出 `5`、`3`，无页面异常，未启用跨源隔离。
- 将完整进度示例直接放入 scaffold 的 `src/lib.zig`，线程版、非线程版和原生 Node 均编译成功。JS 示例验证按序交付事件、监听器中取消、`AbortError` 拒绝与 `finally` 销毁；非线程版本次交付 8 个事件，线程版 263 个，符合并发下取消不是精确抢占的约定，不把该次数作为稳定 API。
- 校验和示例从已验证视图捕获数据；调用返回后立即转移/分离原始 ArrayBuffer，结果仍为 `6`，销毁完成。原生 Node 同样验证结果和进度取消。
- 原生能力回归 `pnpm --filter zig-napi-node-test run test:napi`：189 通过。
- CLI 加载器/打包用例：31 通过，无跳过。
- WASM ABI/并发用例：6 通过；1 项需要专用低内存产物的 OOM 测试按现有条件跳过，本轮不将其算作通过。
- 现有 WASM 浏览器回归：线程/非线程的 UTF-8、TypedArray、异步、事件顺序、异常身份、取消、销毁，以及 deferred 字节输入拒绝、实例隔离、单例复用和重新实例化均通过。

### 复核修正与回归防护

审查期间退回并修正了延迟加载器默认导出、销毁后的模块缓存、CLI 子命令作用、内存导入最大值匹配方向、线程取消语义、复制回退的即时 finalizer 等不准确初稿。删除会泄漏的普通已分配切片导出示例，改用受控异步捕获及明确所有权说明；这些是文档修正，不是本轮运行时行为变更。

内存匹配方向通过一个最小 Wasm 模块实测：模块最大值为 10 页时，宿主提供最大值 5/10 页可实例化，11 页被拒绝；依据为 [WebAssembly 类型匹配规范](https://webassembly.github.io/spec/core/valid/matching.html)。额外的 `initial < maximum` 是当前 Zig 分配器需要的增长余量，不与 Wasm 导入匹配规则混为一谈。

旧锚点现在固定在独立 fixture `website/test/lib/published-anchors.json`，不从当前正文重新推导。测试对内存中的旧 ID 删除/重命名做负向验证，保证新增段落后仍能捕获旧链接被破坏。另修正静态测试对跨代码片段的加粗/链接误解析，并新增实体、反斜线、字面代码及缺失正文负向用例，没有为了通过验收而改掉正确 Markdown 或弱化正文检查。

### 资源与结论

16 篇文档均为零 JavaScript；首页保留原来的 2225 B 渐进增强脚本（gzip 977 B），流程不增加脚本。共用 CSS 为 18390 B（gzip 4163 B），比上轮增加 2773 B；导出的 PNG 不进入首页请求。以上是文件体积，不冒充网络测速或 RSS 测量。

工作区 lint、修改的 Astro 文件 Prettier 检查、`git diff --check` 通过；运行时源文件、工作区依赖和锁文件未改动。验收通过，无本轮待修复阻塞项。仅本地提交，不推送、不部署；未扩展宣称 Safari/Firefox、workerd 部署、真机 ArkVM 或完整 napi-rs 等价能力。
