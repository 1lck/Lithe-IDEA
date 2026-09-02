# Lithe Agent Entry Point

Before any work in this repository, load and follow the `develop-lithe` skill
at `.agents/skills/develop-lithe/SKILL.md`. That Skill is the single source of
truth for AI coding and verification rules, including the required Rust Core
comment standard.

If a task creates, modifies, or reviews test code or test infrastructure,
additionally load `.agents/skills/write-stable-tests/SKILL.md` before
proceeding. That Skill defines the mandatory bounded-wait, deterministic-time,
cleanup, and per-test timing rules for both macOS and Windows.

If a task prepares, validates, or publishes a stable Lithe release,
additionally load `.agents/skills/release-lithe/SKILL.md` before changing
release notes, version metadata, tags, or release workflows.

If the task involves building, running, diagnosing, or transferring files to the
Windows product through a Parallels guest VM, additionally load
`.agents/skills/debug-windows-on-parallels/SKILL.md` before proceeding.

## Test process lifecycle and cleanup

Unless the user gives a specific instruction to keep a process running, any
Lithe application started for building, testing, debugging, previewing, or
verification must be shut down when the task or test run is complete. Clean up
all child processes, helper processes, temporary app instances, and related
resources, then verify that no Lithe processes remain before handing the work
back. Do not launch duplicate Lithe instances during repeated checks, and do
not leave test-built applications open in the user's application list. If a
process cannot be stopped cleanly, report it explicitly and make a bounded
best-effort cleanup before continuing.

## 高性能 UI 交互与可调布局要求

涉及可拖拽分隔线、可调整面板、连续拖动、滚动或其他高频 UI 交互时，必须
优先复用项目中已有的高性能布局容器和交互组件，不得为了快速实现而在业务
父视图中直接堆叠自定义 `DragGesture`、逐事件写入多个 `@State` 或重复实现
分隔线逻辑。

- macOS 的可调面板必须优先使用 `LitheSplitPaneView` 和
  `SplitHandleView`；如果确实无法复用，必须在变更说明中解释原因，并保持
  相同的行为契约。
- 拖拽处理必须使用稳定的坐标空间（连续拖动时优先使用全局坐标），避免因
  分隔线自身移动导致坐标原点变化和拖拽跳动。
- 高频拖拽事件必须经过节流、合并或死区过滤，不能在每个指针事件中触发
  无必要的父视图重建；可变尺寸状态应尽量封装在局部布局容器内，避免拖动
  使整个功能页面重新计算。
- 必须提供明确的最小/最大尺寸和可用空间约束，保证相邻面板仍满足最低可用
  宽度；窗口缩放、面板隐藏和重新出现时不得产生负尺寸或布局溢出。
- 交互行为应与现有 Git、编辑器和工具窗口保持一致，包括悬停/拖拽高亮、
  平台对应的调整光标、帮助文本和无障碍标签。
- 如果尺寸需要跨刷新或重启保留，应通过现有布局持久化机制提交最终尺寸，
  不要在拖拽过程中持续写入持久化存储。
- 新增或修改此类 UI 后，必须至少完成对应产品构建、`git diff --check`
  和相关边界检查；代码审查时应明确确认拖拽不会导致高频全页面重绘。

这些要求适用于 macOS 和 Windows：平台可使用各自的原生实现，但交互语义、
性能目标、尺寸约束和可访问性要求必须保持一致。
