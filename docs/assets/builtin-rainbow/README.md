# 内置彩虹配色与上下文高亮验证

工作台截图来自评审修复提交 `293d01fd4`；设置截图已在本次彩虹参考线分组调整后重新生成。使用隔离合成源码与诊断，不依赖具体插件；已检查实际 PNG。

- 平台：物理 Windows amd64，本机 Intel Core Ultra 5 125H；Go 1.27.4、GNU Rust 1.100.0、MinGW x64。不是 Parallels 来宾或 ARM64 仿真验证。
- 截图原始依赖为 Core 功能提交 `6eccef4467d4b79f17b55fcd43f8d03e69d57ba1`、Viva `d8c0a63`。最新 main 合并验证使用 Core `4f4cc06c`（CI 单测修复，不改生产行为），Viva 则在最新固定修订 `448b0553faf8` 上仅叠加 #60 的选色器修复。Core #201 和 Viva #60 仍待合入；覆盖只在忽略配置中，不证明默认固定版本可构建。
- 工作台：`TestVisualEditorContextHighlights`（1000 × 640 逻辑像素，浅色英文、深色中文）和 `TestVisualProblemsSourcePreviewRainbow`（1440 × 1000，两主题、英文）。
- 设置：`TestVisualEditorEssentialsSettings/editor-settings-*`（浅色英文、深色中文）。彩虹括号、变量、彩虹参考线和两套色板放在同一区块；普通缩进参考线保留在编辑器显示区块。包含关闭/启用、两主题色板和选色器。
- 入口：`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench ./internal/settingswindow`，用 `-run` 选择上述场景，设置 `LITHE_VISUAL_OUTPUT_DIR`。

`context-before-*` 与 `context-symbol-*` 是同一选区的前后对照，`context-brackets-*` 展示配对端。`editor-settings-rainbow-*` 展示独立设置区块，`problems-source-preview-rainbow-*` 展示主编辑器与完整源码预览共享配色、配对和参考线。

本轮正常计时验证 58 项结果通过；新增的跨检查点删除、缓存上限/删除补回、随机编辑与 Core 结果复用均覆盖。最终语法、视图、Core 桥接、工作台、设置五包的相关竞态测试通过。静态测试扫描对 Go 报 N/A，不算稳定性通过证据。

编辑器全部子包与设置包全量通过；全量工作台触发全包累计 180 秒期限，当时 `TestLogDeleteButtonReportsTheBranchesItCouldNotDelete` 仅运行 5 秒，仍在初始化。不能将超时栈最后出现的用例认定为根因，没有宣称全量通过。Core 的范围外 Git 集成也有失败/超时。macOS、原生可见窗口、日志窗口整链与默认依赖构建仍未验收。

合并最新 main 后，使用相同依赖分别运行 main/当前的该单例（90 秒期限），两侧均通过，分别 18.56 / 21.05 秒。再用 `-test.run=^TestLog(Deletes|DeleteButton|ForceDelete) -test.count=1 -test.v -test.timeout=180s` 对照同组 6 个删除分支场景，两侧均通过，进程耗时分别 154.1 / 159.4 秒。Git fixture、调度、桥接相对 main 未改变，Core #201 也没有修改 Git 路径；这些证据不支持本次引入 Git 挂死，但定向通过不代表全量套件已通过。

资源只读脚本和其 Node fixture 测试在 Linux CI 的 `Format and script tests` 检查通过（运行 `45739420847`）；fixture 已补齐生产脚本新增的设置发布工作流，没有放宽静态门禁。本机没有 zsh，未重复执行该脚本；Windows 安装目录只读工作流定向测试通过。


## 本轮性能测量

完整基线保持原有 100 KiB / 10 MiB 和预算：修复前 129 项，修复后新增 6 项候选管线，共 135 项，各 6 样本、200 ms。旧基准没有被替换、删除或缩小。候选管线另外比较同一编辑操作的旧全量收集和新增增量收集；每次迭代是两次同宽编辑及对应快照。新场景按功能的 1 MiB（含）上限截断生成器可能补齐的最后一行，前后完全相同。

