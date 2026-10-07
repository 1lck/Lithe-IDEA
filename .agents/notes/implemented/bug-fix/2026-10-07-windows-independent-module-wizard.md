# Agent 笔记：Windows独立模块创建与工作区附加

状态：已实现

## 先说结论

模块向导复用项目脚手架和共享Spring字段，只编排创建与工作区附加。捕获原工作区动作并在异步边界验证归属；成功目录在挂载失败或工作区切换后保留，重试只执行附加。

## 问题

创建子目录后直接打开为新项目会丢失当前工作区；创建成功但附加失败时再次创建又可能覆盖或误删用户文件。

## 决策

模块向导复用项目脚手架和共享Spring字段，只编排创建与工作区附加。捕获原工作区动作并在异步边界验证归属；成功目录在挂载失败或工作区切换后保留，重试只执行附加。

## 考虑过的备选方案

不通过创建后切换根项目模拟模块；不自动改写父POM或Gradle聚合关系；不在附加失败时回滚删除完整用户项目。

## 后果

独立Java/Spring模块可以加入现有工作区；构建聚合和模块依赖仍由用户明确配置。创建者只拥有临时目录的清理权，完成目录归用户所有，不属于构建缓存，也不修改发行安装目录。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/window/services/create-workspace-module.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/file-explorer/stores/new-entry.store.test.ts`

## 适用范围

- `windows/tauri/src/features/window/components/new-module-dialog.tsx`
- `windows/tauri/src/features/window/services/create-workspace-module.ts`
- `windows/tauri/src/features/window/services/create-workspace-module.test.ts`
- `windows/tauri/src/features/file-explorer/stores/new-entry.store.ts`
- `windows/tauri/src/features/file-explorer/stores/new-entry.store.test.ts`
- `windows/tauri/src/features/file-explorer/components/new-entry-dialog-host.tsx`
- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/window/components/window-menu-bar.tsx`
