# Agent 笔记：迁移期间测试稳定性门禁的差异范围

状态：已实现

## 先说结论

测试稳定性门禁只读取它会分析的 Rust、Swift 测试及 TypeScript 测试文件的差异。
被删除的大量无关文件不再撑满 Git 输出缓冲；被删除的测试文件仍参与迁移代码的
既有违规匹配，不改变扫描规则或放宽门禁。

## 问题

Viva 迁移相对旧基线删除了大量客户端和内核源文件。此前门禁先获取完整差异，
再按语言筛选，超过 64 MiB 的 Git 子进程输出上限而报 `ENOBUFS`，无法开始检查。

## 决策

在 Git 差异阶段使用与语言识别一致的路径过滤；仍保留删除文件，保证已移动
测试的旧违规只能按原有规则抵扣，新增违规不能被误认作存量。

## 考虑过的备选方案

只扩大缓冲仍会读取所有无关差异，在更大的迁移中继续增长；过滤未扫描的文件
可以保持原有有界缓冲，也不改变被检查的文件。

## 后果

若以后新增扫描语言或测试文件命名规则，必须同步扩展 Git 路径过滤，并用
真实仓库夹具验证；否则新增语言的差异不会进入门禁。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --base origin/main`：只读取 Rust、Swift 与 TypeScript 测试文件的差异；相对基线的相关差异仍在原有有界缓冲内。
- 工具自检覆盖超过 64 MiB 的无关差异和 Rust 测试移动夹具，用真实 Git 仓库验证过滤。自检不依赖任何具体 CI 工作流文件。

## 适用范围

- `.agents/skills/write-stable-tests/scripts/verify-test-stability.mjs`
- `.agents/skills/write-stable-tests/scripts/test-verify-test-stability.mjs`
