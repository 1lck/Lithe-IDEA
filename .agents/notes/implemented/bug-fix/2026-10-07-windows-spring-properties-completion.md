# Agent 笔记：Windows Spring 配置键补全与依赖刷新

状态：已实现

## 先说结论

配置键与描述仍由既有Core Spring元数据索引提供。前端只计算键范围和编辑建议，限制application及profile properties、当前项目和键位置。索引请求持续携带依赖仓库，并订阅Java语言服务就绪变化来刷新。

## 问题

properties由Monaco的ini tokenizer处理，不能依赖Java或YAML语言服务补全；索引重载不携带元数据仓库会丢失依赖配置项。

## 决策

配置键与描述仍由既有Core Spring元数据索引提供。前端只计算键范围和编辑建议，限制application及profile properties、当前项目和键位置。索引请求持续携带依赖仓库，并订阅Java语言服务就绪变化来刷新。

## 考虑过的备选方案

复用Java/YAML补全无法覆盖ini模型；在前端扫描依赖并维护另一份Spring字典会复制语义，均不采用。

## 后果

输入时保留依赖键建议，避免跨项目与值位置误补全。增加一个前端补全provider和就绪订阅，取消加载时释放订阅；不更改资源编译复制和安装目录。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/spring/utils/spring-property-completion.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/spring/hooks/use-spring-index.test.tsx`

## 适用范围

- `windows/tauri/src/features/spring/hooks/use-spring-index.ts`
- `windows/tauri/src/features/spring/hooks/use-spring-index.test.tsx`
- `windows/tauri/src/features/spring/utils/spring-property-completion.ts`
- `windows/tauri/src/features/spring/utils/spring-property-completion.test.ts`
- `windows/tauri/src/features/editor/engines/monaco/lsp-providers.ts`
