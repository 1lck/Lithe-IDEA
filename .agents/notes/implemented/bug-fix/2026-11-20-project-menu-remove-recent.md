# Agent 笔记：项目菜单独立移除最近记录

状态：已实现

## 先说结论

标题栏项目菜单的最近项目每行都提供 X，只从最近列表移除记录，不打开项目、不删除目录，也不关闭菜单。当前项目行的 X 继续关闭项目，并保留最近记录。目录已经不存在时，该行不能打开，但 X 仍可用。

## 问题

项目菜单原来仅为当前项目绘制关闭按钮，最近项目没有直接移除入口。若将缺失项目整行禁用，后续加入的移除按钮也会一起失去交互能力。

## 决策

最近项目复用 Core（共享 Rust 规则层）的现有最近项目移除动作和持久化路径。行内 X 使用独立命中区与对应的本地化提示，移除动作优先于行打开动作，防止同一次点击又触发打开。

缺失项目继续灰显且禁止打开，移除按钮保持可点击。正确做法是分别处理行激活和 X；不要在父容器上禁用全部子控件。

## 考虑过的备选方案

- 只在右键菜单提供移除：入口不直观，无法满足项目菜单直接删除记录的操作。
- 点击 X 后关闭整个菜单：连续整理最近记录时需要反复展开，现有列表更新已能原位呈现结果。

## 后果

用户可以直接整理存在或缺失目录的最近记录。两个区段的 X 有不同含义，因此分别使用“关闭项目”和“从最近项目移除”的提示；删除文件不属于这个入口。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestProjectMenuRemoves|TestProjectMenuWheel' -count=1 -timeout=45s`：回归测试先确认缺少 X 时失败；修复后验证记录持久化、目录保留、菜单保留及当前项目关闭。
- `scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench -run TestVisualProjectMenuRemove -count=1 -timeout=45s`：使用真实临时目录生成中英文、明暗主题截图，检查存在与缺失两种最近记录。输出由 `LITHE_VISUAL_OUTPUT_DIR` 指定。

## 适用范围

- `desktop/internal/workbench/chrome_view.go`
- `desktop/internal/workbench/project_menu_test.go`
- `shared/platform-feature-matrix/features/workspace-open-switch.json`
