# Agent 笔记：Windows选中运行配置工具栏与动作归属

状态：已实现

## 先说结论

工具栏观察既有Run配置、运行会话、调试会话和发现诊断。共享动作捕获配置与工作区身份，在准备边界检查取消；Java调试复用已有Maven/JDT和DAP入口，Stop依据选中配置的会话拥有者释放。

## 问题

标题栏缺少命名配置与直接Debug入口；按当前焦点终端或全局运行布尔值执行Stop和Rerun，会干扰另一配置或工作区拥有的进程。

## 决策

工具栏观察既有Run配置、运行会话、调试会话和发现诊断。共享动作捕获配置与工作区身份，在准备边界检查取消；Java调试复用已有Maven/JDT和DAP入口，Stop依据选中配置的会话拥有者释放。

## 考虑过的备选方案

不根据当前终端焦点停止进程；不为了下拉框重新扫描Java入口；不对所有语言显示可用的Debug；不为每个按钮复制清理协议。

## 后果

新增临时操作和错误状态以及选中动作测试。Java/Spring可从命名配置Run/Debug；不额外添加重复设置齿轮，保留下拉Edit与全局设置。运行临时资源沿用既有会话所有者与清理边界，不修改安装目录。

## 验证

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
