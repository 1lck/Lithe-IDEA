# Agent 笔记：Git 状态的旧请求不能覆盖新结果

状态：已实现

## 先说结论

同一项目可能同时读取几次 Git 状态；先发出的读取不一定先返回。工作台为读取分配递增编号，只让仍然有效的读取发布结果，避免分支和变更数量倒退。分支和同步操作使用同一套读取编号，不能用较早取得的状态覆盖后来的读取。

## 问题

`loadGit` 原来只依赖后台队列检查项目对象是否相同。这个检查能隔离关闭或切换的项目，却不能区分同一项目的先后读取；旧错误也可能抹掉已经显示的新状态。

## 决策

请求代次（开始读取时分配的递增编号）属于工作台异步结果投递的生命周期，不改变 Core 的 Git 状态语义。编号保存在项目对象，而不保存在每次整体替换的 `gitState` 中。

发起 `loadGit` 时取号；分支和同步先执行写操作，再在后台真正开始读取状态前取号。跨线程取号使用原子计数，状态发布仍仅在窗口线程进行。所有发布入口通过 `setGit` 检查编号；它不得在发布时重新取号，否则会误丢操作期间已经发起的新读取。嵌套仓库的分支读取不发布当前项目状态，也不占用当前项目的编号。过期失败仅进入后台诊断，不再改变当前界面；主动取消沿用日志豁免。

正确做法是分支写入后、读取前取号，再带着同一编号调用 `setGit`。不要直接赋值 `p.git`，也不要在读取完成后才取号，否则完成顺序会冒充观察顺序。关闭或重新打开项目仍由现有项目对象身份隔离，不复用已关闭对象。

## 考虑过的备选方案

- 仅取消旧请求：底层读取可能已完成并排队，取消不能代替发布前检查。
- 串行化全部读取：让新状态等待旧请求结束，增加刷新延迟，也无法单独覆盖分支和同步的发布入口。
- 把编号放在 `gitState`：整体替换状态会丢失编号，容易重新接受旧请求。

## 后果

每个项目增加一个固定大小原子编号，不增加常驻线程、轮询或请求缓存。最新读取失败仍保留现有错误语义，不能被更旧的成功覆盖。本修复不承诺外部 Git 操作的原子快照，也不重排多个写操作本身。

## 验证

`desktop/internal/workbench/git_order_test.go` 使用真实 Viva Driver 和 Core reducer，仅控制 Git 状态读取的完成顺序，覆盖逆序成功、过期失败、最新失败、分支与同步两种方向的交错完成、嵌套仓库隔离、操作后读取失败的既有终态、关闭重开。视觉用例 `desktop/internal/workbench/git_order_visual_test.go` 在明暗主题和中英文下渲染最新分支及计数。

运行 `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestGitStatus'`；视觉检查使用同一入口添加 `-tags 'vivahead lithevisual' -run '^TestVisualGitStatusRequestOrder$'` 并设置 `LITHE_VISUAL_OUTPUT_DIR`。目标平台原生操作验证独立于无头测试，不能用 Linux 结果标记 macOS 或 Windows 已验收。

## 适用范围

`desktop/internal/workbench/git.go`、`desktop/internal/workbench/changelists.go`、`desktop/internal/workbench/app.go`、`desktop/internal/workbench/branch.go`、`desktop/internal/workbench/gitsync.go` 的窗口异步读取发布，不涉及 Core ABI、插件或多仓库写操作协调。
