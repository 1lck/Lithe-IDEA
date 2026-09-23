# Agent 笔记：工作树资源复用边界

状态：已实现

## 先说结论

Git linked worktree 之间只复用校验过的下载缓存，不共享 `.build` 或旧预览应用。
目标工作树仍须自己编译，并在打包预览应用时复制两种 SwiftPM 资源包。
漏掉应用自己的资源包会让使用内置工作台背景的应用在启动时崩溃。

## 问题

每个工作树的 `.artifacts` 相互独立，反复下载 JDTLS、JDK、Cargo、SwiftPM 和 Bun
资源会拖慢开发。直接搬运构建产物则无法保证其源码、工具链和平台与目标工作树匹配。

下载缓存可用也不等于预览应用可用。`scripts/preview.sh` 曾只复制
`SwiftTerm_SwiftTerm.bundle`，漏掉 `Lithe_Lithe.bundle`；当已选择内置工作台背景时，
应用初始化读取 `Bundle.module` 会因资源包不存在而崩溃。漏拷资源在工作树复用机制
出现前就已存在，切换工作树或再次运行旧脚本只是让这一缺口重新暴露。

## 决策

`scripts/reuse-worktree-resources.mjs` 只从同一 Git 仓库的另一工作树复制
`scripts/worktree-resources.json` 登记的 `.artifacts` 子目录。资源先进入目标临时目录，
由 `scripts/verify-download-cache.mjs` 根据目标工作树的 manifest、lockfile、版本和
完整性信息验证，再发布到目标缓存。不要把 `.build`、解压后的工具目录或旧 `.app`
加入可复用清单；这些内容必须在目标工作树重新生成。

SwiftPM 下载缓存保存依赖，不包含应用编译后需要的资源包。`scripts/preview.sh` 和
`scripts/package-app.sh` 应从当前工作树的构建目录复制 `Lithe_Lithe.bundle` 与
`SwiftTerm_SwiftTerm.bundle`，缺少任一资源包就应在启动前报错。
`scripts/verify-macos-app-build-safety.sh` 检查两个打包脚本均声明这两种资源。
正确做法是切换工作树后重新运行预览脚本并检查新包；不要继续运行此前生成的 `.app`。

## 考虑过的备选方案

### 共享整个 `.artifacts`、`.build` 或旧预览应用

省去复制和编译，但两棵工作树可能同时修改缓存，可执行文件也可能与当前源码不匹配。
旧预览应用缺少资源时，切换工作树不会修复它，因此拒绝。

### 所有资源都重新下载

隔离最简单，但重复下载大体积 Java 工具和依赖会拖慢切换；只对没有可靠校验身份的
生成产物保留重新构建策略。

## 后果

可验证的下载资源能复用，源码和平台相关的构建状态保持隔离。代价是每个目标工作树
仍需自行编译、打包，并维护资源清单和校验器。脚本更新也不会修改已生成的旧 `.app`；
遇到启动崩溃时应先核对二进制构建身份、资源目录和实际运行的工作树，不要只看当前分支。

## 验证

- `node scripts/test-verify-download-cache.mjs`
- `node scripts/test-reuse-worktree-resources.mjs`
- `./scripts/verify-macos-app-build-safety.sh`：确认两个打包脚本均声明所需资源包。
- `./scripts/preview.sh`：检查新包包含 `Lithe_Lithe.bundle`，并在内置背景设置下启动。
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `scripts/reuse-worktree-resources.mjs`
- `scripts/worktree-resources.json`
- `scripts/verify-download-cache.mjs`
- `scripts/preview.sh`
- `scripts/package-app.sh`
- `scripts/verify-macos-app-build-safety.sh`
- `docs/ci-builds.md`