| 候选管线（两次编辑和快照） | 修复前 ms | 修复后 ms | 分配前 KiB | 分配后 KiB |
| --- | ---: | ---: | ---: | ---: |
| go/100KiB | 158.911 | 1.156 | 5965.9 | 430.3 |
| go/1MiB | 535.851 | 2.629 | 17902.0 | 1394.3 |
| java/100KiB | 132.420 | 3.112 | 4205.7 | 313.4 |
| java/1MiB | 885.026 | 3.822 | 22840.8 | 1390.7 |
| markdown/100KiB | 80.557 | 1.805 | 3892.7 | 159.5 |
| markdown/1MiB | 820.488 | 2.340 | 23180.9 | 972.6 |

候选前后比较在编译结束后相邻运行，表中为 6 样本中位数。改动后候选场景每次迭代分配最多约 1.36 MiB，低于新增 3 MiB 预算；没有修改既有预算。Core 结果复用另有测试：关闭前景色仍保留配对/参考线，候选相同时返回同一结果，开关变化时重新调用 Core。

完整报告：之前的 Rope LineOf 规模比 2.85（上限 2）和 longline-wrap 输入 2.53（上限 2）已超限；本轮分别为 2.55 和 2.58。新增 minimap 绘制 1.73（上限 1.5）。视图后段出现其他项目编译，原始报告带有负载干扰；已检查这些路径：本轮没有修改 Rope 查找、小地图绘制、长行输入或绘制循环，绘制和滚动仍为 0 B/op、0 allocs/op。不能据此将原始时间比直接归因为代码回归，后续固定 CPU 的复核单列。当前 CPU 不同于 Apple M4，绝对耗时上限不判定。

### 最新 main 合并后的空闲复核

已通过 merge commit `a39ac7d3a` 合入 `upstream/main` 的 `b6eab0b364`，包括最新 Viva 同步和 v0.8.18。对照一侧使用该 main 的原始 Go 源码，另一侧使用最终功能分支；两侧链接相同的上述 Core/Viva，避免依赖差异干扰归因。使用同机 CPU 0、`GOMAXPROCS=1`、500 ms，每个场景各 6 样本，按轮交替 main/当前顺序。监测编译器和工作台测试进程；48 个视图有效样本均没有检测到重叠负载。

| 场景 | main / 100 KiB µs | 当前 / 100 KiB µs | main / 10 MiB µs | 当前 / 10 MiB µs | 规模比 main → 当前 | 结论 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| minimap 绘制 | 71.5 | 72.7 | 68.2 | 67.2 | 0.95 → 0.92 | 均低于 1.5；两侧均 0 B/op、0 allocs/op |
| longline-wrap 输入 | 49.5 | 50.8 | 124.8 | 126.6 | 2.52 → 2.49 | 两侧均超过既有上限 2；未新增超限，10 MiB 耗时变化 +1.4% |

表中为中位数，报告由 `scripts/desktop/perf/editor-perf-report.mjs --budgets desktop/benchmarks/editor-budgets.json --base <main.txt> <current.txt>` 生成。没有调整工作负载、规模或既有预算。小地图原始新增超限未在空闲条件下复现；长行换行规模比为 main 已有问题，本次没有引入新的超预算项。该结论只覆盖上述两项与当前机器，绝对耗时不按 Apple M4 预算判定。

收尾全量运行复现了本 PR 新增超时用例的不稳定性：`time.Nanosecond` 依赖真实计时精度，没有触发超时而返回全部候选。现通过私有单方法 tokenizer 接口注入 `stopped=true`，覆盖真实的超时原因传播，并精确断言保留首段、不混入无效后缀。修复后编辑器各子包、视图、设置全量及工作台相关测试通过；该用例连续 100 次通过，候选相关竞态通过，逐项计时 10 ms，HTML/JUnit 报告确认进程结束。

为核对接口分派开销，另取修复前 `a39ac7d3a` 与修复后的候选管线各 6 样本、两个规模，共 24 个无重叠负载样本：Go/100 KiB 中位数 1.327 → 1.310 ms，Go/1 MiB 为 2.638 → 2.629 ms；分配次数分别保持 424、434，分配字节约 430 KiB、1.36 MiB，均符合既有 3 MiB 上限。未改 tokenizer 的生产选择、时限或超时语义。

### 深入归因与既有问题登记

再次 fetch 并 merge `upstream/main`，远端仍为 `b6eab0b364`，结果 `Already up to date`。本轮当前实现为 `e0244463a`，诊断没有修改产品代码或测试预算。

