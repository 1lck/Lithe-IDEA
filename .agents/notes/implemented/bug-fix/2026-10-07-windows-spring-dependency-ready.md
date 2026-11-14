# Agent 笔记：Spring依赖索引消费实际Java就绪事件

状态：已实现

## 先说结论

Spring订阅接受serviceReady与历史fullyReady，只在非就绪到就绪的边缘触发。用现有工作区Java会话快照选owner，复用hook既有刷新合并与清理，不改Core协议或新增扫描。

## 问题

Core适配器把ready映射为serviceReady，Spring默认订阅仅等待fullyReady；原有测试注入回调而未覆盖真实LSP store，导致导入后的依赖刷新漏掉。

## 决策

Spring订阅接受serviceReady与历史fullyReady，只在非就绪到就绪的边缘触发。用现有工作区Java会话快照选owner，复用hook既有刷新合并与清理，不改Core协议或新增扫描。

## 考虑过的备选方案

不修改适配器全局事件命名，不让每次store变更触发全仓库刷新，也不继续用替代ready回调证明生产订阅。

## 后果

新增生产订阅的真实store集成回归，并在Windows CI登记现有Spring属性与hook套件。失败恢复后可以再次刷新；卸载释放订阅；不解决target/classes新鲜度，不宣称macOS/GUI或实时JDT导入验收。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/spring/utils/spring-property-completion.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/spring/hooks/use-spring-index.test.tsx`

## 适用范围

- ~~`windows/tauri/src/features/spring/hooks/use-spring-index.ts`~~（已随 #1794 移除）
- ~~`windows/tauri/src/features/spring/hooks/use-spring-index.test.tsx`~~（已随 #1794 移除）
- ~~`.github/workflows/ci-windows.yml`~~（已随 #1794 移除）
- ~~`shared/platform-feature-matrix/features/spring-index.json`~~（已随插件归属规则移出宿主，见 [插件的测试、功能矩阵和翻译只在插件仓库](../architecture/2026-11-14-plugin-owned-tests-matrix-i18n.md)）
