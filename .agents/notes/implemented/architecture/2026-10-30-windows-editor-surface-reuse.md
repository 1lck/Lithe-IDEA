# Agent 笔记：Windows 编辑器表面复用与标签上限

状态：已实现

## 先说结论

Windows 每个窗格最多保留 8 个已挂载的编辑器表面（surface，一个 Monaco 编辑器实例及其 DOM）。打开第 9 个文件时不再销毁并新建编辑器，而是把最久未用的表面改绑到新文件，只切换模型（model，Monaco 里保存一个文件文本的对象）。

这样打开文件省掉了建编辑器的成本，代价是组件不再随文件重建：凡是属于某个文件的状态，都必须在模型绑定的 effect 里建立和清理。标签上限是另一件事：它决定标签栏里留多少标签，默认 30，全部逻辑只有一份，在 `buffer-eviction.ts`。

## 问题

打开文件时，建编辑器的成本是 70～100 毫秒，还要运行全部 Monaco 贡献点（contribution）。隐藏的标签也会拖慢其他操作：WebView2 给 `visibility: hidden` 的 Monaco 树重算样式比可见时慢很多，在隐藏标签旁打开文件要多花 100～250 毫秒。

标签上限当时有两份实现，而且都不完整：

- `buffer.store.ts` 的淘汰路径用的是 store 里的 `maxOpenTabs` 副本。这个副本取自默认值，设置页改动从来同步不到，所以用户设的上限和策略都不生效，0 也不代表不限。
- `tab-bar.tsx` 的 effect 读真实设置，但只排除已固定、未保存和当前标签，不排除终端和 Agent 标签。默认值是 100 时几乎碰不到，默认值降低后，打开新标签就可能关掉用户的终端。

## 决策

### 编辑器表面

`pane-container.tsx` 用 `assignEditorSurfaceKeys` 给挂载中的文件分配稳定的 surface key，离开挂载集合的文件把 key 让给下一个文件。React 因此保留同一个组件实例，`MonacoEditor` 只执行一次 `monacoEditor.create`。

开发者要按这个规则放代码：

- 编辑器级的处理函数放在创建 effect 里，通过 `modelBindingRef` 或 `editorCallbacksRef` 读取当前文件。
- 模型级的东西放在模型 effect 里，随文件建立和清理，包括内容监听、跳转手势、Git gutter、调试装饰和打开的菜单。
- 读 `modelRef` 的 effect 不能只依赖文件相关的值。文件文本还在恢复时 `isContentReady` 为 false，此时没有模型，所以依赖里要带上它，否则模型绑定后这个 effect 不会重跑。诊断标记和 Vim 适配器都因此依赖 `isContentReady`。
- 新增按文件保存的 `useState` 时，要在模型 effect 的清理函数里重置。

不要这样做：在创建 effect 里直接闭包读取 `filePath`、`editorBufferId`，这些值在第一次切换文件后就过期了。

### 隐藏标签

隐藏的表面用 `content-visibility: hidden` 加 `visibility: hidden`。前者跳过内容的样式和布局，并保留缓存的尺寸，所以 Monaco 不会被缩成 0；后者防止空槽位接收点击。

隐藏表面仍然挂着模型，Monaco 会照常向提供方请求数据。`surface-visibility.ts` 记录每个模型的可见情况，CodeLens 和语义高亮对只被隐藏表面显示的模型跳过请求，显示时再刷新一次。语义高亮靠抛出含 `busy` 的错误保留现有 token，这是 Monaco 0.55 `documentSemanticTokens` 的既有行为，升级 Monaco 时要复查。

### 标签上限

`selectBuffersOverTabLimit` 是唯一的选择逻辑，打开新标签时由 store 调用，调低上限或恢复会话后由标签栏调用。store 直接读取设置，不再保存副本。

规则是：上限只计算可以自动关闭的标签；已固定、有未保存修改的标签，以及终端、Agent、外部编辑器、网页查看器和单例工具标签，既不计数也不关闭；0 表示不限制。

### 默认值

默认值定为 30。表面复用之后，标签数已经不是性能问题：用 `fileOpen` 同样的固定工程（每个文件几十行）测量，打开新文件的耗时在 8、20、30、40 个标签时分别约为 40、42、44、49 毫秒，每多一个标签约增加 0.2MB 堆内存。复用之前这组数字是 72、92、105、119 毫秒。

既然上限不再用来换性能，它就只是在“标签栏可控”和“不要替用户关文件”之间取舍。IDEA 默认的 10 在 Java 工程里偏紧，跳转几次定义就会把刚看的文件挤掉；100 基本等于不限制。30 比 20 只多约 2 毫秒和 2MB，却能明显减少自动关闭；到 40 时耗时开始上升。实际文件更大时内存会相应增加，这也是保留上限的原因。

`settings.json` 在首次启动时写入全部默认值，所以这个默认值只影响新安装。已有用户保存的 100 不会被改写，因为无法区分它是旧默认值还是用户的选择。

## 考虑过的备选方案

- 只把默认值改小，不合并两份实现：会让设置继续失效，并开始关闭终端和 Agent 标签，所以不采用。
- 把淘汰逻辑全部放到标签栏：标签栏未挂载时就没有上限，而且关闭发生在渲染之后，所以打开时的淘汰仍留在 store。
- 只保留 `visibility: hidden` 或卸载隐藏标签：前者样式成本高，后者每次切回都要重建编辑器。
- 挂载更多表面：内存随表面数线性增长，8 个已能覆盖常见的来回切换。

## 后果

- 文件切换不再重建组件，遗漏重置的按文件状态会带到下一个文件，审查 `monaco-editor.tsx` 时要专门检查。
- 超过 8 个标签后切回未挂载的文件仍要绑定模型，但不再新建编辑器。越过挂载上限打开文件从约 94 毫秒降到约 42 毫秒。
- 切回已挂载标签的中位耗时从约 7 毫秒变成约 13 毫秒，因为不再在提交阶段同步布局，要等下一帧；P95 都是 16 毫秒，仍在一帧之内。
- Monaco 的 `editor.addCommand` 不提供注销，处理函数会存活到进程结束。这里的处理函数不能捕获创建 effect 的作用域，否则每个销毁的编辑器都会被留在内存里，`leaks` 场景会把它测出来。
- 卸载时 React 先清理创建 effect，所以创建 effect 的清理函数要先调用模型清理，否则编辑器已销毁，视口状态存不下来。
- 标签上限对已有用户不产生变化，想要收敛的用户需要自己调低。
- macOS 目前没有标签上限，功能矩阵 `editor-tab-limit` 记录了这个差异。

## 验证

```bash
./scripts/agent-notes/verify-agent-notes.sh
node scripts/windows/perf/run-windows-perf.mjs --only tabs,fileOpen,leaks
```

Windows CI 的 `windows-file-open-performance` 和 `windows-file-drop-listeners` 覆盖淘汰规则、表面 key、模型位置解析、隐藏模型跳过和日志批量发送。`fileOpen` 场景测量越过挂载上限后的打开耗时。

## 适用范围

适用于 `windows/tauri` 的编辑器窗格、标签栏和相关设置。macOS 使用原生编辑器结构，不受本笔记约束。
