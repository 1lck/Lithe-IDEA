# Agent 笔记：独立的插件高亮与编辑器动作 API

状态：已实现

## 先说结论

普通工具插件可以独立提供文本高亮、编辑器配置和位置动作，不要求实现 LSP（语言服务器协议）、构建、运行或调试提供者。静态资源使用 `languages:2`，位置动作通过函数协议 3 的独立宿主方法注册，再复用原有函数调用执行；没有 `runMarkers` 清单能力，也不修改 `commands/didRun`。当前接线限 macOS，运行和界面验收以功能矩阵为准，不把静态校验当作产品验收。

## 问题

HTTP 工具插件需要高亮和请求旁的按钮。原方案把按钮建模成专用运行标记，并向通用命令通知加入 `runMarker`，扩大了无关领域的兼容面。用户确认[独立能力与领域边界](2026-10-31-plugin-capability-and-domain-boundaries.md)：宿主理解动作的有限展示结构，插件理解 HTTP/SQL 等业务，不能因为按钮像播放图标就归入 Run。

## 决策

### 静态高亮与后端业务分离

语法和注释/括号配置属于安装包内只读资源，通过独立编辑器模块启用；不要求语言服务器或后端。仅配置贡献也应用，编辑器模块不抢占已有语言的运行、调试和服务器所有权。纯静态资源可安装、停用和卸载即时生效，带后端的插件继续遵循既有启动登记规则。没有 UI 或领域模块的独立后端派生应用级启用模块，不能为通过 catalog 检查伪造网页；启动仍检查明确启用、安全模式和隔离状态。

复用已固定版本的 Monaco Monarch 引擎，不在 Core 重写词法分析。Core 校验资源大小、状态和规则，并拒绝 include 环及展开后超过预算的图；浏览器中的专用 worker 才编译和执行插件正则，主线程只接受 token。worker 超过本地执行期限时终止，该语言退为普通文本，不影响编辑与保存。现有 TextMate/Oniguruma 已打包，不以“需要新增 WASM”作为否决理由；首版选择 Monarch 是局部数据适配，不改变 Java 的 TextMate 工作流。

### 编辑器动作是小型独立契约

后端先注册普通函数，再通过 `editor/registerActions` 注册上下文、文件选择器和收集函数。宿主返回既有 subscription，由会话、上下文或显式释放共同清理。注册时只记录绑定，下一事件轮才请求解析，避免后端等待宿主注册答复、宿主又等待同一后端的循环。

宿主向收集函数提供公开文档身份、内容版本和当前脏缓冲。返回范围、标题、受限图标和同插件函数绑定；Core 只校验结构和 UTF-16 边界，不解释请求、查询、框架或任务 ID。多个同一行动作进入同一菜单，不制造测试种类或覆盖为只剩一个动作。

正确做法：HTTP 的“发送请求”和 SQL 的“执行查询”都返回同一展示结构，分别绑定自己已有的普通函数。不要这样做：新增 `http`/`sql` 执行类型、把请求包成假 Build 任务，或者要求工具插件提供 LSP CodeLens。

点击时浏览器只回传宿主生成的批次和动作键，不能提供函数或业务参数。宿主重新验证内容版本、上下文、注册租约与会话函数，再用已有 invocation 调用；插件收到文档身份、预期版本和自己的不透明数据，执行前核对当前文本。命令通知保持原样，命令面板可调用同一插件业务实现。

### 生命周期与兼容

编辑立即撤销旧动作，取消旧收集任务，防抖后再请求；关闭、替换和失效结果均不得恢复旧按钮。解析和用户执行分开管理，后者不因重新解析被误取消；撤销注册、关闭上下文或会话结束时取消所属执行，不自动重试 HTTP 等副作用。

