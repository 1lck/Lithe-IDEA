# Agent 笔记：Windows 设置分层与 macOS 表单布局

状态：已实现

## 先说结论

Windows 设置改为与 macOS 相同的分类树、搜索、面包屑和标题分组线。页面继续调用已有 Windows 功能，不新增另一套设置存储或跨平台 UI 实现。普通设置即时生效；底部左侧保留恢复默认，右侧只提供“关闭”，关闭时丢弃页面尚未提交的草稿，不回滚已经保存的设置。

## 问题

macOS 的 `SettingsView` 已有五个可折叠分组、顶层页面和本地化搜索，Windows 却将所有页面平铺，并混用卡片分组与两套设置行。仅按截图增加取消按钮还容易误以为所有设置都需要等确认才写入，改变实际产品行为。

## 决策

以 `macos/Sources/Lithe/Views/App/SettingsView.swift`、`SettingsSearchVocabulary.swift` 和前者内部的 `SettingsViewState` 类为依据。macOS 普通设置绑定直接写入；只有插件启用状态由 `pendingPluginEnabledStates` 暂存，并在确认时应用，不能将插件事务推广到全部设置。

Windows 的 `settings-navigation.ts` 集中定义可见分层和检索词。对应关系如下：

| 层级 | Windows 页面 |
| --- | --- |
| 外观与行为 | 通用、更新 |
| 顶层页面 | 快捷键、编辑器、插件、MCP 配置 |
| 版本控制 | Git |
| 构建、执行、部署 | 项目环境、运行配置、Maven |
| 语言与框架 | LSP |
| 工具 | 终端、AI 聊天与编辑、AI 与提交、日志 |

保留 Windows 的 Maven、AI 聊天和日志入口。macOS 的 AI Providers 相关选项在 Windows 已由 AI 页面和 AI 提交配置负责，不增加重复的服务商设置页。插件页复用已有 `ExtensionsSidebar`，按需加载，不复制安装、市场、启用和详情逻辑；其操作仍即时生效，与 macOS 的插件草稿确认不同。

Windows 底部使用单个次要样式的“关闭”按钮。普通设置和插件操作已即时生效，项目、运行和 Maven 配置由页面内的显式保存动作负责；保留同样只关闭窗口的取消和确定会让用户误以为存在统一提交或回滚。因此不照搬 macOS 的插件确认按钮，也不让关闭替代页面保存。

搜索词表只收录当前实际页面的字段，不复用旧页面索引，避免粘滞滚动、界面字体大小等不存在的控件产生误命中。无论当前界面语言如何，都匹配已发布的中英文文案和英文关键词。搜索时展开所有命中分组；当前页面不匹配时切换至首个结果，无结果时两侧显示空态。页面首次访问时才挂载，切换分类或显示搜索空态只隐藏已访问页面，因此未保存的项目 JDK、Maven 等草稿在自动搜索跳转、手动导航和外部分类请求后仍保留；关闭设置时统一卸载并丢弃未提交草稿。外部分类请求清空搜索、展开父组；重复请求同一页仍由 `settingsTabRequest` 触发。不要为建立索引而预先挂载其他页面，避免后台操作和设置副作用。已访问页面的订阅及异步操作由页面继续持有，到关闭设置时按既有清理逻辑释放；隐藏不能触发保存，也不另建持久化草稿存储。插件设置页挂载时保留全局搜索焦点，只有独立扩展管理入口自动聚焦插件搜索框。

Windows 设置组件使用 `settings-panels.tsx`、`SettingsPanel` 和 `SettingsCategory`。macOS 是布局和行为参考，不是这些 React 组件的平台归属；目录已经表达 Windows 平台，不再用 `macos-` 或 `Mac` 前缀。

共用设置文案以 macOS 的实际设置页面和 `macos/Resources/zh-Hans.lproj/Localizable.strings` 为依据，中英文同步核对。Windows 统一使用“通用”“字体”“编辑器标签栏”“多行展开”“Tab 宽度”“显示引用数量和 Git 作者”“搁置”“Git Stash”“服务商”和“API 密钥或 Token”；英文快捷键分类为 `Keymap`。全局搜索、快捷键搜索、无结果和更新检查提示也使用对应的 macOS 文案，命令面板的设置入口保持一致。

相同英文词在 macOS 全局字典中可能属于不同功能，不能按字符串相同直接批量覆盖。例如 AI 的 `Provider` 应为“服务商”，不能采用语言检测的“识别器”；Windows 项目 `Attach` 是“附加”，不能采用调试连接的译文。项目附加、Windows 凭据管理器和页面内显式保存说明继续描述实际 Windows 功能。只调整本地化展示，保留设置键、存储值和保存时机；底部仍为单个“关闭”。

外观模式选择“跟随系统”时，原生窗口通过 `set_native_window_appearance` 的 `system` 值调用 Tauri `set_theme(None)`，解除手动明暗覆盖。Windows 的 Tauri 窗口主题事件会同步 WebView2 的颜色偏好；如果每次应用主题都调用 `set_theme(Some(...))`，系统外观变化就不能继续驱动窗口和 WebView，前端 `prefers-color-scheme` 读到的也是固定模式。继续复用既有媒体查询监听更新页面与编辑器，不添加轮询或另一套系统主题来源。手动模式移除同步监听并固定指定外观；通用设置中的主题选项显示实际生效的主题，明暗判断使用主题元数据，不依赖主题名称是否包含 light。

