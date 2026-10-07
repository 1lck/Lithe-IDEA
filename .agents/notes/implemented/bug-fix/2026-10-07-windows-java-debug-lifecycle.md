# Agent 笔记：Windows Java调试状态与资源生命周期

状态：已实现

## 先说结论

使用宿主既有request信封；在launch前同步断点。Core规范化事件进入同一暂停/继续状态处理，线程列表不能覆盖实际停止线程。调试器动作共享停止与线程请求所有者，并发释放等待同一Promise；Maven调试准备检查取消和工作区归属，编辑器装饰只观察既有调试状态。

## 问题

DAP请求参数与宿主信封不匹配、断点入队晚于启动、继续和单步异步回执覆盖新暂停状态，以及重复Stop提前返回，都能造成界面和实际会话矛盾。

## 决策

使用宿主既有request信封；在launch前同步断点。Core规范化事件进入同一暂停/继续状态处理，线程列表不能覆盖实际停止线程。调试器动作共享停止与线程请求所有者，并发释放等待同一Promise；Maven调试准备检查取消和工作区归属，编辑器装饰只观察既有调试状态。

## 考虑过的备选方案

不在前端重写DAP初始化或configurationDone；不按当前焦点终端停止进程；不在每个按钮里复制清理流程；不通过固定延迟等待下一次暂停。

## 后果

前端与适配器状态更一致；增加清理并发与过期响应测试。启动的进程/监听/装饰按会话释放，不改写安装目录。快捷键重新映射和选中配置工具栏是后续独立改动，不宣称完整IDEA调试能力。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/services/debug-adapter-service.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/services/debug-adapter-events.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/services/debug-session-resources.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/services/debug-session-actions.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/services/monaco-debug-decorations.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/maven/services/maven-module-debug.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/run/hooks/use-run-process-events.test.ts`

## 适用范围

- `windows/tauri/src/features/debugger/services/debug-adapter-service.ts`
- `windows/tauri/src/features/debugger/services/debug-adapter-service.test.ts`
- `windows/tauri/src/features/debugger/services/debug-adapter-events.ts`
- `windows/tauri/src/features/debugger/services/debug-adapter-events.test.ts`
- `windows/tauri/src/features/debugger/services/debug-session-resources.ts`
- `windows/tauri/src/features/debugger/services/debug-session-resources.test.ts`
- `windows/tauri/src/features/debugger/services/debug-session-actions.ts`
- `windows/tauri/src/features/debugger/services/debug-session-actions.test.ts`
- `windows/tauri/src/features/debugger/services/monaco-debug-decorations.ts`
- `windows/tauri/src/features/debugger/services/monaco-debug-decorations.test.ts`
- `windows/tauri/src/features/debugger/components/debugger-view.tsx`
- `windows/tauri/src/features/maven/services/maven-module-debug.ts`
- `windows/tauri/src/features/maven/services/maven-module-debug.test.ts`
- `windows/tauri/src/features/run/hooks/use-run-process-events.ts`
- `windows/tauri/src/features/run/hooks/use-run-process-events.test.ts`
- `windows/tauri/src/features/editor/styles/monaco-editor.css`
- `windows/tauri/src/features/editor/components/monaco-editor.tsx`
