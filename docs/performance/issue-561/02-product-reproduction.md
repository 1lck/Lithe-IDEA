# Issue #561：完整 macOS 产品性能验证

> 归档说明：本报告记录 2026-09-11 正式修复之前的完整 macOS 应用复现。正文中的“当前行为”“未交付正式产品修复”和 31 个回归测试均指这一历史阶段；本报告的三项优化是定位瓶颈的实验，不等同于后来提交的正式实现。正式修复和后续复测见 [PR #621](https://github.com/1lck/Lithe-IDEA/pull/621)。
>
> 各轮统计已随文提交为 [product-reproduction-summary.json](product-reproduction-summary.json)。本次归档保留原有结论和全部实验数据，并把本机源码链接替换为经过行号核对的固定版本链接；该固定版本的对应代码与当时工作树一致。文中其余日志、探针和缓存清单记录的是当时的本地归档，并非本目录全部收录的文件。

## 结论

在本次合成文件复现中，持续卡顿的主要热点是行号栏的折叠箭头绘制。主线程采样、直接计时和保留全文语义着色的单变量对照相互印证。全文语义染色后反复强制全文排版是另一个独立的打开/编辑停顿来源。

本次只做验证，未交付正式产品修复。所有临时探针和行为开关已经从产品源码撤回，原文件（包括任务开始前已有的用户改动）已按 SHA-256 验证逐字节恢复。

## 实验环境

- 日期：2026-09-11；macOS 27.0，Apple Silicon。
- 当前工作树构建的完整 Release 产品；HEAD：6a1ae4d43f3e。工作树含任务开始前已有改动。
- 使用本机 Swift 6.3.3。仓库要求的 Swift 6.2 工具链符号链接失效，本次没有安装/切换工具链。
- 新构建并链接了 Rust Core，使用实际 CodeEditorView、CodeTextView、NSTextStorage、NSLayoutManager、行号栏和 SwiftUI 工作台。
- 实际打包 .app，并复用已有捆绑 JDK/JDT LS；语言服务器开启组保留 JDT LS 初始化日志和 Java 子进程证据。
- 固定合成 Java 文件：8329 行、457728 字节（447 KiB）、164 个 import、142 个方法、69 个注入字段，约 50701 个语义 token、1990 个折叠区域。
- 固定默认主题、字体、窗口尺寸、默认 import 折叠和开启的 Code Vision 配置。没有修改用户真实项目文件。

## 主结果

表中多轮结果取各轮中位数的中位数；每轮独立启动进程并使用新的测试工作区。关闭 LSP 的主比较使用第二版同一探针二进制，排除了首次 UI 观察尝试的探索轮。

| 条件 | 轮数 | 结构结果应用中位数 | 滚动时箭头绘制中位数 | 26 次滚动序列耗时 |
|---|---:|---:|---:|---:|
| 当前行为，LSP 关闭 | 2 | 808.9 ms | 957.116 ms | 22.228 s |
| 仅优化折叠箭头遍历，LSP 关闭 | 2 | 752.9 ms | 0.881 ms | 0.553 s |
| 三项实验优化一起启用，LSP 关闭 | 2 | 9.9 ms | 0.916 ms | 0.551 s |
| 当前行为，LSP 开启 | 1 | 920.7 ms | 992.752 ms | 24.917 s |
| 仅优化折叠箭头遍历，LSP 开启 | 1 | 957.3 ms | 1.044 ms | 0.721 s |

结构结果应用包括语义着色和 applyFoldState；其中不包含异步 Rust 分析等待时间。每轮实际经历打开、三处单字符插入、26 次滚动。滚动以 16 ms 的主线程定时器产生相同刺激，因此上表反映完成同一操作序列的耗时，不能换算成产品实际渲染 FPS。

## 如何定位到折叠箭头

1. 最初三个探索组分别保留当前行为、仅限制语义着色范围、仅跳过未变化的折叠几何刷新。三者的滚动序列分别耗时约 22.7、23.3、20.2 秒，后两者仍有持续卡顿。
2. 编辑期间采样主线程，后两个探索组中 drawFoldIndicators 调用栈分别占 2559/4007（63.9%）、3302/4107（80.4%）样本；大量下层调用涉及字符串构造/分配。
3. 代码在每次绘制中，对每个折叠区域再次 regions.contains 遍历全部区域，判断父折叠。视口范围判断在这之后。1990 个区域对应最坏约 396 万次父区域检查，每次还会计算字符串形式的 id。
4. 单变量实验仅先筛出 collapsedFoldIDs 中的候选父区域，再使用原有的父区域判断；保留全文语义着色和原有全文排版。当前文件默认只折叠 import，于是内层由约 1990 个候选降为 1 个。
5. 两轮关闭 LSP 对照均从约 22 秒降至约 0.55 秒。启用并完成初始化的 JDT LS 对照也从约 24.9 秒降至约 0.72 秒。

定位：[CodeEditorView.swift:4605](https://github.com/1lck/Lithe-IDEA/blob/481da5e8b55102b3d3e2cd64e1850d072053a7eb/macos/Sources/Lithe/Views/Editor/CodeEditorView.swift#L4605)，`LineNumberGutterView.drawFoldIndicators`。
ID 构造：[JavaNavigationModels.swift:86](https://github.com/1lck/Lithe-IDEA/blob/481da5e8b55102b3d3e2cd64e1850d072053a7eb/macos/Sources/Lithe/Models/Java/JavaNavigationModels.swift#L86)。

## 次要但独立的停顿

仅优化箭头后，结构结果应用仍约 0.75 秒。updateFolds 在折叠几何没有改变时依然使全文布局失效，再同步 ensureLayout 整个文本容器。将语义着色限制到视口，并跳过未变化的折叠几何刷新，再配合箭头遍历优化后，结果应用降至约 10 ms。

定位：[CodeEditorView.swift:2693](https://github.com/1lck/Lithe-IDEA/blob/481da5e8b55102b3d3e2cd64e1850d072053a7eb/macos/Sources/Lithe/Views/Editor/CodeEditorView.swift#L2693)。

## 限制

- 没有获得 issue 中的原始业务源码。合成文件对齐行数和字节数，但控制流、折叠密度、依赖完整性和语义复杂度可能不同；这些结果确认了本地热点，不能证明原报告只有这些根因。
- 原报告为 macOS 15.5 / Lithe 0.4.3，本次为 macOS 27 / 当前工作树。此前已确认所分析的关键路径在 v0.4.3 中存在。
- 没有搭建报告中的 3564 文件、9 个 Maven 模块工程；LSP 开启组是实际单文件 Java 工作区，不代表大型 Maven 索引负载。
- 未单独完成同一应用会话内关闭标签页再重新打开的暖打开对照；重复启动轮不能替代该场景。
- 操作由进程内诊断驱动调用实际 AppKit 编辑和滚动入口；没有声称测到了物理键盘/触控板到屏幕的端到端延迟。
- 视口语义着色实验仅筛选当前视口 token，未实现完整的滚动补色、缓存失效和跨行语义处理，因此不能直接作为正式修复提交。
- 第一版探针的 heartbeat 输出没有保留阶段标签，仅使用其整体阻塞证据；主结果使用第二版同一二进制。
- 第一次探索轮尝试通过辅助功能观察窗口超时；该轮不进入第二版的主要对照汇总。

## 原始证据和复现材料

- `summary.json`：每轮统计。
- 各运行目录的 `events.jsonl`：直接计时、阶段和操作记录；`sample.txt`：启动阶段采样；`active-sample.txt`：编辑阶段采样。
- `processes.txt`、`status.json`：测试进程及完成记录；JDT LS 开启组的 Java 进程已被观测。
- `*.jdtls.log`：两个测试工作区的 JDT LS 初始化日志副本。
- `instrumentation-v2.patch`、`JavaEditorPerformanceProbe.swift`：临时诊断改动，已从产品源码撤回。
- `run-product.py`：打包和逐轮运行监督器，每轮 90 秒单调时钟截止时间，并清理进程树和采样子进程。
- `originals.json`、`restoration.json`：原文件指纹及恢复验证。
- `workspace/LargeService.java`：可复用合成文件；`build.log` 和 `build-v2.log`：两次成功的 Release 构建。

## 收尾验证

- 两次完整 macOS Release 构建成功。
- 临时改动期间测试稳定性静态检查、服务边界检查及 git diff --check 通过。
- 原源码已恢复，临时 .app 和两个本次创建的 JDT LS 缓存目录已删除。
- 源码恢复后，通过计时 harness 运行相关编辑器回归测试：31 个测试、4 个套件全部通过，测试执行共 0.379 秒。逐项耗时和 HTML/JUnit 已生成。
- 回归命令：`./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/issue-561-macos-swift.json -- --filter 'EditorSyntaxHighlighterTests|EditorCaretGeometryTests|TextViewportLayoutTests'`。
- 最终服务边界检查和 `git diff --check` 再次通过。

最慢的三个相关测试：yamlIncrementalHighlightingUsesCachedLineStateNearDocumentEnd() 106 ms；xmlIncrementalHighlightingUsesCachedLineStateNearDocumentEnd() 98 ms；caretAfterLastCharacterSitsPastTheFinalGlyphWhenFileHasNoTrailingNewline() 75 ms。所有测试均低于 1000 ms 警告阈值。
