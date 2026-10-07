# Agent 笔记：Windows Java与Spring项目创建向导

状态：已实现

## 先说结论

复用现有新项目向导与官方Spring Initializr元数据。Windows适配器负责有界网络读取、安全解压、同父目录暂存和排他发布；普通Java模板只是初始文件，不代替JDT项目模型。版本及依赖由Initializr决定，向导不运行下载的脚本。

## 问题

新项目入口缺少普通Java和Spring Boot；固定的版本与依赖目录易过期，直接解压到目标目录还可能覆盖既有文件或遗留半成品。

## 决策

复用现有新项目向导与官方Spring Initializr元数据。Windows适配器负责有界网络读取、安全解压、同父目录暂存和排他发布；普通Java模板只是初始文件，不代替JDT项目模型。版本及依赖由Initializr决定，向导不运行下载的脚本。

## 考虑过的备选方案

不维护另一份固定Spring版本目录；不调用shell拼接下载命令；不直接解压进已存在的目标。

## 后果

增加网络依赖与Windows文件发布适配代码；超时/体积/条目边界使失败可控。所有暂存与生成文件归用户所选父目录，成功项目不因打开失败而删除；不写入安装目录，且禁止跨构建工作树复用用户项目。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/window/lib/new-project-location.test.ts`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/window/lib/spring-initializr.test.ts`
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml project_scaffold::tests`
- `node scripts/test-reuse-worktree-resources.mjs`

## 适用范围

- `windows/tauri/src/features/window/components/new-project-content.tsx`
- `windows/tauri/src/features/window/components/spring-project-fields.tsx`
- `windows/tauri/src/features/window/lib/new-project-model.ts`
- `windows/tauri/src/features/window/lib/new-project-location.test.ts`
- `windows/tauri/src/features/window/lib/spring-initializr.ts`
- `windows/tauri/src/features/window/lib/spring-initializr.test.ts`
- `windows/tauri/src-tauri/src/project_scaffold.rs`
