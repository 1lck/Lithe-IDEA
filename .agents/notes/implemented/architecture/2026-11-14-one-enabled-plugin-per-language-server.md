# Agent 笔记：同一语言只由一个已启用插件提供语言服务器

状态：已实现

## 先说结论

Java 现在有两个插件：Java Support（JDT LS，补全、诊断、运行、调试都有，安装包约 250 MiB）和 Java Navigation（不依赖 JDT，只做跳转、引用和文档结构，安装包约 1 MiB）。两个都为 `java` 声明了语言服务器，同时启用时宿主会静默选中其中一个，另一个形同失效。现在规定：同一语言只由一个已启用插件提供语言服务器。启用或安装其中一个，另一个会被自动停用，宿主告诉用户停用了谁、为什么。两个插件作为同一语言的“完整版”和“轻量版”二选一，不分工合作。

## 问题

- Core 的清单校验只禁止**同一个插件**为一门语言声明两个语言服务器，对不同插件之间没有任何规则。
- Viva 宿主的 `pluginservice.Service.LanguageServerProvider` 按已安装插件的顺序取第一个声明了该语言服务器的已启用插件，不报错也不提示。按 ID 排序时 Java Navigation 排在前面，装上它会让 Java Support 的 JDT 根本不启动，补全、诊断消失，调试一直等 JDT 就绪。
- Java Navigation 的 README 只能写“暂时不要同时启用”，用户在界面上看不到这句话。

## 决策

规则放在 Core 的 `plugins.installed.lifecycle`（`rust/crates/plugin-lifecycle`，Lithe-core-rust#39），因为“哪个插件启用”本来就由它回答；宿主只提供事实、执行步骤。

- **宿主提供事实**：`pluginmanager.Manager` 规划时，为每个已安装版本读出清单 `languageServers[].languageID`，作为 `installed[].languageServers` 交给 Core。读不到或解析失败的清单按“不提供语言服务器”处理，因为那个版本的服务器本来也启动不了，启动和注册语言的路径会报告这次失败。
- **Core 决定谁让位**：只看每个插件**最新安装版本**的语言服务器。用户启用插件 Y，或确认安装后 Y 处于启用状态时，其他已启用、与 Y 共享语言的插件 X 各得到一步 `displacePlugin { pluginID, languageIDs }`。停用不顶替任何插件，所以停用 Y 后，X 原来的启用选择会自然接手。
- **规则之前的旧状态**：用户以前把两个都启用了，Core 报告启用状态时按 ID 只保留第一个，选择本身不改；用户再启用其中一个时，用 `displacePlugin` 定下来。
- **宿主执行步骤**（`workbench/plugin_displace.go`）：`Manager.Apply` 先把 X 记为停用；工作台回到窗口线程用 `detachPluginServer` 把 X 的服务器移出登记表，再在后台用 `pluginservice.Service.StopDisplaced` 停掉 X 的语言服务器和后端；停完后，如果项目里打开着共享语言的文档，就为它启动 Y 的服务器。同时用 `desktop.marketplace.languageServerDisplaced` 提示“已停用「X」：「Y」也提供 Java 语言服务器……”。

正确做法：新语言插件想做“轻量版 + 完整版”，两个插件都正常声明同一语言的 `languageServers`，由用户二选一。

不要这样做：在宿主里按插件 ID 或语言名写“Java Navigation 让位给 Java Support”之类的特判；也不要让完整版去掉自己的跳转、期望轻量版补上，现有契约下一门语言的所有 LSP 请求只发给一个插件。

## 考虑过的备选方案

1. **同一语言同时跑多个服务器，按请求类型分配**（跳转给轻量版、补全给完整版）：需要新契约，还要定义结果冲突、就绪前后切换的规则；而且 JDT 建好语义模型后跳转几乎不额外花资源，分出去省不了内存。现在不做。
2. **启用第二个时直接拒绝，让用户先手动停用另一个**：多一步操作，用户要自己弄明白两个插件为什么冲突。改为自动停用并提示。
3. **在清单里写 `conflicts: [插件 ID]`**：要求插件作者互相知道对方，第三方插件做同一语言时又会漏掉。按语言服务器声明自动判断更通用。
4. **把 Java Navigation 并进 Java Support**：轻量用户就得下载 250 MiB 的 JDT 和 JDK。两个插件分开上架、二选一更合适；以后可以把轻量引擎打进 Java Support，作为 JDT 就绪前的快速层。

## 后果

- 用户不会再遇到两个 Java 插件互相抢、其中一个静默失效的情况；切换时有明确提示。
- 启用一个插件可能改变另一个插件的启用状态，这是用户可见的副作用，所以必须提示。
- 每次规划启停都要读取已安装插件的清单，有界（单个清单最多 8 MiB，通常只有几 KB）。
- 旧状态按 ID 选出的那个不一定是用户想要的，用户再启用另一个即可，不会丢选择。
- 尚未在原生窗口和 Windows 上验证。

## 验证

- Core 仓库 `cargo test -p lithe-core --lib shared_plugin_lifecycle_fixture`：`rust/fixtures/plugins/installed-lifecycle.json` 覆盖启用、确认安装、更新后新增语言、禁用插件的更新、只看最新版本、旧状态、反向启用和停用接手。
- `scripts/desktop/desktop-go.sh test ./internal/pluginmanager -run 'TestEnable|TestEarlierChoices|TestUnreadableManifest' -count=1`（需要链接包含 Lithe-core-rust#39 的 Core）：顶替记录与报告、确认安装顶替、旧状态只启用一个且停用后接手、清单损坏不影响其他插件。

## 适用范围

Viva 客户端（`desktop/`）的插件启用与安装：Core 的 `plugins.installed.lifecycle`、`desktop/internal/core/plugin_lifecycle.go`、`desktop/internal/pluginmanager/`、`desktop/internal/pluginservice/lifecycle.go`、`desktop/internal/workbench/plugins.go`、`desktop/internal/workbench/plugin_displace.go`。启用、禁用、卸载的其余规则见[Viva 确认安装即启用插件，卸载先停进程再清理状态目录](../bug-fix/2026-11-13-viva-plugin-install-enables-and-uninstall-cleans-state.md)。
