# Agent 笔记：Windows选中运行配置工具栏与动作归属

状态：已实现

## 先说结论

工具栏观察既有Run配置、运行会话、调试会话和发现诊断。共享动作捕获配置与工作区身份，在准备边界检查取消；Java调试复用已有Maven/JDT和DAP入口，Stop依据选中配置的会话拥有者释放。

## 问题

标题栏缺少命名配置与直接Debug入口；按当前焦点终端或全局运行布尔值执行Stop和Rerun，会干扰另一配置或工作区拥有的进程。

## 决策

工具栏观察既有Run配置、运行会话、调试会话和发现诊断。共享动作捕获配置与工作区身份，在准备边界检查取消；Java调试复用已有Maven/JDT和DAP入口，Stop依据选中配置的会话拥有者释放。

标题栏集成只增加组件导入和右侧控件，保留已合并的 New Entry host、紧凑菜单关闭逻辑、项目菜单、窗口标题与官方更新器控件。不携带已合并的 Java / Debug 前置实现，不把 Spring 索引 readiness 或 gutter 路径归一化修复混入本功能。

首次service Run的取消同样由Run owner负责：工具栏传入可选AbortSignal，owner在execution预留后注册精确取消，在各await边界检查身份和signal，并在finally解绑。即使save/context仍未结束、sessions仍为空也不会随后启动进程。旧signal或旧execution的Stop不能取消替代执行或它的构建决策；不借用primary/focused槽位。真实createRunStore回归用受控stop/save/context门闩，而非手工伪造preparing session。

## 考虑过的备选方案

不根据当前终端焦点停止进程；不为了下拉框重新扫描Java入口；不对所有语言显示可用的Debug；不为每个按钮复制清理协议。

## 后果

新增临时操作和错误状态以及选中动作测试。Java/Spring可从命名配置Run/Debug；不额外添加重复设置齿轮，保留下拉Edit与全局设置。运行临时资源沿用既有会话所有者与清理边界，不修改安装目录。

## 验证

两个工具栏测试入口显式登记到 Windows CI 的独立计时进程。除选中动作和实际控件测试外，还重跑既有 Java / Debug 依赖契约、官方标题栏更新器、窗口拖动、紧凑菜单关闭与项目菜单模型回归；这不等同于完整 Windows GUI 或新的原生后端验收。

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/run/actions/selected-run-actions.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/run/components/title-run-control.test.tsx`

## 适用范围

- `windows/tauri/src/features/run/actions/selected-run-actions.ts`
- `windows/tauri/src/features/run/actions/selected-run-actions.test.ts`
- `windows/tauri/src/features/run/components/title-run-control.tsx`
- `windows/tauri/src/features/run/components/title-run-control.test.tsx`
- `windows/tauri/src/i18n/java-run-control.ts`
- `windows/tauri/src/i18n/locale.ts`
- `windows/tauri/src/features/window/components/title-bar/title-bar.tsx`

- `.github/workflows/ci-windows.yml`

- `windows/tauri/src/features/run/stores/run.store.ts`
- `windows/tauri/src/features/run/actions/selected-run-owner.test.ts`