新宿主方法在已支持增量能力发现的函数协议 3 内新增，不提高整套协议或新增领域版本。新增 `editor.actions` 权限由安装审查明确确认，旧宿主不认识时拒绝安装；不能一边要求新权限、一边宣称同一包能在旧宿主无条件降级。静态清单新增资源仍要求 `languages:2`；契约、fixture 与两个 SDK 的验证和合并后镜像同步不能省略。

第一版使用既有 `onWorkspaceOpen` 启动，接受其后台成本。不会通过尚未存在的注册信息发现一个未启动的后端，也不假称已支持按文件懒启动或后端热安装。

### 资源生命周期

grammar 从只读插件包有界读取，校验结果仅在本次进程内缓存；编译后的状态与文档 token 属于一个 worker，终止/停用时释放，不落盘。worker 代码复用本工作树生成的 `textmate-worker.js`，应用运行时只读；编辑器动作和租约也仅在内存。没有 bundle、安装资源或跨工作树缓存写入，不影响签名及 Sparkle 增量基线。

## 考虑过的备选方案

- 要求工具插件提供 LSP：标准化但无必要地强加语言服务生命周期，拒绝。
- 专用 `runMarkers` 和 `didRun.runMarker`：把展示和执行耦合，新增一种动作就扩张执行通知，拒绝。
- 函数名约定或插件名分支：宿主猜私有协议且无法安全撤回，拒绝。
- 首版做任意样式装饰/万能工具工作流：超出当前需求；仅开放范围、标题、图标与函数绑定。
- 直接在主线程运行语法：长度限额不能阻止病态回溯，采用可终止 worker。

## 后果

收益是工具插件不污染领域模型，执行复用现成函数基础设施。代价是增加一个明确授权的独立编辑器贡献契约，需要跨语言校验与生命周期接线。首版不支持远程、只读预览动作，也不承诺任意大型文档的插件高亮；Windows 产品接入和完整界面验收仍需后续完成。

### API-25 当前不是通用 Provider 注册框架

当前高亮入口只接受插件清单和包内 JSON 资源；纯静态插件的安装、更新与撤回即时生效，不代表后端可以在运行中直接传 JSON 注册、替换或释放高亮 Provider（能力提供者）。已安装包仍只读，也没有任意语法文件修改后自动重载的承诺。

独立补全、悬浮、定义、符号、格式化、重命名和 Code Action 尚无 JSON 到普通插件函数的注册绑定；既有 LSP 实现和独立 `editor/registerActions` 都不能冒充这些接口。新增符合既有 Monarch 结构的文本格式只改插件，不因规则变化升级 API；新增引擎或能力种类则仍需宿主适配与契约，不能靠未知 `kind` 自动获得实现。

因此 API-25 只完成静态语法与编辑配置这一部分。当前 worker 对超过 128 Ki UTF-16 单位或 10,000 行的文档保持普通文本，嵌入语言也按普通文本处理；SDK 兼容性测试通过不等于新增能力的封装、发布及真实插件安装验收已经完成。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib plugin_editor_resources`：静态资源、配置及 include 预算。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib plugins::editor_actions`：HTTP/SQL 同构动作、范围、重复身份及不透明数据。
- `bun test frontend/editor/src`：活跃文件匹配、别名身份、配置独立应用与撤回。
- `scripts/macos/test/test-macos.sh --filter 'PluginEditorLanguagesTests|PluginEditorActionTests'`：真实 catalog 接纳、独立模块与动作注册清理。
- `scripts/macos/verify/verify-runtime-bundle-immutability.sh`：发行路径只读静态边界。

## 适用范围

- `rust/lithe-core/src/plugins/grammar.rs`
- `rust/lithe-core/src/plugins/editor_actions.rs`
- `macos/Sources/Lithe/Application/Features/PluginEditorActionHostService.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginEditorLanguages.swift`
- `frontend/editor/src/plugin-languages.ts`
- `frontend/editor/src/plugin-editor-actions.ts`
- `frontend/editor/src/plugin-grammar-tokenizer.ts`
