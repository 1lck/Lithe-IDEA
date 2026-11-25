# 内置彩虹配色与上下文高亮验证

这些截图由合并 `upstream/main` 后的 `3a10672c5` 生成，使用隔离的合成源码与诊断，不依赖具体插件。

- 平台：Windows amd64，本机 x64；Go 1.27.4、GNU Rust 1.100.0、MinGW x64。
- 依赖：本地 Core `a3dbe3d`、Viva `989da6b`。Core #201 和 Viva #60 尚未合入，因此这些结果不证明默认固定版本可构建。
- 工作台场景：`TestVisualEditorContextHighlights`（1000 × 640 逻辑像素，浅色英文、深色中文）和 `TestVisualProblemsSourcePreviewRainbow`（1440 × 1000，两种主题、英文）。
- 设置场景：`TestVisualEditorEssentialsSettings/editor-settings-*`（浅色英文、深色中文）。设置基线、彩虹开关和选色器由同一测试依次生成。
- 运行入口：`scripts/desktop/desktop-go.sh test -tags vivahead,lithevisual ./internal/workbench ./internal/settingswindow`，使用 `-run` 选择上述场景并设置 `LITHE_VISUAL_OUTPUT_DIR`。截图尺寸由测试和绘制缩放决定。
- 合并后 100 项定向竞态结果通过；6 项工作台截图结果和 3 项设置截图结果通过（数量包含父测试）。本次启动的测试进程已退出。

`context-before-*` 与 `context-symbol-*` 对照同一选区的高亮关闭和开启状态。`editor-settings-rainbow-light.png` 展示开关及配色，`editor-settings-rainbow-picker-dark.png` 展示选色器；`problems-source-preview-rainbow-*` 展示主编辑器与 Problems 源码预览共享的配色和参考线。

性能复核保留 100 KiB / 10 MiB 文档与原预算。等待其他编译结束后，固定逻辑 CPU 0、`GOMAXPROCS=1`，对修复前覆盖与当前源码各运行 10 个 500 ms 样本：

| 基准 | 10 MiB 前→后 | 规模比前→后 | 上限 |
| --- | ---: | ---: | ---: |
| Rope 视口读取 | 37.438→36.757 µs | 1.664→1.635 | 2 |
| 语法视口读取 | 1.795→1.804 µs | 1.052→1.054 | 1.5 |
| 语法行内输入 | 14.180→14.567 µs | 1.073→1.063 | 1.5 |

三项均未复现新增超预算，分配次数不变；被测热路径未修改。该单 CPU 设置只用于同条件前后归因，不将绝对耗时与原多核运行混比。当前 CPU 不是 Apple M4 参考机，绝对耗时预算未判定。

仍待完成：两项依赖合入后的默认构建、全量桌面测试、macOS 与原生可见窗口验收。先前全量测试有 Cygwin 发现、原生监听失败和工作台超时，合并后只重跑定向范围，未宣称全量通过。资源只读脚本依赖 zsh，本机缺少解释器；安装目录只读回归已在定向测试中通过。
