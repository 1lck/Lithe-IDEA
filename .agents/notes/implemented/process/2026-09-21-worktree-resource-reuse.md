# Agent 笔记：工作树资源复用边界

状态：已实现

## 先说结论

Git linked worktree 之间只复用校验过的下载缓存，不共享 `.build`、解压后的工具目录或旧的应用包。目标工作树仍须自己编译和打包；桌面端的构建资源（例如 Core 静态库）只从本工作树的构建输出生成。

## 问题

每个工作树的 `.artifacts` 相互独立，反复下载 JDK、Cargo、Go 模块等资源会拖慢开发。直接搬运构建产物则无法保证其源码、工具链和平台与目标工作树匹配。

下载缓存可用也不等于构建产物可用：旧的应用包和编译结果可能与当前源码不一致，切换工作树后再次运行旧脚本只会让这种不一致重新暴露。

## 决策

`scripts/resources/reuse-worktree-resources.mjs` 只从同一 Git 仓库的另一工作树复制 `scripts/resources/worktree-resources.json` 登记的 `.artifacts` 子目录。资源先进入目标临时目录，由 `scripts/resources/verify-download-cache.mjs` 根据目标工作树的 manifest、lockfile、版本和完整性信息验证，再发布到目标缓存。

不要把 `.build`、解压后的工具目录或旧的应用包加入可复用清单；这些内容必须在目标工作树重新生成。运行状态和可变构建状态同样不得登记为可复用资源。

切换工作树后应重新构建，不要继续运行此前生成的应用包。

## 考虑过的备选方案

### 共享整个 `.artifacts`、`.build` 或旧应用包

省去复制和编译，但两棵工作树可能同时修改缓存，可执行文件也可能与当前源码不匹配。旧应用包缺少资源时，切换工作树不会修复它，因此拒绝。

### 所有资源都重新下载

隔离最简单，但重复下载大体积工具和依赖会拖慢切换；只对没有可靠校验身份的生成产物保留重新构建策略。

## 后果

可验证的下载资源能复用，源码和平台相关的构建状态保持隔离。代价是每个目标工作树仍需自行编译、打包，并维护资源清单和校验器。
新增或修改资源时，必须同步更新资源清单、校验路由和 `docs/ci-builds.md` 的“独立工作树的本地编译”章节。

## 验证

- `node scripts/resources/test-verify-download-cache.mjs`
- `node scripts/resources/test-reuse-worktree-resources.mjs`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `scripts/resources/reuse-worktree-resources.mjs`
- `scripts/resources/worktree-resources.json`
- `scripts/resources/verify-download-cache.mjs`
- `docs/ci-builds.md`
