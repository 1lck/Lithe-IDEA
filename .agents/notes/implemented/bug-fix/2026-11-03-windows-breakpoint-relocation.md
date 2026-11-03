# Agent 笔记：Windows 编辑后把断点位置写回唯一存储

状态：已实现

## 先说结论

Windows 编辑器通过已有的 `debug.relocateBreakpoints` 移动断点，并把结果写回断点
store（界面和调试请求共用的状态存储）及本地持久化。启动调试前必须等待位置更新，
然后重新读取断点；不能使用点击启动按钮时捕获的旧列表。

## 问题

Monaco 编辑器会临时移动行边的断点图标，但重新绘制或启动调试仍从旧存储读取行号。
此外，编辑器为同步原始换行而携带的替换范围会包含未变化的相邻字符；把这种范围
直接交给断点定位，会把仍然存在的代码当成已删除，丢失断点的启用状态。

## 决策

原始源码映射器同时提供精确编辑范围 `anchorChanges`，保留原来的同步补丁供其他
消费者使用。UTF-16 是编辑器的位置单位，emoji 通常占两个单位；传给 Core 的偏移
必须来自源码映射器，不能直接使用 Monaco 已统一换行后的偏移。

位置和冲突合并规则全部交给 Core。一次编辑中的多个替换先共同处理，再投影和去重，支持 LF、CRLF、CR。版本化源码快照只在首次传完整文本，后续传增量；缓存最多 4 份，每份最多 16 MiB，采用最近使用淘汰，不写安装资源。
Windows 将等待中的相邻编辑按原始顺序合批：只保留批次起点、最新文本引用和各次编辑的增量，不为每次输入保留整份旧文本。Core 在每次编辑之后投影和去重，因此与逐次请求的结果一致；用户修改断点后，新编辑必须开启另一批。正在执行的请求和等待队列各有独立的源码引用生命周期，等待队列限制 32 MiB，所有待处理编辑限制 128 次和 32 MiB 增量。超过上限时仍拒绝使用旧位置启动。
同一源码事件被分屏观察时只处理一次。没有断点的文件不发送请求，位置没有变化时
不发布新 store，避免每次输入都向调试器重新同步。

快速输入的请求串行执行，最多保留 128 次编辑。超限或 Core 失败时，保留用户状态并阻止
使用旧位置启动，提示清除断点后重设。清除会递增存储
代次，使尚未返回的旧结果失效；其他文件的断点不会被结果覆盖。

正确做法：等待更新结束，再从 store 获取断点并发送一基的 DAP（调试适配器协议）行号。
不要这样做：保存启动按钮闭包里的旧数组，或只读取图标移动后的位置作为存储真源。

## 考虑过的备选方案

- 让 Monaco 图标位置成为断点真源：依赖视图是否存在，未打开文件和重新启动无法保持一致。
- Windows 自行按插入和删除行数移动：无法完整复用 Core 的字符锚点和碰撞处理，形成两套算法。
- 并行发送每次编辑并只取最后结果：后一次请求可能从尚未更新的旧断点计算，丢掉连续编辑。

## 后果

普通调试配置和 Java 调试均在启动前等待同一屏障，编辑、持久化、重绘和发送使用一致位置。
调试页重新读取存储可能创建与原断点值相同的新对象；提交迁移时按完整断点内容比较，
不会仅因对象引用变化就判为并发修改。真正变化的断点仍拒绝被旧结果覆盖。
每次编辑只迁移发生该编辑时已经存在的断点；之后新建的断点已经使用新文档行号。
Core 返回碰撞后保留下来的输入序号，Windows 据此保留断点身份。原生请求期间断点发生
修改时，使用原编辑和最新断点状态有限重试，不把过时结果覆盖到用户刚才的操作上。
多个等待中的编辑可以共用一次 Core 请求，多光标编辑仍保留自己的边界。
精确范围只增加原生编辑元数据，文本引用复用已有映射，不增加完整文档镜像。
外部重新载入不当作用户编辑回放；真实适配器停住位置和完整界面验收仍需目标平台验证。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- `node scripts/i18n/generate-i18n.mjs --check`
- `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs --check`
- `node scripts/agent-notes/verify-agent-notes.mjs`

设置 `LITHE_CORE_TEST_LIBRARY` 为本地构建的 Core 动态库可运行显式原生集成测试。
共享样例覆盖插入、删除、中文、emoji、CRLF、禁用断点和位置合并，并检查发送的 DAP 行号。
并发测试使用可控 Promise 验证快速输入、清除、分屏去重和启动屏障，不使用计时睡眠。

## 适用范围

- `frontend/editor/src/source-text.ts`
- `frontend/editor/src/model-source.ts`
- `windows/tauri/src/features/editor/components/monaco-editor.tsx`
- `windows/tauri/src/features/debugger/services/breakpoint-relocation.ts`
- `windows/tauri/src/features/debugger/stores/debugger.store.ts`
- `windows/tauri/src/features/debugger/services/debug-adapter-service.ts`
