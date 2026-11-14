# Agent 笔记：CI 构建缓存与测试产物策略

状态：已实现

> 2026-11-08 Viva 迁移：下文的 CI 门禁以当前工作流为准。`desktop-ci.yml` 对 Draft PR 只运行 Linux 格式、脚本和桌面测试，非 Draft 另运行 macOS 与 Windows 测试；旧的 Swift/Tauri 工作流、分片、lane 复用和资源复用脚本的 CI 接线尚未迁移，不能当作当前门禁。

## 先说结论

CI 缓存的是经过版本和依赖约束的中间构建结果（Core 的编译输出和下载依赖），不缓存最终安装包或可执行文件。Draft PR 只跑 Linux 检查，不占用 macOS 和 Windows runner；标记为 ready 后才运行完整的平台测试。组织使用 GitHub Free 计划，全组织同时最多运行 5 个 GitHub 托管 macOS job，所以每次推送占用的 macOS runner 数量本身就是需要控制的成本。

## 问题

Viva 桌面端要在 macOS、Windows 和 Linux 上构建，Rust Core 和 Go 桌面端的耗时来源不同。如果只缓存最终可执行文件，容易复用错误的构建结果，也无法稳定获得测试安装包。

## 决策

- Core 的缓存键必须包含运行器的系统与架构、工具链身份、构建目标、发布或调试配置，以及构建脚本的哈希。发布工作流与自动构建使用同一个 release 档 Core 缓存键，因此自动构建通常能复用前一晚的 Core 编译结果。
- 只缓存 Cargo 的依赖、编译中间产物和构建脚本输出，不缓存最终可执行文件，也不缓存整个增量编译目录。最终打包仍然重新运行必要的构建步骤，保证产物来自当前源码。
- Draft PR 关闭所有 macOS 和 Windows 测试，只保留 Linux 上的分类、格式、脚本和桌面测试；PR 标记为 ready for review 时重新触发完整检查。
- 关闭或合并 PR 时，清理工作流按来源仓库、来源分支和关闭时间查找所有历史运行，不能只查最后一次提交。清理使用 GitHub 的强制取消接口，避免旧运行继续占用托管 runner。取消失败只有在运行已经结束时才视为正常竞争；权限或 API 故障必须使清理检查失败，不能伪装成清理成功。保留关闭后创建的运行、其他来源仓库和非 PR 事件。
- 同一个 PR 的运行共享 concurrency group，新提交取消旧运行。`main` 的 push 使用独立的 concurrency group，`cancel-in-progress: false`，每个提交都完整运行。
- 取消不算验证通过。当前工作流未被取消时，即使测试失败，汇总检查也必须执行并失败；不能在 shell 中把取消结果转换为成功。
- Windows 的 Core 克隆使用 `--no-checkout`。即使克隆的 HEAD 已经等于固定修订，也必须在没有 Git 索引时检出工作树；否则 Cargo 清单不存在。这个恢复不使用 `--force`，冲突的未跟踪文件会阻止检出。已有索引的工作树如果缺少清单则报错，不静默恢复用户删除的文件。
- Windows 的 Rust 静态库依赖 Cargo crate 提供的导入库，不能只传系统库名称给 Go 链接器。桌面构建入口读取对应 target/profile 的 Cargo 构建输出，把实际使用的导入库目录加入链接搜索路径；相同库名对应不同字节时拒绝构建，避免误用旧缓存。路径按 Go 的参数解析规则整体引用，包含空格的目录也可使用。
- 只有 Node 脚本、没有外部依赖的工作流不为了打开 `cache` 而引入不存在的 lockfile；Bun 的真实依赖缓存保留。

## 考虑过的备选方案

### 缓存最终可执行文件

可以减少部分打包时间，但容易受到源码、编译器、SDK 和构建参数变化影响，也会掩盖当前提交是否真正完成构建，因此不采用。

### 只缓存下载依赖

能减少网络等待，但无法覆盖 Rust Core 的主要编译成本，因此扩展为缓存 Cargo 的中间输出和构建脚本结果。

### 对 preview 推送关闭 cancel-in-progress

能让每次推送都跑完并保存缓存，但连续合并时 runner 分钟数成倍增加，后续推送要排队等待前一次完成，因此保留取消旧运行。

### 所有 PR 都强制生成完整安装包

会增加文档和不需要产品包的改动的构建时间与存储成本。安装包不是合并判断的输入，因此 PR 只运行测试，需要安装包时手动运行发布工作流。

### 在 PR 中等待完整的 Release 编译

Release 编译和打包会把反馈推迟到最慢的任务结束。Draft PR 和普通 PR 只需要测试结果，发布工作流负责产出安装包。

## 后果

- 普通 PR 更快得到检查结果；Draft PR 迭代期间不占 macOS 和 Windows runner。
- 缓存命中可以减少 Core 的重复编译，同时通过完整缓存键避免跨环境误复用。
- 冷构建、编译器变化、依赖变化和 runner 排队仍可能很慢，不能把缓存策略当作总耗时保证。
- 工作流调整时必须同步检查缓存键、gate 依赖和平台矩阵。

## 验证

- `make -C desktop check`：当前 macOS 本机的格式、vet 和 Go 测试；它不证明 GitHub Actions 或 Windows 已通过。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestDesktopGoFindsWindowsCargoImportLibraries$'`：受控 Cargo 输出夹具验证导入库发现、带空格路径和冲突拒绝；Windows 实机仍须编译与链接实际 Core。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestBuildDesktopCoreChecksOutFreshPinnedRevision$'`：使用本地 Git 仓库和编译器替身验证空工作树检出，并确认不会恢复已有工作树中主动删除的文件。
- `node --test scripts/ci/cancel-closed-pr-runs/cancel-closed-pr-runs.test.mjs`：用离线 GitHub CLI 替身验证关闭清理，覆盖分页历史运行、来源隔离、关闭时间、取消竞争和 API 失败传播。
- 真实的 CI 和发布流程需要在 GitHub 上分别验收，离线测试不能替代。

## 适用范围

- `.github/workflows/desktop-ci.yml`
- `.github/workflows/desktop-release.yml`
- `.github/workflows/desktop-autobuild.yml`
- `.github/actions/setup-desktop-windows-build-tools/action.yml`
- `scripts/desktop/build-desktop-core.sh`
- `scripts/desktop/desktop-go.sh`
- `scripts/ci/cancel-closed-pr-runs/`
- `docs/ci-builds.md`
