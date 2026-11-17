# Agent 笔记：工作树缓存复用改由 Agent 按 Skill 提醒判断

状态：已实现

## 先说结论

仓库不再提供跨工作树复制资源的脚本。#2002 删除了 `scripts/resources/` 下的复用脚本、资源清单和下载缓存校验器。新工作树编译前，Agent 按 `develop-lithe` Skill 的“工作树缓存复用”一节自己判断：来源版本一致时，用 APFS 克隆复制已有工作树的 `.artifacts/desktop`，再照常运行构建脚本，由脚本自己的身份检查决定重编什么。

开发者需要知道两件事：Go 和 Cargo 的全局缓存本来就是共享的，不用管；新增下载、解压、生成或缓存资源时，只需在 `docs/ci-builds.md`“独立工作树的本地编译”一节写清能否复制、复制的前提，不再登记清单。

## 问题

旧方案（已归档的 2026-09-21“工作树资源复用边界”）用一份资源清单登记可复用的下载缓存，复制前由校验器按目标工作树的 lockfile 和 manifest 检查完整性。到 #2002 时，清单登记的 4 个可复用缓存全部失效：

- `cargo`（`.artifacts/cargo-home/registry/cache`）：Core 移到独立仓库后，构建脚本不再设置 `CARGO_HOME`，Cargo 直接用用户目录下的 `~/.cargo/registry`，这个目录不会再出现。
- `swiftpm`、`bun`：Swift 客户端和 Bun 前端已经移除，校验器依赖的 manifest 和 lockfile 都不存在。
- `conpty`：ConPTY 改为随包携带、运行时放进用户缓存目录，不再下载到 `.artifacts/conpty-downloads`。

剩下的约 50 条清单项全部是“排除项”，只为了让复用脚本拒绝复制；配套的校验器有 560 多行，复用脚本 500 多行，再加两份测试。脚本已经复制不了任何东西，却要求每个新增资源都改清单、改校验路由、跑测试，规则散落在 AGENTS.md、Skill、PR 模板、审查规则和十几篇 Note 里。

另一方面，新工作树第一次编译 Core 确实慢，真正值得复用的是 `.artifacts/desktop` 下的 Core 编译结果，而旧清单把它列为排除项。

## 决策

1. 删除 `scripts/resources/` 下全部脚本、清单和测试，归档旧 Note。
2. 在 `develop-lithe` Skill 第七节新增“工作树缓存复用”，写明 Agent 自己判断时要遵守的规则：
   - 全局缓存（Go 模块与构建缓存、`~/.cargo/registry`）已自动共享，不挪进 `.artifacts`。
   - 只复制、不共享：macOS 用 `cp -cR` 做 APFS 克隆，不用符号链接、硬链接或共用目录；源工作树正在编译时不复制。
   - 只在 `PINNED_CORE_REVISION`、`desktop/go.mod` 固定的 Viva 版本、平台、架构和工具链都一致时复制。
   - 复制后照常运行构建脚本，结果异常就删掉复制的目录重新编译。
   - 运行时状态、用户数据、日志、插件安装与状态目录、LSP workspace 状态、测试报告和截图一律不复制。
3. AGENTS.md 只保留一条提醒，指向 Skill；`docs/ci-builds.md`“独立工作树的本地编译”一节继续逐项写资源的归属、生命周期和能否复制。

Core 编译结果之所以可以复制，是因为 `scripts/desktop/build-desktop-core.sh` 已经有两道身份检查：`identity.txt` 记录 Core 版本、dirty 标记、rustc、target 和 profile；`lithe-core-built-from-<target>-<profile>.txt` 记录编译时的 Core 源码目录，目录变了就对 Core 自己的 workspace 运行 `cargo clean --workspace`，第三方依赖的编译结果保留。复制后的工作树因此不会用上另一份源码编出的 Core。

## 考虑过的备选方案

### 保留脚本，清单只留空的可复用集合

脚本和校验器还能跑，但没有任何资源可以复制，等于只保留维护成本，因此拒绝。

### 恢复 Cargo 缓存：把 `CARGO_HOME` 设回 `.artifacts`

能让旧的 `cargo` 条目重新生效，但 `~/.cargo/registry` 已经在所有工作树之间共享，挪回 `.artifacts` 反而让每个工作树各下载一份，因此拒绝。

### 写一个新脚本，专门复制 `.artifacts/desktop`

复制本身只是一条 `cp -cR`，难点在判断“版本是否一致、源工作树是否在编译”，这些判断依赖当次任务的上下文，写成脚本仍要维护一套清单和测试。构建脚本已经负责重编的正确性，复制这一步交给 Agent 按 Skill 判断即可，因此拒绝。

## 后果

- 新增资源不用再改清单、校验路由和测试，只需在 `docs/ci-builds.md` 写清楚。
- 复制是否发生取决于 Agent 是否按 Skill 执行，没有脚本兜底；正确性由构建脚本的身份检查保证，复制错了最多是多编一次或删掉重编。
- 复制后，`target/debug/build/*/*/out/` 下由第三方 build script 生成的 dep-info（`.d`）文件仍带着源工作树的路径；实验中编译和链接都不受影响。源工作树删除后会不会让这些 build script 重跑，没有单独验证；最坏情况是多编一些依赖，删掉复制的目录重编即可恢复。
- 依赖源工作树正在编译时复制，可能复制到写了一半的产物；Skill 要求避开这种情况，出错时删除重编。

## 验证

- 2026-11-16 复制实验：用 `cp -cR` 把一个工作树的 `.artifacts/desktop`（4.9 GB）克隆进新工作树，耗时约 4 秒；随后 `scripts/desktop/build-desktop-core.sh` 用 33 秒完成，只重编了 52 个 Core 自己的 crate，没有重编第三方依赖，`identity.txt` 和 built-from 记录都按新工作树更新；再用 `scripts/desktop/desktop-go.sh build ./cmd/lithe` 完整链接桌面客户端，31 秒成功。
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `AGENTS.md`
- `.agents/skills/develop-lithe/SKILL.md`
- `docs/ci-builds.md`
- `scripts/desktop/build-desktop-core.sh`
