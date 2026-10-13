# Agent 笔记：Windows 普通 Java 文件的运行配置生成

状态：已实现

## 先说结论

入口事实继续由Java开发工具语言服务（JDT）提供。缺少配置时先保存、预热语言服务并重新请求当前文件入口，核实类名后通过既有Run配置生成入口合并；异步边界检查工作区身份，不扫描源码猜测main。

## 问题

JDT工作区入口搜索可能遗漏默认或不可见项目中的单文件，但当前文件仍有有效main标记，旧流程只重做工作区搜索而无法运行。

## 决策

入口事实继续由Java开发工具语言服务（JDT）提供。缺少配置时先保存、预热语言服务并重新请求当前文件入口，核实类名后通过既有Run配置生成入口合并；异步边界检查工作区身份，不扫描源码猜测main。

## 考虑过的备选方案

只重复工作区搜索不能覆盖单文件；用正则扫描或手工拼主类会复制JDT语义，因此不采用。

## 后果

单文件可生成命名配置；新增准备等待与明确错误。复用原有Run编译和启动流程，不改变运行时缓存位置，也不保证工作区自动扫描能列出全部未管理源文件。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/run/services/java-main-launch.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/run/services/java-context-entrypoint.test.ts`
- `node scripts/verify-java-semantic-ownership.mjs`

## 适用范围

- `windows/tauri/src/features/run/services/java-main-launch.ts`
- `windows/tauri/src/features/run/services/java-main-launch.test.ts`
- `windows/tauri/src/features/run/services/java-context-entrypoint.ts`
- `windows/tauri/src/features/run/services/java-context-entrypoint.test.ts`
- `windows/tauri/src/features/run/stores/run.store.ts`