长行换行的 CPU 采样定位到 `View.Paint`：每帧从该逻辑行第 0 个折行遍历，逐个计算 y 并跳过视口之前的折行。10 MiB 采样约 96.7% 在绘制路径，编辑约 2%；循环枚举、y 计算和上方 `continue` 约占全部样本的 47.9%。main 已有同一循环，属于既有问题。

以仅替换该循环起点的忽略目录 Go overlay 做因果实验，仍使用原 100 KiB / 10 MiB 基准、500 ms、CPU 0、`GOMAXPROCS=1`，每侧每规模 6 个交替样本，24 个样本无检测到的编译或工作台测试重叠：输入和下一帧中位数分别为 49.85 → 48.89 µs、125.37 → 57.98 µs，规模比 2.52 → 1.19，分配次数保持 9 / 16。实验下现有 editorview 测试通过；该 overlay 是诊断证据，尚未作为正式修复交付。已按功能建议模板登记 [#2424](https://github.com/1lck/Lithe-IDEA/issues/2424)，正式修复需补深滚动、部分可见行及提示/选区边界的回归。

工作台两侧用相同 Core/Viva、同一全包顺序、`-test.count=1 -test.v -test.timeout=180s` 和相同 Git Trace2 诊断再运行。两侧都累计超时；共同 25 个顶层用例的报告耗时合计为 main 160.84 s、当前 153.17 s，当前额外通过远程分支删除用例（18.88 s）。main 到期时该用例运行 19 s，当前到期时下一个用例运行 8 s。本次采样未显示共同用例变慢，仍不宣称全量通过。

| 共同慢用例 | main s | 当前 s |
| --- | ---: | ---: |
| 新建公共分支 | 62.59 | 57.02 |
| 部分失败回滚 | 32.82 | 33.44 |
| 列出阻塞修改 | 29.94 | 27.77 |
| 公共分支切换 | 25.80 | 23.94 |

这四项的 Git 命令类别次数逐项相同。main/当前分别记录 796/849 个根 Git 进程（当前多进入一个用例），根命令中位数 86.2/73.1 ms、最长约 1.052/0.700 s，没有单条 Git 接近 30 s。并发运行区间去重合并后覆盖约 62.0/58.5 s；其余时间仅能归入进程启动、等待、调度、清理等，现有 trace 不能确定各部分比例。

静态链路确认 fixture 每次先做 10 次串行本地 Git，再打开完整 App；`settleChain` 经 `App.wait` 等待全部后台任务，轮数限制不等于每轮有本地截止时间，watch 初始化和状态发布会再发仓库、rebase、operation 读取。已按功能建议模板登记 [#2425](https://github.com/1lck/Lithe-IDEA/issues/2425)，用于明确等待边界、缩小 fixture 与有界清理。上述数据只证明本轮共同场景没有观察到性能退化，不能保证未执行到的后续全包用例。

两张 Issue 的正文已回读核验。创建时请求的标签没有保留，补充 `refactor` 等普通标签时，GraphQL 返回权限不足，REST 返回 403（需要仓库管理员权限）。标签登记仍未完成，合并前需要维护者补齐；没有将这一项记为通过。

本次分组调整：先确认中英文分区回归在移动前失败，移动后 8 项计时结果通过；保留普通参考线关闭时禁用彩虹开关、保存选择、重新开启后恢复和色板显隐。明暗主题设置场景已重拍并检查，不涉及编辑器绘制或 Core 行为变更。


## 2026-11-26：默认依赖与新评审修复

当前分支合并 `upstream/main 82530d8a0`，保留 #2427 的 `firstSub` 可见折行循环，并合入 #2436、#2437 的测试等待及夹具修复。Core 固定 `c269c411`（#201），Viva 固定 `7696355e44b5`（main #2439，包含已合并的上游 #458）。默认 wrapper 的 Core 身份为 `core-source=pinned`、`core-worktree=clean`，无 Core/Viva 本地覆盖。

降级日志回归在修复前观察到同一原因随三次编辑累计四条 WARN，修复后只在原因新出现时记录；恢复后再次出现仍记录。位置复用回归在修复前因偏移改变重新调用已取消的 Core 请求而失败；修复后按候选序号投影颜色、配对和作用域，结果与新 Core 调用一致，覆盖非均匀位移、不匹配闭括号及混合颜色排序。跨 1 MiB 关闭候选收集的旧实现重分词四段，修复后只重算编辑所在的一段；重新启用仍重建完整候选。

### 性能复核

新增正式 `BenchmarkEditorViewPaint/indent-guides`，设置 `IndentGuides=true` 并安装视口附近已准备的代码块作用域。两侧均保留该场景，100 KiB/10 MiB 文档、默认预算不变。前侧仅把 `paint.go`、`highlighter.go` 覆盖为 `61f4bc7` 的实现，其余代码和依赖与当前侧相同；覆盖文件只在 `.artifacts/pr2420-update/`。

预先通过 `scripts/desktop/desktop-go.sh test -c` 编译两侧视图和语法测试程序，停止其他编译和测试后运行。首轮各六样本的 48 项均满足预算，但 perfhistory 报告十项耗时回归；这些结果没有当作无回归结论。随后在同一 Windows amd64 物理机 Intel Core Ultra 5 125H 上固定 CPU 0、`-test.cpu=1`，交替前后顺序，每侧六样本、200 ms，对全部 42 项视图场景复核，未检测到编译/其他测试重叠；没有修改实现、规模、场景或预算。固定 CPU 后 perfhistory 未报告回归，42 项均满足可判定预算。该机器不是 Apple M4，不判绝对耗时上限。

| 场景 | 前侧 100 KiB µs | 当前 100 KiB µs | 前侧 10 MiB µs | 当前 10 MiB µs | 说明 |
| --- | ---: | ---: | ---: | ---: | --- |
| Go 绘制 | 48.56 | 48.14 | 44.99 | 44.24 | 两侧零分配 |
| 默认普通参考线及作用域 | 52.02 | 51.44 | 48.32 | 48.66 | 当前规模比 0.95，零分配；相对当前无参考线 Go 场景增加约 6.9% / 10.0% |
| 小地图绘制 | 72.25 | 82.11 | 70.52 | 71.18 | 当前规模比 0.87，零分配；耗时差未超过 perfhistory 15% 阈值 |
| 长行换行绘制 | 40.67 | 38.28 | 112.13 | 43.38 | 规模比 2.76→1.13，零分配 |
| 长行换行输入及下一帧 | 50.86 | 49.69 | 133.19 | 59.96 | 规模比 2.62→1.21；分配次数保持 9 / 16 |

原始输出、身份信息、覆盖配置和预算报告保留在本检出的 `.artifacts/pr2420-update/`。基准程序使用 `-test.run=^$ -test.bench=^BenchmarkEditorView(Paint|Type|Scroll) -test.count=1 -test.benchtime=200ms -test.cpu=1`，每侧交替六次。语法候选管线另以 `^BenchmarkEditorSyntaxCandidates`、count 6 验证，六项均满足预算，分配次数不变。报告使用：

```bash
scripts/desktop/perf/editor-bench.sh compare \
  .artifacts/pr2420-update/perf-pinned-before.txt \
  .artifacts/pr2420-update/perf-pinned-after.txt
```

### 默认依赖验证及限制

- Windows amd64 GNU 原生 `scripts/desktop/desktop-go.sh build -o ../.artifacts/pr2420-update/lithe.exe ./cmd/lithe` 成功；未使用 `vivahead` 构建标签。
- `editor/...`、`editorview`、`settingswindow` 和 `core` 包完整测试通过，包含日志目录调用点校验。相关语法、视图、工作台竞态通过；合并最终 main 后工作台竞态再次通过。
- Windows 逐项计时最终记录 53 项通过，进程树终止已确认；新增日志回归 0.60 秒，安装目录只读工作流 5.50 秒。静态扫描对 Go 为 N/A，另按资源、等待及清理边界人工检查。
- 默认依赖无头视觉用例覆盖普通/彩虹参考线、括号和符号背景、Problems 源码预览；深色中文、浅色英文截图重新生成并检查，位于忽略目录，不将其当作原生窗口验收。
- `test ./... -timeout=300s` 中其他包通过，工作台触发整包累计期限，最后的 `TestBuildProviderObservesGlobalToolchainSavedByAnotherClient` 当时仅运行 2 秒，单独复测 5.31 秒通过。因此不宣称全包通过，也不把这个累计超时当作该用例或本次彩虹改动引入的挂死。
- macOS、原生可见窗口及整机工作流未验收。当前机器没有 zsh，资源只读静态脚本未能在本机执行；已有安装目录只读回归通过，完整静态门禁仍由 CI 验证。
