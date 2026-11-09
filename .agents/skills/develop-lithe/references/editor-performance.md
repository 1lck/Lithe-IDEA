# 编辑器性能基线

修改 Viva 编辑器或它的性能基线时遵守本页。通用性能规则见 [Lithe 开发规范](../SKILL.md) 第四节；本页路径都相对于仓库根目录。决策原因和被否方案见 `.agents/notes/implemented/testing/2026-11-09-viva-editor-performance-baseline.md`。

## 适用范围

以下路径统称“编辑器模块”：

| 路径 | 内容 |
| --- | --- |
| `desktop/internal/editor/**` | rope（文本存储）、syntax（染色调度）、textmate（语法分词）、regexp2（分词用的正则）、editorperf（基准文档生成） |
| `desktop/internal/editorview/**` | 编辑器视图：绘制、输入、撤销、折行、小地图、滚动 |
| `desktop/benchmarks/editor-budgets.json` | 每项基准的预算和理由 |
| `scripts/desktop/perf/**` | 运行、记录、对比和报告脚本 |

## 何时必须运行

- 改动编辑器模块的代码时，必须在同一台机器上分别运行改动前和改动后的基线，并把对比写进 PR 说明。只改注释或文档时不需要运行。
- 基线不是 CI 必跑项。CI 只检查脚本语法、ShellCheck 和报告生成器的测试，不运行基准。
- 超出预算只报告，不让脚本失败。PR 说明必须逐项解释改动新引入的超预算结果；已有的超预算结果不要求在同一个 PR 中修复。

## 硬性规则

1. **绘制和滚动不得分配。** `Paint` 和 `Scroll` 基准必须是 0 allocs/op、0 B/op。需要的缓冲放在视图上复用。交给 Viva 画布的字符串必须不可变，因为画布会跨帧保留标签内容并按内容比较：取 rope 叶子的子串（rope 的叶子是不可变字符串）、按文本版本缓存的跨叶子行，或预先格式化好的行号窗口里的子串，不得用 `unsafe` 把复用的缓冲当作字符串。
2. **一帧的开销只取决于可见范围。** 绘制、滚动、光标移动的耗时不得随文档大小或行长增长；超长单行（例如压缩过的 JSON）只处理视口里的列。
3. **输入路径不得做与文档大小成正比的工作。** 一次按键（含下一帧）在参考机上不超过 1 ms，分配有界。不得在按键、撤销、重做时复制整篇文本、全量扫描行宽或重新检测缩进；需要整篇信息时增量维护。
4. **窗口线程不得做与文档大小成正比的工作。** 打开和重新加载时，建 rope、扫描行宽、检测缩进都在后台完成，窗口线程只接收准备好的结果。
5. **空闲时不得重绘。** 没有输入、动画或新的后台结果时不得请求帧；周期性的变化（例如光标闪烁）只请求下一次变化时刻的那一帧。
6. **染色读取不得分配。** 视口内已算好的颜色每帧读取 0 分配；跳转后的首屏颜色在一帧（8.3 ms）内给出；整篇后台分词不低于 20 MB/s。
7. **内存有上限。** 一个打开的文档常驻不超过 2 MiB 加 1.5 倍文本字节。
8. **没有数据不得写性能结论。** “更快”“更省内存”必须附同一台空闲机器上的改动前后数据。
9. **不得通过放宽来变好看。** 不得为了让报告变好而上调预算、删除场景、缩小文档规模或改动基准文档的生成方式。确需调整预算时单独提交，并在预算的 `why` 和 PR 说明中写明原因与数据。

## 规模

- 小文档 100 KiB，大文档默认 10 MiB。
- 大文档的大小用环境变量 `LITHE_EDITOR_PERF_LARGE_BYTES` 或脚本参数 `--large-bytes` 修改，例如 `--large-bytes 50MiB`。接受的单位见 `editorperf.ParseBytes`。
- 基准文档由 `editorperf.Text` 按固定种子生成，不读磁盘、不下载。小文档是大文档的前缀，所以两种规模的结果可以直接对比。
- 文档类型：Go、Java、JSON（单行）、Markdown（含中文）、日志、混合（CRLF、制表符、中文、emoji、长行）。

## 运行

