# Issue #561：初始诊断与完整应用复现报告

关联：[原始问题 #561](https://github.com/1lck/Lithe-IDEA/issues/561) · [修复 PR #621](https://github.com/1lck/Lithe-IDEA/pull/621)

这里归档正式修复前的两份完整报告，以及支撑报告数值的测量数据。它们保留当时的结论、实验条件和限制，用于说明如何从“是否只染色可见区域”的疑问，逐步定位到 Java 全文语义着色、重复全文排版和折叠箭头的二次遍历。

## 阅读顺序

| 阶段 | 报告 | 测量范围 | 对应数据 |
| --- | --- | --- | --- |
| 1：最初的原生操作诊断 | [01-native-diagnostic.md](01-native-diagnostic.md) | 8329 行、271949 字节；独立 AppKit 文本操作，无完整 IDE、无 LSP | [原始 30 次测量](native-results.json)、[环境与 Rust 调用记录](native-metadata.json) |
| 2：完整产品复现与单变量验证 | [02-product-reproduction.md](02-product-reproduction.md) | 8329 行、457728 字节；完整 Release 应用，打开、三次编辑及 26 次滚动，包含真实 JDT LS 对照 | [全部 11 轮统计](product-reproduction-summary.json) |
| 3：正式修复与复测 | [PR #621 的正式复测、回归和验证边界](https://github.com/1lck/Lithe-IDEA/pull/621) | 正式视口缓存、折叠布局复用和可见行绘制实现；含超时对照及语义颜色校验 | PR 说明中的结果表及验证记录 |

## 归档口径

- 两份报告沿用原始正文，仅增加历史阶段说明；第二份报告将本机源码链接替换为已核对的固定版本链接。
- `native-results.json` 和 `product-reproduction-summary.json` 与初始诊断归档逐字节一致。`native-metadata.json` 的 `binary` 字段将本机绝对路径改为仓库相对路径，其余数据不变。
- 第一阶段原生操作计时不能解释为产品交互延迟；第二阶段的实验性视口过滤也不能解释为正式修复已经完整处理了滚动补色。后续修复结果单独记录在 PR 中。
- 第二阶段 JSON 保留探索轮和主对照轮。报告的主比较采用第二版探针的两轮 `baseline-lsp0-2/3`、两轮 `gutter-lsp0-1/2`、两轮 `all-lsp0-1/2`，以及各一轮开启 LSP 的对照；没有把第一版探索轮混入同一主统计组。JSON 中的 `null` 表示未采集到该项数据，不表示零耗时。
- 本次提交的是报告和支撑数值的数据文件。原报告列出的完整本地诊断目录还包含运行探针、输入文件、JSONL、进程采样和日志；二进制、应用包、缓存和这些本地运行材料未随文提交。
