# Agent 笔记：Windows 前端交互性能预算

状态：已实现

## 先说结论

Windows 前端的流畅度用 `scripts/windows/perf/run-windows-perf.mjs` 测量：在 Chromium 里跑生产构建，配一个页面内的模拟后端，用固定工程和固定场景给出启动、打字、滚动、切标签等数字。预算写在 `budgets.json`，只作为目标和手动门禁，不接入 CI。改编辑器、按键路径或每次保存都会走的代码时，先跑一次再跑一次对比，不靠“感觉变快了”。

## 问题

Windows 版跑在 WebView2 里，真实的卡顿来自主线程上的 JavaScript 和跨进程通信（IPC，前端与 Rust 之间传数据）。这些成本在小工程上看不出来，而且大部分没有任何测量。我们先前的判断都来自读代码，而读代码会同时高估和低估问题：

- 第一次测量发现“每键 25 次 IPC”，实际是模拟后端的失败重试放大的，真实是 3 次左右。
- 同样这次测量发现了读代码没有发现的主要成本：TextMate 分词在每次编辑后都重做到文件末尾，把 2 万行文件打字时六成的脚本时间花在主线程接收结果上。

没有数字，第一件事会被当成问题修，第二件事不会被发现。

## 决策

### 测什么

`scenarios.mjs` 定义场景：启动、打开工程、小文件和 2 万行文件打字、连按、滚动、切标签、工程树、快速打开、命令面板，以及反复打开文件后的内存增长。指标包括按键到下一帧的延迟、每键主线程耗时、每键 IPC 字节数和保存次数。

打字有两种节奏：匀速（`typingLarge`）和分组（`typingBursts`，每 8 个键停 400 毫秒）。后者才能暴露防抖后的工作，比如自动保存和工程索引，匀速打字时这些工作根本不会触发。

### 模拟后端

`lib/mock-tauri-host.js` 在页面内实现 Tauri 接口、虚拟文件系统和一个总是就绪的模拟语言服务器。它不含 Rust 和真实 IPC 的耗时，所以这里的数字是前端成本的下限，不是用户看到的总延迟。它的价值在于稳定、可重复，不需要 Windows 机器和真实 JDT LS。

每次运行结尾会列出模拟后端没有回答的命令。这个列表要保持为空或只有无关紧要的项，否则场景测到的是错误处理路径，第一次测量的“25 次 IPC”就是这样来的。

### 怎么用

```sh
node scripts/windows/perf/run-windows-perf.mjs                # 全部场景
node scripts/windows/perf/run-windows-perf.mjs --only typingLarge,scroll --save-baseline
node scripts/windows/perf/run-windows-perf.mjs --cpu 4        # 4 倍 CPU 降速
node scripts/windows/perf/run-windows-perf.mjs --profile typingLarge
```

`--profile` 使用未压缩构建，输出打字阶段按函数统计的自身耗时和按命令统计的 IPC 字节数。找性能问题时先看它，不要先猜。

`--cpu 4` 更接近用户的普通笔记本：开发机很快，1 倍速下按键延迟几乎总是下一帧，看不出差别。预算只在 1 倍速下判定，降速时只对比本地基线。

## 考虑过的备选方案

- 接入 CI 并在超预算时失败：否决。仓库曾因 Actions 用量被判定为滥用，而且共享 runner 的性能抖动会制造误报。`--fail-on-budget` 留给本地手动使用。
- 在真实 Tauri 应用里测量：否决作为日常手段。需要 Windows 机器和完整 JDT LS，耗时长且结果受环境影响。真实环境验证仍由人工完成，这份工具不替代它。
- 参考 OpenIDEA 的 `scripts/perf`：只借鉴了场景划分和“预算 + 基线”的思路，代码是针对 Lithe 的前端和命令重新写的。

## 后果

- 新增开发依赖 `playwright-core`（固定版本），只用于这个工具，产物不进安装包。
- 产物在 `.artifacts/windows-perf/`，包含构建结果、本地基线和 CPU profile。它们是每个工作树私有的可变状态，内容随源码变化，没有可靠的身份标记，所以在 `scripts/resources/worktree-resources.json` 登记为不可复用的 `windows-perf-state`。
- 模拟后端是一份要跟前端命令同步的代码。前端新增启动期命令时，运行结尾的未回答列表会提示补上。

## 验证

```sh
node --test scripts/windows/perf/lib/stats.test.mjs
./scripts/ci/common/test-classify-ci-changes.sh
```

## 适用范围

适用于 `windows/tauri/src` 和 `frontend/editor` 的交互性能工作。macOS 的基线见 [macOS 交互性能基线](2026-09-13-macos-interaction-performance-baseline.md)。真实 WebView2 和真实 JDT LS 下的表现不在这份工具的覆盖范围内。
