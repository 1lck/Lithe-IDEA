# Agent 笔记：工作树资源复用边界

状态：已实现

## 先说结论

Git linked worktree 之间只复用经过现有校验器验证的下载缓存，不共享可变构建状态或整个
`.artifacts`。复用脚本把源资源复制到目标临时目录，校验通过后原子发布，并在发布失败时
保留或恢复目标原缓存；一个资源失败不会阻止其他资源继续处理。以后新增资源必须同时更新
注册表、校验路由、测试和操作文档。预览应用仍须在目标工作树重新构建并打包自身资源，
不能复用另一工作树的 `.build` 或旧 `.app`。

## 问题

每个 linked worktree 都有自己的 `.artifacts`，重复下载 JDTLS、JDK、Cargo、SwiftPM 或 Bun
资源会拖慢本地编译。直接共享整个目录又会把当前源码、平台、工具链不匹配的状态带入另一棵
工作树；复制过程被中断时还可能留下锁目录和临时目录，影响下一次复用。

下载缓存和可运行的预览包不是同一种资源。曾有 `scripts/preview.sh` 只复制
`SwiftTerm_SwiftTerm.bundle`，漏掉应用自己的 `Lithe_Lithe.bundle`；选择内置工作台背景后，
启动时读取 `Bundle.module` 会因缺少资源包而直接崩溃。这是预览打包脚本已有的缺口，
不是工作树资源复用脚本引入的错误；切换工作树或重新运行旧脚本会再次暴露它。

## 决策

`scripts/reuse-worktree-resources.mjs` 只接受同一 Git 仓库的真实 linked worktree，并从
`scripts/worktree-resources.json` 读取允许复用的 `.artifacts` 子目录。每个资源先复制到
目标目录旁的 staging 目录，再调用 `scripts/verify-download-cache.mjs` 使用目标工作树的
manifest、lockfile、版本或完整性清单校验。目标已有缓存时，校验器可能先就地删除不匹配内容；
只有源缓存包含更多已验证文件时才原子替换目标。

发布使用显式状态记录：只有旧目标目录已经成功 rename 到 backup 后，失败路径才会删除新
目标并恢复 backup；备份 rename 失败时保留原目标目录。资源循环逐项捕获错误，Bun 不存在或
版本不符按跳过处理，其余失败汇总后以非零退出，但不吃掉后续资源。锁目录写入 PID 和时间，
锁竞争错误会提示操作者确认没有其他复用进程后清理锁；成功取得锁后会清理同资源的孤儿
`*.staging-*` 与 `*.backup-*` 目录。

SwiftPM 下载缓存只用于获取依赖，`.build` 内的编译产物仍由各工作树独立生成。
`scripts/preview.sh` 与 `scripts/package-app.sh` 必须从当前工作树的构建目录显式复制
`Lithe_Lithe.bundle` 和 `SwiftTerm_SwiftTerm.bundle` 到应用资源目录，缺失时在启动前失败；
`scripts/verify-macos-app-build-safety.sh` 检查两个打包脚本均声明这两种资源。正确做法是在目标工作树
重新构建预览包并检查其资源目录，不要把另一工作树的 `.build` 或旧 `.app` 当作可复用缓存。

## 考虑过的备选方案

### 直接共享或软链整个 `.artifacts`

省去复制时间，但会让两个 worktree 共同修改缓存、构建输出和 LSP 状态；源码或工具链变化
时无法判断哪些结果仍可信，因此拒绝。

### 把缓存移到仓库外的全局目录

能减少复制，但改变 CI 和本地脚本已有的缓存落点，且不同仓库、分支和平台会争用同一目录；
不符合当前下载校验器以工作树路径为边界的行为，因此暂不采用。

### 不做复用，每个 worktree 重新下载

实现最简单且隔离性最好，但重复下载大体积 Java 资源会让工作树切换的等待时间不可接受，
因此只对没有可靠 identity 校验的生成状态保持这一策略。

## 后果

收益是源工作树保持只读，目标发布具有失败恢复路径，工具链缺失不会阻断其他资源，残留目录
可在下一次成功加锁后清理。代价是目标缓存比较不是纯只读操作，校验器可能裁剪无效内容；新增
资源仍需维护注册表、校验路由、测试和文档四处同步，并且锁被外部终止后需要人工确认再删除。
目标工作树仍需编译和打包，已生成的旧 `.app` 不会因为脚本更新而自动修复；启动崩溃时应先
核对运行中的二进制构建身份、预览包资源和当前工作树，避免在无关分支上修复后继续运行旧包。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `node scripts/test-verify-download-cache.mjs`
- `node scripts/test-reuse-worktree-resources.mjs`
- `./scripts/verify-macos-app-build-safety.sh`：确认预览与正式打包脚本均要求两种 SwiftPM 资源包。
- `./scripts/preview.sh`：确认目标工作树生成的预览包含 `Lithe_Lithe.bundle`，且内置背景设置下能够启动。
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `scripts/reuse-worktree-resources.mjs`
- `scripts/worktree-resources.json`
- `scripts/verify-download-cache.mjs`
- `scripts/test-reuse-worktree-resources.mjs`
- `scripts/preview.sh`
- `scripts/package-app.sh`
- `scripts/verify-macos-app-build-safety.sh`
- `docs/ci-builds.md`
