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

本次分组调整：先确认中英文分区回归在移动前失败，移动后 8 项计时结果通过；保留普通参考线关闭时禁用彩虹开关、保存选择、重新开启后恢复和色板显隐。明暗主题设置场景已重拍并检查，不涉及编辑器绘制或 Core 行为变更。
