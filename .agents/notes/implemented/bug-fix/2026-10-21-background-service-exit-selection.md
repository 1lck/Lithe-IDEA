# Agent 笔记：后台服务退出确认使用可滚动的多选列表

状态：已实现

## 先说结论

退出 Lithe 时的后台服务列表不能把完整命令当作单行复选框标题，否则用户无法判断将结束哪个服务。列表现在固定宽度、限制可见高度，并让命令与详情换行；长列表通过滚动查看。全选、全不选和已选数量帮助用户批量操作，确认之前只改变本次弹窗的选择。

## 问题

Issue #1344 的截图中，Java 的长启动参数被原生复选框裁剪。原来的纵向列表没有高度上限，服务较多时还可能把底部退出按钮挤出屏幕。

## 决策

原生弹窗仍由 `MacProcessExitConfirmationPresenter` 管理，服务列表由同层的 `BackgroundResourceSelectionView`（AppKit 原生视图）呈现。复选框只保存选择，旁边的文本显示完整名称、详情、端口与进程数；文本允许选择和复制，也支持不含空格的长参数换行。列表视口最多 260 点，内容不足时按实际高度收缩。

全选和全不选只修改此弹窗内的选择，并更新数量；返回的仍是原来的资源 ID 集合。名称相同的服务不合并。只有已识别服务才显示“记住选择”，且默认不勾选。按选择结束、全部结束、取消，以及启动残留清扫的映射沿用原逻辑，不改进程终止和所有权判断。

正确做法：先在列表中勾选目标，用户确认后由已有协调器决定结束哪些资源。不要在复选框变化或全选时立即停止进程，也不要因为本次界面改进而给终端和 Agent 任务增加批量结束。

## 考虑过的备选方案

- 继续保留单行标题，仅增加悬停提示：仍难以比较多条长命令，也不能解决多服务时的整体高度问题。
- 重写整个退出流程或改用另一个模态窗口：本次仅需修复后台服务的多选内容，原生弹窗已有可靠的确认和取消映射，保留它可以缩小回归面。
- 每条命令独占一个弹窗：无法一起检查和批量选择后台服务，反而增加退出步骤。

## 后果

用户能完整查看和复制命令，并在服务较多时滚动选择。代价是原生适配层需要维护列表测量和选择控件；窗口仍使用系统弹窗外观，不新增产品菜单或主题系统。此视图不创建进程、不读写发行目录，也不产生运行时文件。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'BackgroundResourceSelectionViewTests|ProcessExitCoordinatorTests'`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

回归检查长命令换行、列表高度和滚动到最后一项、按资源身份多选、批量选择、记住选项及深浅外观。组件测试不代替完整产品退出和启动残留清扫的实机验收。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/UI/BackgroundResourceSelectionView.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacProcessExitConfirmationPresenter.swift`
- `macos/Tests/LitheTests/BackgroundResourceSelectionViewTests.swift`
