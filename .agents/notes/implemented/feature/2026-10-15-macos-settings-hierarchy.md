# Agent 笔记：macOS 设置分类归属规则

状态：已实现

## 先说结论

macOS 设置侧栏现在只有七个一级入口：外观与行为、插件、版本控制、构建/执行/部署、语言与框架、工具、AI。每个设置页必须属于其中一个分组，分组与页面的对应关系只写在 `SettingsGroup` 一处，侧栏、面包屑和“打开设置时展开所属分组”都从它推导。新增设置页前先按下面的归属规则选分组，不要再加一级入口。

## 问题

原来的侧栏把“快捷键”“编辑器”“MCP 配置”做成一级入口，AI 相关页面又散在“工具”下。分组关系同时写在三个 `switch` 里（侧栏、展开逻辑、面包屑），新增页面很容易只改一处，出现“侧栏在 A 组、面包屑写 B 组”的不一致。仓库里也没有一条规则说明新页面该放哪里，每次都靠评审时口头约定。

## 决策

### 归属规则

| 分组 | 放什么 |
| --- | --- |
| 外观与行为 | 应用本身的外观、更新、编辑器显示与输入、快捷键，以及应用自身网络请求的代理设置 |
| 插件 | 插件的安装、启用和插件自带的选项；一级页面，不属于任何分组 |
| 版本控制 | Git、SVN 等版本控制系统的配置 |
| 构建、执行、部署 | 构建工具、项目 JDK、运行配置、服务运行，以及框架和构建工具注入的配置 |
| 语言与框架 | 语言服务（LSP）的开关，以及 Spring Boot 等框架的配置 |
| 工具 | 终端、日志与诊断（查看、目录、清理和诊断包导出）等通用工具；插件带来的专用工具（例如 `.http` 请求）可以放进对应工具页 |
| AI | 凡是和 AI 有关的都放这里：MCP、Skill、全局指令、AI 提交信息、Agents、AI 服务商 |

插件如果带来了新的设置，默认放进“插件”页；只有它新增的是上表中某个分组本来就该有的能力（例如新的版本控制系统）时，才放进那个分组。

“运行环境”和“环境来源”是构建分组的工具链通用框架页，位于旧项目页和运行配置前；工具名称、提供方及使用方来自贡献快照，不是给某个插件开的专用设置页。提供方自己的配置继续从插件页注入。当前页面只读，旧项目 JDK/Maven 页面保留到实际消费者迁移后再删除，完整进度见[工具链提案](../../proposed/architecture/2026-10-31-plugin-injected-toolchains.md)。

AI 分组内按“AI 服务商 → Agent 管理 → 指令 → 技能 → Hooks → MCP 配置 → AI 与提交”排列：先放基础配置，再放行为规则和扩展能力，最后放具体应用功能。顺序仍只在 `SettingsGroup.categories` 中声明，搜索过滤后的侧栏也沿用这一顺序。

### 二级折叠：AI › 资源库

AI 分组里，Agent 可加载的资源（指令、技能、Hooks、MCP 配置）收进可折叠的“资源库”，与 AI 服务商、Agents、AI 与提交并列。二级折叠由 `SettingsSubgroup` 声明，页面仍归父分组所有：`SettingsGroup.categories` 保持完整平铺列表，`SettingsGroup.entries` 决定侧栏行顺序，面包屑为“AI › 资源库 › 页面”，搜索命中或跳转到其中的页面时自动展开。只有同类资源达到三个以上页面时才新增二级折叠。Windows 目前没有指令、技能页，暂不引入此层级。

### 插件注册的页面

插件可以在清单里把设置和按钮放到“语言与框架 › <语言>”或“构建、执行、部署 › <构建系统>”。这些页面不是 `SettingsCategory` 的 case，而是由 `PluginSettingsRegistry` 从已启用插件的声明推导，跟在对应分组的静态页面后面；面包屑和搜索同样从注册结果推导。宿主不为任何具体语言或构建工具写专用页面，规则见 [插件设置的通用注册面与生效方式](../architecture/2026-10-21-plugin-settings-surfaces.md)。

### 开发者怎么做

- 新设置页：在 `SettingsCategory` 增加 case，把它加进 `SettingsGroup.categories`（或确实是插件管理这类一级页面时加进 `SettingsSidebarItem.layout`），补 `SettingsSearchVocabulary` 的检索词和中英文文案。不需要再改侧栏、展开逻辑和面包屑。
- 新分组：只有上表没有任何一行能容纳时才新增，并先更新本 Note。

### 页面宽度

设置页内容区随窗口宽度伸缩，页面不要再自带 `maxWidth: 900/860/760` 之类的上限，否则调大设置窗口后右侧出现空白条。需要限制宽度的是单个控件（输入框、选择器的固定宽度），不是整页。

### 不要这样做

- 不要把页面直接加到 `SettingsSidebarItem.layout` 来绕开分组；一级页面只留给插件。
- 不要在 `SettingsView` 里再写按页面分支的分组 `switch`，这正是本次删除的重复来源。
- 不要为某个语言或构建工具新增 `SettingsCategory`；让对应插件在清单里用 `page` 注册。

## 考虑过的备选方案

### 完整实现 Issue 中的三级树

Issue 希望“构建工具 → Maven”“服务运行”“框架支持”也有独立节点。目前没有对应的独立页面：JDK 与 Maven 同在“项目”页，服务运行对应“运行配置”页，也没有任何框架配置。为了凑树形结构拆页面或放空页会增加没有内容的入口，所以本次只落地已有页面的归属；这些页面出现时按上表归入对应分组即可。

### 把规则只写在 `AGENTS.md`

`AGENTS.md` 的约定是只放入口提醒、详细规则放 Note，避免多份规则漂移，所以 `AGENTS.md` 只留一条指向本 Note 的提醒。

## 后果

- 收益：一级入口从九个减少到七个，AI 相关页面集中；分组关系只有一个来源。
- 代价：“快捷键”“编辑器”“MCP 配置”“AI 提交”“Agents”“AI 服务商”的位置变了，老用户需要重新找一次。
- Windows 的分组已按同一规则同步，见 `2026-10-08-windows-settings-hierarchy.md`；Windows 没有独立的 AI 服务商页和 Agents 页，AI 分组只有 MCP 配置、AI 与提交、AI 聊天与编辑。

## 验证

- `SettingsSidebarLayoutTests` 保证每个页面恰好属于一个分组或是一级页面，并固定本表的分组内容与 AI 页面顺序。
- `SettingsSearchVocabularyTests` 保证每个页面仍能被检索到。
- `./scripts/macos/test/test-macos.sh --filter SettingsSidebarLayoutTests`。
- 实机查看设置窗口的侧栏、面包屑、搜索展开和从其他入口跳转到某一页时展开所属分组。

## 适用范围

- `macos/Sources/Lithe/Models/AppModel/AppModelSupportTypes.swift`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
- `macos/Sources/Lithe/Views/App/SettingsSearchVocabulary.swift`
- `macos/Sources/Lithe/Application/Features/PluginSettingsRegistry.swift`
- `macos/Tests/LitheTests/SettingsSidebarLayoutTests.swift`
- `windows/tauri/src/features/settings/lib/settings-navigation.ts`（Windows 同步）