设置窗口采用 900×700 的桌面布局，并受视口大小限制。分类栏初始宽度为 234px；视口宽度超过 768px 时最小宽度仍为 234px，较窄时降为 180px，正文始终保留至少 500px。断点包含弹窗两侧留白、边框和分隔线，使 Windows 允许的 720px 最小窗口也能容纳两栏；分类名通过省略号保持单行。使用媒体查询只在跨越断点时更新局部布局状态，关闭设置时释放监听，不在每次拖动时重建业务页面。复用 `ResizablePanelGroup` 和其 `useDefaultLayout`，拖动结束才写入布局存储，连续拖动不更新设置业务状态；分隔线保持原色，仅显示调整光标。

插件页通过 `ExtensionsBrowserLayout` 的设置模式保留列表与详情两栏，列表初始 230px、最小 200px，详情最小 160px。它不使用主窗口的屏幕宽度断点隐藏详情，布局与分类栏分别保存；普通扩展管理入口继续使用原网格布局。

所有普通分组复用 `settings-section.tsx`：标题后跟水平线，第一组标题也可见；行标签和控件靠左，说明占下一行，窄内容区允许换行。保留行点击激活、重置、搜索定位和无障碍命名。下拉、输入、分段选择与步进器继续使用已有共享控件，不按页面重画表面。列表、编辑器和插件详情保持各自业务布局。

正确做法是将新页面加入分类目录并补充实际字段的中英文检索词，继续调用原功能的保存动作。不要为取消按钮创建全局设置快照并覆盖新值，也不要把项目和运行配置的显式保存改为输入时保存。

## 考虑过的备选方案

只调整平铺导航的颜色无法表达 macOS 的分层。逐页复制 macOS 的数据模型会重复 Windows 的功能与存储。为所有设置引入确认事务则会改变主题、字号和语言即时生效的行为，也与 macOS 普通设置的实现不同，因此只统一导航和共享表单布局。搜索导航不通过自动保存草稿来避免丢失，也不新增 dirty 提示阻断搜索；采用窗口生命周期内的按需挂载，复用页面已有草稿和显式保存逻辑。所有页面预挂载会启动未访问页面的工作，离开页面即卸载则丢失草稿，两者均不采用。

## 后果

两端的设置导航和普通表单结构一致，Windows 现有能力仍可直接访问。插件操作的提交时机仍存在平台差异；macOS 专有能力不会因增加导航而自动具备 Windows 实现。浏览器组件探针能证明布局和交互，但不能替代真实 WebView2、插件安装及重启持久化验证。

## 验证

- `scripts/build-windows.ps1 -Configuration Release` 验证类型、前端和 Windows 构建。
- `.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1` 与 `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend` 检查测试稳定性并生成计时报告。
- `windows/tauri/src/features/settings/components/settings-hierarchy.test.tsx` 覆盖两种界面语言下的中英文字段检索、不可见字段排除、折叠组搜索、无结果、重复外部请求、面包屑和 Esc 清空查询，并验证无结果搜索、命中后的自动跳转、手动切换和外部导航均保留项目与 Maven 草稿，关闭后清除且释放页面资源。这些交互不能由类型检查证明。
- `windows/tauri/src/extensions/ui/components/extensions-sidebar-focus.test.tsx` 挂载真实插件浏览器，验证设置模式保留全局搜索焦点、独立入口仍自动聚焦；原生发现和市场请求使用立即完成的测试替身，不访问网络。分层、主题、下拉控件、更新状态和插件焦点回归分别以独立进程接入 Windows CI（持续集成）。
- 编辑器路由测试验证字号即时写入，关闭不会回滚；快捷键测试准确定位页面内搜索，避免与新全局搜索混淆。
- 核对共用中英文标签及说明与 macOS 设置语境一致，保留变量占位符；检查命令入口、搜索匹配和无障碍名称使用同一文案。Windows 专有说明按实际功能验收。
- `windows/tauri/src/features/settings/lib/settings-theme-sync.test.ts` 用受控媒体查询和原生接口模拟验证手动浅色切回系统深色、系统明暗变化、重复启用不重复监听，以及手动模式清理监听。真实 Windows 另验证浅色 → 跟随系统立即恢复当前系统模式；系统变化由既有窗口事件与 WebView2 媒体查询传递。
- `scripts/verify-windows-boundaries.sh`、`scripts/verify-platform-feature-matrix.sh` 和 `scripts/verify-agent-notes.sh` 验证边界及记录。
- 深浅色检查分类、下拉菜单、字体检索、外部关闭、Esc 和底部按钮；连续拖动时确认存储不变，松开后保存，重开恢复宽度；分别以 720px、768px、769px 和 800px 视口检查正文至少 500px、弹窗无水平溢出及底部按钮可用，再从已保存的宽布局缩至最小窗口。

## 适用范围

- `macos/Sources/Lithe/Views/App/SettingsView.swift`（行为参考，未改动）
- `windows/tauri/src/features/settings/lib/settings-navigation.ts`
- `windows/tauri/src/features/settings/components/settings-dialog.tsx`
- `windows/tauri/src/features/settings/components/settings-section.tsx`
- `windows/tauri/src/features/settings/components/settings-panels.tsx`
- `windows/tauri/src/i18n/locale.ts`
- `windows/tauri/src/i18n/ai-commit.ts`
- `windows/tauri/src/features/settings/lib/settings-effects.ts`
- `windows/tauri/src/features/settings/lib/theme-resolution.ts`
- `windows/tauri/src/features/settings/lib/settings-theme-sync.test.ts`
- `windows/tauri/src-tauri/src/host.rs`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`（文案参考，未改动）
- `windows/tauri/src/extensions/ui/components/extensions-sidebar.tsx`（复用既有插件能力）
- `windows/tauri/src/extensions/ui/components/extensions-browser-layout.tsx`
