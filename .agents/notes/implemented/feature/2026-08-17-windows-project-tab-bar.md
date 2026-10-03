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

### 同一本地项目只属于一个窗口

Tauri 宿主记录目录实际对应的文件系统对象与所属窗口，前端项目 store 继续
拥有项目列表和活动标签。使用锁定依赖中的 `same-file` 原生句柄判断目录身份，
不把所有路径强制转成小写，避免误合并支持大小写区分的两个目录。

新窗口创建把查找、预留和构建放在同一个异步锁内。连续打开同一目录时，
第二次请求会复用第一个窗口，即使它的前端尚未完成加载。已有项目的重复
打开会显示窗口、解除最小化、聚焦，并通知所属前端切换到对应项目标签。
例如窗口 A 的后台标签打开了项目 B，再从窗口 C 打开 B，应激活 A 中的 B；
不要只聚焦 A 而仍显示 A 的其他项目，也不要扫描各窗口持久化缓存来猜测归属。

前端先注册激活监听器，再登记恢复的项目标签；当前窗口打开项目也先登记，
所以不会绕过新窗口去重。项目关闭、初始化失败、新窗口构建失败和窗口销毁
分别释放登记。初始路径校验失败也释放尚未登记为项目的预留，允许重试。
销毁事件不能同步等待宿主异步锁，否则可能阻塞正在构建窗口的 UI 线程。
远程和 WSL 协议路径不参与本地目录身份判断。

### 打开项目的目的地语义（This Window / New Window / Attach）

打开项目的询问弹窗对齐 IntelliJ：**This Window 关闭当前项目并由新项目替换**，
**New Window 打开独立应用窗口**，**Attach 把新项目作为附加的项目 Tab 加到当前
窗口**（即本 Note 的多项目模型），Cancel 取消。这是对 macOS 参考实现的有意分歧：
macOS 的同窗口选项就是本地的 Attach 语义（同窗口新开项目 session），Windows 端
把"替换"保留给 This Window，两个平台的差异记录在
`shared/platform-feature-matrix/features/workspace-open-switch.json`。

替换由 `openWorkspaceRuntime` 的 `mode: "replace-active"` 实现，语义对齐 IntelliJ
`ProjectManagerImpl.attachToExistingOrOpenInTheSameFrame` → `closeAndDisposeKeepingFrame`：
**关闭当前项目的确认是唯一决策点**，确认后旧项目就进入关闭状态，之后不再询问。时序是：
claim 窗口归属 → 对旧活动项目做一次未保存缓冲确认（用户取消或确认异常时，
若新路径此前在本窗口没有 Tab，则 release 本次新取得的 claim，避免原生
registry 把它一直路由到本窗口导致其他窗口也打不开；旧项目归属不动）→
**确认通过立即给旧项目加 closing 锁**（不可切回、不可编辑）→ persistCurrent →
走正常 attach 流程（新 Tab 激活、初始化或恢复）→ 新项目成功后拆除旧项目
（撤销 MCP、停止扩展进程与服务、删 Tab、释放归属）。与 IntelliJ 的有意差异：
IntelliJ 先关旧项目再开新项目，新项目失败时留下空框架；Lithe 在新项目初始化失败时
释放锁并把仍完好的旧项目原样交还（MCP 与服务从未撤销）。初始化期间用户切到其他
Tab 不影响拆除（旧项目已锁定，且拆除目标是进入时捕获的 id）。旧项目的服务拆除与
`closeProject` 共用 `disposeWorkspaceServices`。

关闭与激活互斥：closing 锁由 `closeWorkspaceRuntime` 或上面的替换流程持有，期间旧
Tab 仍在（Java 服务停止可能要等它的 startTask），但 `switchWorkspaceRuntime`
/ `switchToProject` 直接拒绝激活（不弹失败 toast），同路径的新打开会等关闭结束
再全新打开，重复关闭复用同一个 promise。关闭当前活动项目时**先离开再拆除**：
persist 后先切到后继 Tab（与 `removeProjectTabItems` 的选择一致）或欢迎页，成功后
才撤销 MCP、停止扩展进程和服务；**后继切换失败（回滚到本项目、本项目重新可编辑）
时立即中止关闭并释放锁**，不撤销任何东西，用户可重试。因此调用方的脏缓冲确认就是
最后一次询问；不在拆除之后再弹确认，因为那时 MCP 授权和服务已撤销，用户取消也
无法回到原状态（曾尝试过"拆除后复核"，被评审否决：取消会留下 MCP 失效的项目，
且与已选"放弃"的缓冲冲突）。删除时仍防御性检查活动项目，避免 registry 停在已删除 id。

