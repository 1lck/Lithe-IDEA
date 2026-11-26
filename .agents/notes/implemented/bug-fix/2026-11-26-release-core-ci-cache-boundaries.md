# Agent 笔记：release Core 缓存不能绕过源码完整性检查

状态：已实现

## 先说结论

Desktop CI 使用 release Core 后，冷 Core 构建必须先在有独立时限的构建步骤完成，不能藏在五分钟视觉证据步骤里隐式发生。已暂存 Core 的快路径可以跳过 git 和 cargo，但如果已有 Core 源码检出的 `rust/Cargo.toml` 被删除，快路径不得直接成功；测试进程还必须隔离 CI 的 `LITHE_DESKTOP_CORE_PROFILE`，否则 debug fixture 会按 release 路径查找。

## 问题

#2446 让 Desktop CI 共用 release Core 缓存，macOS、Windows 和 Linux 的 main CI 随后持续失败。三类失败看似独立，实际都出在缓存边界：测试继承了 CI 的 profile、暂存快路径绕过了源码完整性检查、冷构建没有自己的步骤时限。同一轮 main CI 还暴露了 runtime bundle 自测fixture没有跟上脚本新增的安装包工作流。

## 决策

1. `desktop/internal/core/desktop_go_test.go` 的子进程 fixture 明确过滤 `LITHE_DESKTOP_CORE_PROFILE`，测试要验证的路径不受外层 CI 配置影响。
2. `scripts/desktop/build-desktop-core.sh` 的暂存快路径先检查已有源码 checkout 的 manifest 是否仍然存在。源码 checkout 不存在时，stage-only 缓存仍可直接复用；源码 checkout 存在但 manifest 缺失时，继续走普通路径并在原有错误处失败，不能静默修复或掩盖删除。
3. Linux Desktop CI 在第一个 `desktop-go.sh` 测试步骤前增加独立的 `Build release Core` 步骤。该步骤有 25 分钟上限；命中 staged cache 时立即返回，冷构建不会占用视觉证据步骤的 5 分钟预算。
4. `test-runtime-bundle-immutability.mjs` 的 fixture 清单必须与验证脚本要求的安装包工作流一致，包括 devcontainer 远程配置条目。

## 考虑过的备选方案

### 只重跑 CI 或等待缓存热起来

冷缓存会在每次 pin、工具链或缓存 key 变化后重现。只靠重跑不能防止同一个五步视觉步骤再次承担完整 release Core 构建，因此没有采用。

### 删除 manifest 完整性测试或接受快路径成功

暂存产物可能仍然完整，但已有 checkout 中删除 manifest 是明确的源码损坏状态。让构建成功会隐藏这个状态，还会削弱“不得背着用户修复 checkout”的保护，因此没有采用。

### 给视觉证据步骤继续延长超时

延长时间会让编译、测试和截图共用一个模糊预算，失败后仍难分辨是构建慢还是测试卡住。独立步骤保留各自时限和日志边界，因此没有采用。

## 后果

冷 release Core 构建有明确归属和时限，stage 缓存命中后不会重复编译；已有源码 checkout 的删除不会被快路径掩盖。代价是存在源码 checkout 时，快路径需要额外检查一个 manifest 文件；这个成本可以忽略。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/core -run '^(TestDesktopGoFindsWindowsCargoImportLibraries|TestBuildDesktopCoreChecksOutFreshPinnedRevision)$' -count=1 -v`
- `./scripts/desktop/desktop-go.sh test ./internal/core -count=1`
- `./scripts/desktop/desktop-go.sh test ./internal/core -run '^(TestDesktopGoFindsWindowsCargoImportLibraries|TestBuildDesktopCoreChecksOutFreshPinnedRevision)$' -race -count=1`
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `node --test scripts/desktop/verify/test-runtime-bundle-immutability.mjs`
- `shellcheck -S warning scripts/desktop/build-desktop-core.sh scripts/desktop/desktop-go.sh`
- `actionlint .github/workflows/desktop-ci.yml`

## 适用范围

- `.github/workflows/desktop-ci.yml`
- `scripts/desktop/build-desktop-core.sh`
- `scripts/desktop/desktop-go.sh`
- `desktop/internal/core/desktop_go_test.go`
- `scripts/desktop/verify/test-runtime-bundle-immutability.mjs`
