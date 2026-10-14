# Agent 笔记：Windows Java与Spring项目创建向导

状态：已实现

## 先说结论

复用现有新项目向导与官方Spring Initializr元数据。Windows适配器负责有界网络读取、安全解压、同父目录暂存和排他发布；普通Java模板只是初始文件，不代替JDT项目模型。版本及依赖由Initializr决定，向导不运行下载的脚本。

## 问题

新项目入口缺少普通Java和Spring Boot；固定的版本与依赖目录易过期，直接解压到目标目录还可能覆盖既有文件或遗留半成品。

## 决策

复用现有新项目向导与官方Spring Initializr元数据。Windows适配器负责有界网络读取、安全解压、同父目录暂存和排他发布；普通Java模板只是初始文件，不代替JDT项目模型。版本及依赖由Initializr决定，向导不运行下载的脚本。

审查补充：每次创建由组件内的请求身份拥有。关闭、卸载或生成阶段切换工作区使旧请求退役；每个异步边界后检查身份，旧成功/错误/finally 不打开工作区、不覆盖新 UI、不释放新请求。已经发出的原生生成不承诺取消，完成的用户项目不删除；已经发出的工作区打开仍由既有工作区生命周期管理。焦点定时器在作用域结束时释放。

原生检查把父目录和可执行文件都 canonicalize，再用既有 same-file 的目录句柄身份比较父目录祖先，处理 Windows 普通路径、扩展长度前缀、大小写及目录链接；无法确认安装目录时失败关闭，在网络请求前和暂存发布前分别验证。不是字符串 startsWith，也不修改真实安装目录。

外层关闭补充：ProjectPicker 在调用宿主关闭回调之前，通过组件的取消句柄同步退役当前创建请求，覆盖真实 Command 的 Escape/遮罩及其他统一关闭入口。不修改共享动画，也不依赖150毫秒后卸载清理。回归使用真实 ProjectPicker / Command / Base UI，手动保留宿主可见性确认以确保旧子树仍挂载，然后完成或拒绝生成；不模拟 Command、不用真实时间睡眠。这验证 dismissal-to-unmount 边界，不宣称实机动画验收。

## 考虑过的备选方案

不使用整个 Windows 路径 lower-case 后的字符串比较替代文件身份；不将测试链接写入真实安装目录；不维护另一份固定Spring版本目录；不调用shell拼接下载命令；不直接解压进已存在的目标。

## 后果

增加网络依赖与Windows文件发布适配代码；超时/体积/条目边界使失败可控。所有暂存与生成文件归用户所选父目录，成功项目不因打开失败而删除；不写入安装目录，且禁止跨构建工作树复用用户项目。

## 验证

原有 location / Initializr / Java 命名及新的实际组件异步回归均列入 Windows CI，保留上游已有命名测试登记，避免重复执行。组件测试复用真实创建流程，视觉控件与原生 IO 使用可控替身，不代表 WebView2 或实时服务 GUI 验收。Windows 目录链接测试为显式 opt-in（需要符号链接权限或开发者模式），不计入默认单元测试通过数。

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/window/components/new-project-creation.test.tsx`

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

- `windows/tauri/src/features/window/components/new-project-creation.test.tsx`
- `.github/workflows/ci-windows.yml`

- `windows/tauri/src/features/window/components/project-picker.tsx`
- `windows/tauri/src/features/window/components/project-picker-creation.test.tsx`
