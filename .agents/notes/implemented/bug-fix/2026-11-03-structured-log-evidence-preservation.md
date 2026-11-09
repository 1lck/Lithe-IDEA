# Agent 笔记：结构化日志收集与文件替换后保留证据

状态：已实现

## 先说结论

macOS 切到结构化日志后，不能继续用文件名倒序分配读取预算，也不能假设打开的日志文件一直存在。读取顺序和旧分类由 Core 计算；原生写入器在追加前确认缓存句柄仍指向活动路径。插件语法失败始终记录插件身份，不能因为语言 ID 不符合目录段格式就漏掉错误。

## 问题

同一会话有多个通道、每个通道有活动文件和轮转段时，名字靠后的旧段会先耗尽 10 MiB 收集预算，最新错误可能完全不进入预览和导出。缓存的文件描述符在文件删除或原子替换后仍可写，但写入目标失去路径，读回时找不到新事件。

迁移还改变了分类与身份约束：更新事件不再出现在已有 Application 筛选中；浏览器返回 `c++` 等合法语言 ID 时，因为路由段不允许加号，整个失败事件被跳过。

## 决策

- Core 接收原生文件元数据，先按会话和既有分类筛选，再按最新会话、活动段、轮转序号及修改时间分配有界读取。平台只执行返回的路径、偏移和长度。正确做法是先读 `a.log`、`z.log`，再读旧轮转；不要按 `z~2.log`、`z~1.log`、`z.log` 的字符串顺序花完预算。
- 通道到旧六类设置选项的映射由 Core 持有，收集和详细诊断共用。更新、远程及 Agent 事件仍属于 Application；终端属于 Run。
- 每次追加前通过原生设备号、inode（文件身份）、链接数和长度检查缓存句柄。路径删除、替换或截断后关闭旧句柄并重开，必要时重建文件头；目录不可写时沿用默认目录回退。只检查路径存在无法发现原子替换。
- 浏览器语法失败使用插件身份路由；语言作为可选、有界的 version 字段。`c++` 保留原值，超长语言 ID 省略该字段，但保留失败事件。

## 考虑过的备选方案

- 继续按文件名倒序收集：新名字不再包含写入时间，无法代表证据新旧。
- 只优先某个通道：会使其他通道的活动日志被旧段挤掉，采用所有活动段优先。
- 每条事件重新打开文件：可恢复路径，但丢失句柄缓存的收益。保留缓存并检查原生身份。
- 把语言 ID 清洗成目录段：改变真实身份，且掩盖插件诊断；仅路由身份需要段校验。

## 后果

日志预览与导出在预算压力、外部清理或原子替换后仍能定位近期错误。每次追加增加一次原生身份检查，Core 增加一个纯计算收集入口；没有新后台定时器或跨工作树可变缓存。日志仍只写平台可写目录，不改变 bundle、代码签名或 Sparkle 增量基线。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'MacLogStoreTests|PluginEditorLanguagesTests|DiagnosticsExportServiceTests|DiagnosticsWorkflowTests'`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib diagnostics::`
- `node scripts/logging/generate-log-events.mjs --check`
- `node --test --test-timeout=60000 scripts/logging/test-log-events.mjs`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`

三项原生文件回归在修复前分别遗漏最新通道、丢失删除/替换后的事件和漏掉更新分类；Core 的 C++ 语法失败用例在修复前返回字段非法。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/diagnostics/collection.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/diagnostics/collection.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/diagnostics/channel.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/diagnostics/channel.rs)
- `macos/Sources/Lithe/Platform/MacOS/Logging/MacLogStore.swift`
- `macos/Sources/Lithe/Application/Features/PluginEditorLanguages.swift`
- `shared/fixtures/diagnostics/logging-v2.json`
