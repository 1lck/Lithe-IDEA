# Agent 笔记：Viva 插件后端的 Core 会话桥接基础

状态：已实现

## 先说结论

Viva 的 Core 适配层可以校验插件声明、取得 Core 生成的后端启动计划，并通过 Core 管理的会话调用插件函数。该适配层和测试不等于完整插件宿主：可信安装、已安装插件发现、授权服务分发、用户入口和宿主会话编排尚未接通。

## 问题

插件清单中的权限、启动参数和函数归属必须遵循共享契约。Core 已拥有进程、协议协商、请求 ID、事件和强制退出；在 Go 中重新实现这些规则会形成互相竞争的两套状态机。

## 决策

宿主将真实实现的能力表交给 `plugins.declarative.validate`；缺失能力时拒绝声明。`plugins.declarative.languageServerLaunchPlan` 的 `backend: true` 选择器返回启动信息、需要的包路径和主机服务。计划只是描述，不证明包来源、签名或程序已被批准；将来调用者必须先验证来源和批准记录、限定包内路径，并且只授予实际实现的宿主服务。

后端以 `lsp.startServer` 启动，函数通过 `lsp.functionRequest` 调用，结果和进度从 `lsp.waitEvents` 收取；宿主可提前指定 operationId 以登记接收者，避免结果早于注册。Core 转发的宿主请求可用 `lsp.hostResponse` 回复；这个接口本身不提供凭据或其他宿主服务，生产端必须先实现并授权对应处理器。取消经 Core 的 `lsp.cancelOperation`，不重新实现 JSON-RPC。`lsp.stopServer` 发起异步关闭，终态后才能 `lsp.destroyServer`；宿主应在有界等待后核实释放，失败不得丢弃会话身份。

固定 Core 已更新到 [Lithe-core-rust #2](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/2)：
`languages` 3 使用 TextMate，旧的 Monarch `languages` 2 被 Core 拒绝。共享契约和
fixture 随固定修订更新，Core 桥接测试验证了声明和语法解码；`DecodePluginGrammar` 只返回
Core 校验后的语言、原始语法与配置，不读取插件文件、认证包或注册编辑器。测试中传入的能力表不是
生产宿主的能力声明。Viva 尚未完成插件语法的发现、可信安装和编辑器注册，不能仅因 Core
支持就宣称该插件功能已可用。契约变化和协议更新记录在 Core 的同一个 PR 里登记；桌面端 Go
测试通过 `LITHE_PLUGIN_CONTRACT_DIR` 读取正在链接的那个 Core 检出里的契约，没有需要另行同步的契约副本。

## 考虑过的备选方案

- 在 Go 再写一套协议、进程和权限路由，会与 Core 的会话及取消状态重复，故不采用。
- 把可解析的能力全部宣称为宿主能力，会让市场提供目前无法运行的包，故测试中的能力表只作为测试输入，不用于生产声明。
- 只检查市场的下载摘要就执行插件，会把索引匹配误称发布者认证，故该桥接层不承担安装和信任决定。

## 后果

适配层为后续真实插件宿主提供调用入口，但目前没有生产路径启动插件；市场仍显示安装不可用。支持协议中的 hostRequest、进度界面、超时和关闭项目的完整产品编排，以及 Windows 实机验收，都仍需完成。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run '^TestPluginBackend' -count=3`：共享清单、能力缺失拒绝、Core 启动计划、真实 Core 与测试进程协商和函数调用、受控测试请求的宿主回复及重复回复拒绝、跨插件归属拒绝、取消、迟到回复与 operationId 复用、终态后销毁。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run '^TestPluginTextMateGrammarUsesPinnedCore$' -count=2`：macOS 上验证新契约的声明、Core 校验、原文与 scope 交给 TextMate 解析、无效输入和旧版拒绝；Windows 尚待重跑。
- 测试进程是当前 Go 测试二进制，不是已安装或受信任插件；测试后核对没有对应子进程残留。这不是插件市场安装或完整宿主验收。

## 适用范围

- `desktop/internal/core/plugin_session.go`
- `desktop/internal/core/plugin_session_test.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
