# Agent 笔记：项目树删除期间保持工作台可操作

状态：已实现

## 先说结论

项目树确认删除后，保存和关闭受影响文档仍在窗口线程完成，移动废纸篓或永久删除本身必须在后台任务执行。批量选择在后台写入开始前结束，删除完成后再回到窗口线程刷新目录和 Git 状态；开发者不得把文件删除循环直接写回窗口线程，否则大目录或多选删除会冻结输入和重绘。

## 问题

项目树的删除确认框通过 Viva 的 `After` 回调调用删除逻辑，这个回调在窗口线程执行。macOS 的 `osascript`、Windows 的 PowerShell 回收站命令和 Linux 的 `gio trash` 都是外部进程，`os.RemoveAll` 删除大目录也会耗时。删除循环如果留在窗口线程，窗口在每一项完成前都不能处理输入或重绘；#2083 由代码审查发现，尚未给出实测卡顿时长。

## 决策

本地项目树删除沿用远程删除和插件删除已经采用的任务边界：

1. 先在窗口线程解析项目相对路径、收集受影响文档，并用既有保存流程保护未保存编辑。
2. 保存完成后仍在窗口线程关闭这些文档，因为文档和标签状态只能由窗口线程修改。
3. 确认后的批量选择视为已经消费，在后台写入开始前通过 Core 的 `ClearRows` 结束。删除结束时不得再清空当前选择，否则会抹掉用户在删除期间新做的选择。
4. 逐个移动废纸篓或执行 `os.RemoveAll` 的循环放进 `App.background` 的工作函数。工作函数只读取它捕获的路径和删除函数，不访问 `App` 或项目状态。
5. 删除结束后由后台任务返回的函数在窗口线程调用 `finishRemoval`，统一记录操作、报告失败、刷新父目录和 Git 状态。

### 正确做法

- 新增项目树文件操作时，把可能耗时的文件系统或外部进程部分放在 `App.background` 的工作函数里，只把状态应用部分带回窗口线程。
- 修复涉及窗口线程阻塞的问题时，用可控的测试替身让操作停在等待点，先证明调用方能返回，再释放操作并验证最终状态。

### 不要这样做

- 不要在 `c.After`、菜单点击或确认框回调里直接执行 `os.RemoveAll`、`CombinedOutput` 或逐文件删除循环。`After` 只是离开绘制过程，并不会离开窗口线程。
- 不要为了等待删除完成而在窗口线程 sleep、轮询或阻塞等待后台任务。

## 考虑过的备选方案

### 保留同步删除，只显示进度

进度条仍需要窗口线程等待删除结束，不能恢复输入；模态进度界面还会继续截获工作台操作，因此没有采用。

### 给每次删除加固定超时

超时不能撤销已经移动或删除的部分，也不能让 `os.RemoveAll` 安全停在一致点。当前修复只改变执行线程，不改变删除语义；是否需要可取消删除，要在单独设计中定义部分结果和用户恢复方式。

## 后果

- 大目录和多选删除期间，窗口可以继续响应输入和重绘。
- 删除完成前标签已经关闭，这与原有“先保存并关闭，再删除”的顺序一致；删除失败仍通过通知报告，但不会恢复已关闭标签。
- 同一项删除还没有进度或取消界面。以后要加取消时，必须先定义部分删除结果如何呈现，不能把上下文取消当成撤销。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run '^TestProjectTreeRemovalReturnsBeforeSlowTrashFinishes$' -count=1`
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run '^(TestProjectTreeRemovalReturnsBeforeSlowTrashFinishes|TestProjectTreeDeleteMovesToTheTrashByDefault|TestProjectTreeCreatesRenamesAndDeletes|TestProjectTreeBatchSelectionFollowsCore)$' -count=1`

## 适用范围

- `desktop/internal/workbench/filetree_batch.go`
- `desktop/internal/workbench/filetree_menu_test.go`
- `desktop/internal/workbench/remote_files.go`
- `desktop/internal/workbench/pluginfilechanges.go`
