# 内置彩虹配色与上下文高亮验证

本目录截图更新至评审修复提交 `293d01fd4`（独立设置区块提交 `25e6ee51f`）。使用隔离合成源码与诊断，不依赖具体插件；已检查实际 PNG。

- 平台：物理 Windows amd64，本机 Intel Core Ultra 5 125H；Go 1.27.4、GNU Rust 1.100.0、MinGW x64。不是 Parallels 来宾或 ARM64 仿真验证。
- 本地依赖：Core 功能提交 `6eccef4467d4b79f17b55fcd43f8d03e69d57ba1`（后续 CI 单测修复 `4f4cc06c` 不改生产行为）、Viva `d8c0a63`；Core #201 和 Viva #60 仍待合入。验证用覆盖只在忽略配置中，不证明默认固定版本可构建。
- 工作台：`TestVisualEditorContextHighlights`（1000 × 640 逻辑像素，浅色英文、深色中文）和 `TestVisualProblemsSourcePreviewRainbow`（1440 × 1000，两主题、英文）。
- 设置：`TestVisualEditorEssentialsSettings/editor-settings-*`（浅色英文、深色中文）。彩虹括号、变量和两套色板单独成区块；基础显示、参考线仍在原区块。包含关闭/启用、两主题色板和选色器。
- 入口：`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench ./internal/settingswindow`，用 `-run` 选择上述场景，设置 `LITHE_VISUAL_OUTPUT_DIR`。

`context-before-*` 与 `context-symbol-*` 是同一选区的前后对照，`context-brackets-*` 展示配对端。`editor-settings-rainbow-*` 展示独立设置区块，`problems-source-preview-rainbow-*` 展示主编辑器与完整源码预览共享配色、配对和参考线。

本轮正常计时验证 58 项结果通过；新增的跨检查点删除、缓存上限/删除补回、随机编辑与 Core 结果复用均覆盖。最终语法、视图、Core 桥接、工作台、设置五包的相关竞态测试通过。静态测试扫描对 Go 报 N/A，不算稳定性通过证据。

编辑器全部子包与设置包全量通过；全量工作台在 `TestLogDeleteButtonReportsTheBranchesItCouldNotDelete` 所在 Git 日志场景达到 180 秒套件期限，没有宣称全量通过。Core 的范围外 Git 集成也有失败/超时。macOS、原生可见窗口、日志窗口整链与默认依赖构建仍未验收。

资源只读脚本和其 Node fixture 测试需要 zsh，本机没有解释器，保留未完成状态；fixture 已补齐生产脚本新增的设置发布工作流，没有放宽静态门禁。安装目录只读工作流定向测试通过。


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
