# Agent 笔记：Windows 工作台项目 Tab Bar

状态：已实现

## 先说结论

Windows 工作台用独立的项目 Tab Bar 做高频项目切换，项目菜单继续负责打开、创建、克隆和最近项目。Tab 的顺序和活动状态来自统一 store，界面不能自行维护另一份项目列表。

## 问题

Windows 工作台可以同时打开多个项目，但原有项目菜单主要承担创建、打开、
克隆和最近项目管理，不适合作为高频的项目切换入口。需要在标题栏下提供
稳定、可访问、不会干扰窗口拖拽的项目 Tab Bar。

旧设计只描述了最初的切换条；当前实现还包含每个项目的关闭按钮，并通过
`hideWhenSingle` 在只有一个项目时隐藏整行。因此本 Note 以当前源码行为为
准，不把旧 spec 当作更高优先级的实现契约。

## 决策

`MainLayout` 在标题栏和工作台内容之间挂载 `ProjectTabBar`。组件从
`useWorkspaceTabsStore` 读取项目顺序和活动状态，用
`useFileSystemStore.switchToProject` 切换项目，用
`useFileSystemStore.closeProject` 关闭项目；原有 `TitleProjectMenu` 继续
负责创建、打开、克隆和选择最近项目。

`getProjectTabBarItems` 保留 store 中的项目顺序，但只承认第一个活动项目，
将其他项目投影为非活动，避免持久化状态或异步切换期间出现多个选中 Tab。
当前工作台使用 `hideWhenSingle`，所以无项目或只有一个项目时隐藏 Tab Bar，
至少有两个项目时显示；这个条件由 `shouldShowProjectTabBar` 集中判断。

Tab Bar 使用固定高度和水平溢出容器，不改变标题栏尺寸，也不占用原生窗口
拖拽区域。项目名称使用截断显示，完整路径通过 tooltip 和可访问标签提供；
容器使用 `role="tablist"`，项目按钮使用 `role="tab"` 和 `aria-selected`。
选中态、焦点环、文件夹图标和颜色沿用现有设计 token，不引入新的调色板。

切换或关闭项目期间，所有项目按钮暂时禁用。关闭按钮阻止事件冒泡，避免
一次点击同时触发切换和关闭；异步关闭通过 `finally` 清理本地进行状态。
这样保留了文件系统 store 已有的切换保护，并避免用户在并发操作期间看到
过期项目状态。

## 考虑过的备选方案

- **继续只使用标题栏项目菜单**：可以复用现有入口，但多项目切换需要多次
  打开菜单和识别项目，因此增加工作台内的直接切换条。
- **让 Tab Bar 成为原生窗口拖拽区**：会和项目按钮、关闭按钮争抢鼠标事件，
  因此保持窗口拖拽区和工作区控件分离。
- **由组件自行保存项目顺序和活动项目**：会和 Zustand workspace store
  产生两套状态，因此 Tab Bar 只做投影和事件转发。
- **直接相信每个输入项的 `isActive`**：异常持久化或异步更新可能产生多个
  活动 Tab，因此由纯 model helper 归一化为一个活动项。
- **只有一个项目也显示 Tab Bar**：能持续展示当前项目，但会占用欢迎页和
  单项目工作台的固定垂直空间，因此当前布局明确隐藏单项目状态。

## 后果

多项目切换变成工作台中的一次点击，项目管理入口仍保持原有职责，状态和
持久化继续归属于 workspace/file-system store。固定尺寸和水平滚动使项目
数量增长时不会改变标题栏和工作台的布局。

代价是单项目时用户看不到这条切换条，关闭动作只能在多项目工作台中使用；
Tab Bar 目前不承载拖拽排序，若未来开放项目排序，必须复用 store 的排序
语义并补充相应的状态和并发测试。

## 验证

- `bun test windows/tauri/src/features/window/components/project-tab-bar.test.ts windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts`
- `bun --cwd windows/tauri run typecheck`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-agent-notes.sh`

测试覆盖可访问角色、项目切换、关闭按钮、异步状态清理、事件冒泡隔离、
项目顺序保持、单一活动项投影以及无项目/单项目/多项目的显示条件。

## 适用范围

- `windows/tauri/src/features/layout/components/main-layout.tsx`
- `windows/tauri/src/features/window/components/project-tab-bar.tsx`
- `windows/tauri/src/features/window/utils/project-tab-bar-model.ts`
- `windows/tauri/src/features/window/stores/workspace-tabs.store.ts`
- `windows/tauri/src/features/window/components/project-tab-bar.test.ts`
- `windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts`
