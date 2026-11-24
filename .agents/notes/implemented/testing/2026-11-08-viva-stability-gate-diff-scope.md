# Agent 笔记：迁移期间测试稳定性门禁的差异范围

状态：已实现

## 先说结论

测试稳定性门禁只读取 Rust 源码及当前桌面 Go 测试文件的差异；Rust 应用既有规则，
Go 只用于明确报告尚未覆盖，不能被解释为静态检查通过。旧客户端的 Swift 和
TypeScript 规则与路径分类已退役。
被删除的大量无关文件不再撑满 Git 输出缓冲；被删除的测试文件仍参与迁移代码的
既有违规匹配，不改变保留的 Rust 规则或放宽违规判断。

## 问题

Viva 迁移相对旧基线删除了大量客户端和内核源文件。此前门禁先获取完整差异，
再按语言筛选，超过 64 MiB 的 Git 子进程输出上限而报 `ENOBUFS`，无法开始检查。

## 决策

在 Git 差异阶段使用与语言识别一致的路径过滤；仍保留删除文件，保证已移动
测试的旧违规只能按原有规则抵扣，新增违规不能被误认作存量。
当前 `desktop/` 的 Go 测试进入覆盖报告，但不参与 Rust 规则或旧违规抵扣。
平台参数不再通过已删除的客户端目录推断覆盖：共用的 Rust 规则和 Go 未覆盖
提示在 macOS、Windows 上一致，目标平台的计时、竞态与原生验证仍需分别执行。

## 考虑过的备选方案

只扩大缓冲仍会读取所有无关差异，在更大的迁移中继续增长；过滤未扫描的文件
可以保持原有有界缓冲，也不改变被检查的文件。

## 后果

若以后新增扫描语言或测试文件命名规则，必须同步扩展 Git 路径过滤，并用
真实仓库夹具验证；否则新增语言的差异不会进入门禁。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --base origin/main`：只读取 Rust 与当前桌面 Go 测试文件的差异；相对基线的相关差异仍在原有有界缓冲内。没有适用的 Rust 源码时输出 `N/A`，Go 改动另列为未覆盖。
- 工具自检覆盖超过 64 MiB 的无关差异和 Rust 测试移动夹具，用真实 Git 仓库验证过滤。自检不依赖任何具体 CI 工作流文件。

## 适用范围

- `.agents/skills/write-stable-tests/scripts/verify-test-stability.mjs`
- `.agents/skills/write-stable-tests/scripts/test-verify-test-stability.mjs`