**所有激活入口都必须遵守 closing 锁，包括失败回滚**：`restorePreviousWorkspace`
（打开或切换失败后回到之前的项目）会跳过已锁定的项目，改为激活其他未锁定的 Tab；
都不可用且失败项目的 Tab 已移除时，回到欢迎页。曾出现的交错路径：Attach 打开 B 卡在初始化 → 切回 A → This Window
打开 C（A 被锁）→ 点击 B → B 失败回滚到最初捕获的 A，绕过锁让 A 重新可编辑，随后 A
被拆除导致输入丢失。另外两道防线：替换流程拆除旧项目前如果它又成了活动项目，就保留
它并释放锁；`activateSuccessor` 缺少 `switchTo` 时视为无法离开（返回 false），不再当作成功。

已知限制与验证状态：WSL 的 `handleOpenWslProject` 已透传 replace 模式
（拆除复用与 `closeProject` 相同的 `disposeWorkspaceServices`），主路径
（WSL 项目经 This Window 替换当前项目）已于 2026-10-03 实机验证通过；
被替换方为 WSL 项目的拆除方向、脏缓冲守卫在 WSL 场景下的表现尚未完整
覆盖。远程（ssh）路径的打开分支仍未接入 replace，保持 attach 行为。

设置侧由布尔 `openFoldersInNewWindow` 迁移为三态
`projectOpenDefaultDestination`（this-window / new-window / attach），
`askWhereToOpenProjects` 保留。迁移映射必须保持旧行为：
`true → "new-window"`、`false → "attach"`（旧 this-window 就是附加 Tab），
且迁移要在 retired key 删除之前读取旧值；写成 `false → "this-window"` 会让
存量用户的项目在升级后被意外替换。

## 考虑过的备选方案

- **按路径字符串或各窗口缓存查重**：字符串会漏掉链接与路径别名，缓存无法原子处理连续打开，也会残留已关闭窗口；因此窗口去重使用宿主原生身份登记。
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
- **替换语义用"先 closeProject 再打开"实现**：关闭最后一个 Tab 会先切到
  欢迎页再加载新项目，产生两次工作区切换闪烁，且关闭后打开失败无法回滚；
  因此替换并入 `openWorkspaceRuntime`，成功后才拆除旧项目。
- **迁移把 `openFoldersInNewWindow=false` 映射为 this-window**：会让存量
  用户从"附加 Tab"变成"替换并关闭当前项目"，行为突变；因此映射为 attach。

## 后果

多项目切换变成工作台中的一次点击，项目管理入口仍保持原有职责，状态和
持久化继续归属于 workspace/file-system store。固定尺寸和水平滚动使项目
数量增长时不会改变标题栏和工作台的布局。

窗口去重额外保留每个本地项目的目录句柄，随项目或窗口关闭释放；原生恢复、
聚焦和网络目录身份仍需 Windows 实机验证。

代价是单项目时用户看不到这条切换条，关闭动作只能在多项目工作台中使用；
Tab Bar 目前不承载拖拽排序，若未来开放项目排序，必须复用 store 的排序
语义并补充相应的状态和并发测试。

## 验证

- `bun test windows/tauri/src/features/window/components/project-tab-bar.test.ts windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts`
- `bun --cwd windows/tauri run typecheck`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-agent-notes.sh`
- `bun test windows/tauri/src/features/window/services/project-window-router.test.ts`
- `bun test windows/tauri/src/features/workspace/services/workspace-lifecycle.test.ts windows/tauri/src/features/file-system/controllers/project-open-destination.test.ts`
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml project_window_registry`
- Windows 手工验证：项目位于后台标签、窗口最小化、连续重复打开、目录别名、关闭重开及初始化失败重试；替换模式下未保存缓冲确认（保存/放弃/取消）、初始化失败回滚、同路径重复打开不触发拆除。

测试覆盖可访问角色、项目切换、关闭按钮、异步状态清理、事件冒泡隔离、
项目顺序保持、单一活动项投影以及无项目/单项目/多项目的显示条件。

## 适用范围

- `windows/tauri/src/features/layout/components/main-layout.tsx`
- `windows/tauri/src/features/window/components/project-tab-bar.tsx`
- `windows/tauri/src/features/window/utils/project-tab-bar-model.ts`
- `windows/tauri/src/features/window/stores/workspace-tabs.store.ts`
- `windows/tauri/src/features/window/components/project-tab-bar.test.ts`
- `windows/tauri/src/features/window/utils/project-tab-bar-model.test.ts`
- `windows/tauri/src/features/file-system/controllers/project-open-destination.ts`
- `windows/tauri/src/features/workspace/services/workspace-lifecycle.ts`

- `windows/tauri/src-tauri/src/project_windows.rs`
- `windows/tauri/src-tauri/src/project_window_registry.rs`
- `windows/tauri/src/features/window/services/project-window-routing.ts`
- `windows/tauri/src/features/window/services/project-window-router.ts`