```bash
# 改动前：在改动前的提交上运行一次，保存输出
scripts/desktop/perf/editor-bench.sh run --out .artifacts/editor-perf/before.txt

# 改动后：运行并对比，报告里会带上相对改动前的变化
scripts/desktop/perf/editor-bench.sh run --out .artifacts/editor-perf/after.txt \
  --base .artifacts/editor-perf/before.txt

# 用 Viva perfhistory 检查回归（阈值 15%，忽略 20 ns 以下的结果）
scripts/desktop/perf/editor-bench.sh compare .artifacts/editor-perf/before.txt .artifacts/editor-perf/after.txt

# 只跑相关的基准
scripts/desktop/perf/editor-bench.sh run --bench '^BenchmarkEditorViewPaint/' --count 6
```

- 默认 `--count 1 --benchtime 200ms`，用于迭代。写进 PR 的前后对比默认使用 `--count 6`，让 `benchstat` 和 `perfhistory` 有足够的样本。
- 运行期间不要编译或运行其他程序。负载会让结果失真：Viva 在负载约 10 的机器上测到同一基准从 35 µs 变成 134 µs。
- 输出写在 `.artifacts/editor-perf/`，只属于这次运行，不跨工作树复用。

## 读报告

报告的每一行是一个基准结果，状态有四种：

| 状态 | 含义 |
| --- | --- |
| `✅ within` | 所有在当前机器上能判定的上限都满足 |
| `⚠️ over` | 至少一项超出；后面列出超出的项和幅度 |
| `— not judged` | 有匹配的预算，但没有一项能在当前机器上判定，例如预算只有耗时上限而当前机器不是参考机 |
| `— no budget` | 没有匹配的预算条目 |

- 耗时上限只在参考机（`editor-budgets.json` 的 `referenceMachine`，当前为 Apple M4）上判定。分配次数、分配字节和规模比在任何机器上都判定。
- 规模比是大文档结果除以小文档结果，用来发现与文档大小成正比的工作。

## 历史记录

```bash
scripts/desktop/perf/editor-bench.sh record --machine m4-mbp --kind physical
```

- `record` 用 `--count 6 --benchtime 500ms` 运行，并用 Viva `perfhistory` 追加到 `desktop/benchmarks/history/<machine>.jsonl`。这个文件随仓库提交。
- 只在空闲机器上记录。1 分钟负载超过 CPU 核数的四分之一时，脚本拒绝记录；`--force` 跳过检查，只在确认机器空闲时使用。
- 同一个历史文件只记录同一台机器、同一种 `kind`（`physical`、`vm`、`software-gpu`）。`perfhistory` 只比较机器、系统、架构和 CPU 都相同的结果。

## 新增基准

- 命名为 `BenchmarkEditor<层><场景>/<变体>/<规模>`，例如 `BenchmarkEditorViewPaint/wrap/10MiB`。规模放在最后，由 `editorperf.Size.Name` 给出。
- 文档只用 `editorperf.Text` 生成，循环用 `b.Loop()`，并调用 `b.ReportAllocs()`。
- 进入计时循环前把状态预热到稳定：首帧已绘制、染色已完成、缓冲已扩容。预热帧必须画在计时循环用的同一块画布上，因为窗口每一帧都复用同一块画布；循环从一块新画布开始时，首帧的扩容会被平摊进每一帧，在 0 B/op 的预算上显示为几字节的超出。视图基准在 `New` 之后立即关闭后台染色协程，避免它与计时循环争用 CPU。
- 一个计时迭代必须是用户可感知的一次完整操作，例如“插入并删除一个字符，再画一帧”，并保持文档在迭代之间不变长。
- 有规模比预算的基准，两种规模必须处理同样的文本。只涉及一行的操作（例如在一行里输入）在每种规模下都选小文档里的同一行，大文档以小文档开头，所以这一行在两边相同；不要各取各自文档的中间行，否则比值比较的是两行不同的内容，一行的分词成本能相差将近六倍。覆盖整个视口的操作可以取各自文档的中间，几十行的平均成本在两种规模下相近。
- 新增基准必须在 `editor-budgets.json` 中有匹配的预算，并写 `why`。预算文件由 `node --test scripts/desktop/perf/editor-perf-report.test.mjs` 校验。
