# Windows 声明式构建执行模型（M4）实施清单

状态：设计待实施。本文是 M4 设计的可执行拆解，不是已完成能力的记录。设计决策与理由以
[proposed Note：Windows 声明式构建执行模型与安全调度](../../.agents/notes/proposed/architecture/2026-10-25-windows-declarative-build-execution.md)
为准；正式阶段边界以 [windows-plugin-parity-plan.md](windows-plugin-parity-plan.md) 的 M4 为准。

基线：`1e78b59b6385fca6a881639b42048bf3bc587f4a`（#1424 合入后的 preview）。M1 为 PR #1476
（head `3408f781`，主审中），其信任链/安装事务修复合入前，本清单的宿主接线批次不得开始改
`plugin_host` 产品代码。

## 0. 全局约定

- Core 14 个 `build.*` 命令（`rust/lithe-core/src/build/commands.rs:91-246`）只在宿主调用，
  不复制语义；宿主入口统一走 `plugin_host/scan.rs:190` 的 `core_execute`。
- 前端命令按普通 Tauri 命令注册（`declarative_plugins_build_*` 前缀），不进
  `platform/tauri-core.ts` 的点分调度命名空间（见 `tauri-core.ts:18` 的规则与路由测试）。
- `buildProviders` 全程关闭（M5）；`buildSystems:[1,2]` 与 `executableResolution:[1]` 只在
  PR-C 行为完整验收后加入 `host_capabilities`（`plugin_host/mod.rs:37`）。
- 矩阵：本清单对应的实现 PR 各自更新 `shared/platform-feature-matrix/features/` 相应条目；
  `declarative-plugin-contract.json` 归 M1 所有，改动前先与 M1 协调。

## 1. M1 阻塞接口（只消费，不定义）

| # | M1 提供 | M4 消费点 |
| --- | --- | --- |
| 1 | 包信任状态查询：已安装、已接受、已启用、当前版本字节与安装记录一致（含 M1 验签/摘要结果） | 每次构建执行的授权链第 1 步 |
| 2 | 安装审查已批准程序/权限记录（command 模型命令、任务/测试命令、打包运行时） | `projectFile`/`command` 执行的同意来源 |
| 3 | `lifecycle.rs` 隔离 API（`blocked/acquire/NativeLease`） | 构建进程注册为原生使用者，等待停用/替换/卸载 |
| 4 | `host_capabilities` 与 `declarative-plugin-contract` 矩阵的唯一修改权 | PR-C 串行在其后声明能力 |

依赖规则：需要新增 M1 接口时，先在 proposed Note 验收标准补记录，由 M1 落地；M4 PR 不改
`store.rs/install.rs` 的 schema。

## 2. PR-A：只读检测与展示（static 线）

新增：

- `windows/tauri/src-tauri/src/plugin_host/build.rs`：构建会话登记表（键
  `(host window label, workspace ID, pluginID, buildSystemID, instance root)`），detect、
  static 模型、`resolveOptions`（含 `dropped` 改存）、`syncFingerprint` 监听与过期标记、
  选项持久化（全局 `app_local_data_dir()/plugin-build-options/`，按工作区 + buildSystemID；
  空值语义照抄 macOS：显式清空是有效值）。
- `windows/tauri/src/features/build-systems/`：统一 TS service（每窗口展示状态）+ 工具窗口
  注册（`<pluginID>.build-systems:<buildSystemID>`，插件启用即注册，无实例显示空状态）+ 实例
  根选择器（候选与生效值取所选实例）。

修改：`main.rs`（命令注册）、`declarative-plugins-section.tsx`（无界面改动则不动）。

验收（真实接线）：

1. `build-static-file` fixture（Cargo）经真实 Core 识别，工具窗口展示工程/目标/任务树。
2. 选项修改经 `build.resolveOptions` 校验后持久化；`dropped` 选项改存生效值；重开工作区保留。
3. 构建文件变化 → `syncFingerprint` 变化 → 窗口显示"需要重新加载"，不自动重跑。
4. 停用插件 → 窗口与命令撤销（复用 `declarative-plugin-ui.ts` 撤销模式）。

有界测试（`plugin_host/tests.rs` 或新增 `build_tests.rs` + bun）：并发 detect/load 用受控假
执行器；登记表代次/槽位拒绝；无真实 sleep、无网络。

## 3. PR-B：进程执行与 Maven 对照

新增：

- `windows/tauri/src-tauri/src/plugin_host/build_resolver.rs`：五种候选来源
  （`projectFile/environment/command/runtime/setting`，`rust/lithe-core/src/plugins/executables.rs:82`）
  的 Windows 解析；`build.invocationPlan` + `build.checkToolVersion`（复用
  `launch.rs:430` 的 `lithe_git_host::run` Job Object 执行器，5s 探测期限、每流上限）；
  setting 来源为空跳过、非空无效终止失败；Runtime 候选自带 PATH、失败候选不传递。
- 命令模型加载：`build.modelPlan/decodeModel`、`build.dependencyPlan/decodeDependencies`；
  stdout 单独捕获交 Core、stderr 进 Build Output；有界收集 + 取消 + 输出上限。
- 任务/测试：`build.taskPlan/testPlan` 后经现有运行管线执行（`run.rs:675`
  `run_resolve_launch`、`run.rs:68` `RunProcessManager`），登记构建归属；
  `build.decodeDiagnostics/decodeTestResults` 结果进 Build Output，路径导航复用现有打开入口。
- `build.languageImport` 接 Java 启动就绪链（`windows/tauri/src/platform/java-launch-readiness.ts`）。

修改：`plugin_host/build.rs`（执行槽位与 NativeLease）、`run.rs`（归属登记）、`web.rs` 不动。

验收（真实接线）：

1. `build-command-stdout`（Go）、`build-command-output-file`（Gradle）、
   `build-host-integration`（Maven）fixture 宿主行为覆盖；argv 与 `build-plans.json` 标准答案一致。
2. 现有 Maven 专用流程（`maven.rs`、`features/maven/`）回归不退化；声明式 Maven 接管后从
   空状态开始，不沿用专用缓存。
3. 取消模型加载、等待同意时切换项目、配置路径带空格、setting 值失效（终止失败）全部覆盖。
4. 停止后确认子进程树结束（Job Object），不是仅从列表移除。

有界测试：进程用固定夹具可执行文件与可控完成顺序；迟到输出/旧代次写回拒绝；取消先于启动。

## 4. PR-C：executableResolution、统一桥与能力开放

范围：

- `executableResolution:1` 完整语义（排序元数据 `priority/insertBefore/insertAfter/platforms`，
  `executables.rs:115` 的 `uses_resolution`）与 `buildSystems:2` 的 `invocation.executableSetting`
  （`build/manifest.rs:1368` 门控：需要 v2 + effect reload/nextRun 的可执行全局设置）。
- 工具路径用户选择复用声明式设置存储（`plugin_host/settings.rs:15` 全局 / `:26` 项目覆盖），
  与 Core `resolveOptions`/设置推送同源。
- `web.rs` 8 个 `build.*` 方法（现拒绝于 `web.rs:787`）改为经登记表转发：页面身份
  （`with_page_owner`，`web.rs:80`）、同插件归属、与原生同一条授权链；`build.cancel` 只取消
  本页面/本窗口操作；页面关闭/导航/工作区切换取消在途并丢弃迟到回复。
- `host_capabilities` 增加 `"buildSystems": [1, 2], "executableResolution": [1]`（在 M1 合入
  之后、本批验收通过后）；能力门控测试随声明更新（参照 settings-v2 fixture 模式）。
- 矩阵更新：`build-system-plugins.json`（Windows → implemented + pending）、
  `plugin-web-tool-windows.json`（build 方法接线说明）。

验收（真实接线）：

1. `build-tool-path` fixture 端到端：setting 显式无效 → 终止失败且不回退 PATH；
   空值 → 跳过候选继续数组顺序。
2. 至少一个真实声明式构建插件完成：保存 → 同步 → 模型 → 运行/测试 → 停止 → 重新打开。
3. 网页与原生同链：同一实例状态、同一忙碌冲突、同一取消语义；跨窗口互不可见。
4. 停用/更新/回滚/卸载期间：`blocked` 拒绝新操作、已运行进程等待退出、页面关闭、
   无任务用旧包字节重启。

有界测试：桥的跨 owner/过期代次/取消竞态；双窗口状态隔离；能力门控翻转前后对比。

## 5. 场景覆盖矩阵（每批必查）

| 场景 | PR-A | PR-B | PR-C |
| --- | --- | --- | --- |
| 执行失败（缺可执行文件、非零退出、输出超限、解码失败） | – | ✔ | ✔ |
| 取消与迟到结果（用户取消/窗口关闭/切工作区/停用插件） | detect 级 | ✔ | ✔ |
| 跨窗口（互不取消、各自忙碌冲突、双窗口隔离） | 登记 | ✔ | ✔ |
| 过期结果（代次变化后迟到完成只标过期，不覆盖） | ✔ | ✔ | ✔ |
| 权限变化（M1 停用/更新/回滚/卸载、包字节替换） | 撤销窗口 | NativeLease | ✔ 全链 |
| 升级/卸载（进程树确认结束、登记表清理、无旧字节重启） | – | ✔ | ✔ |

## 6. 验证命令（实现 PR 按范围选择）

```powershell
node scripts/verify-agent-notes.mjs
cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml plugin_host
# 工作目录 windows/tauri
bun run typecheck
./scripts/verify-windows-boundaries.ps1
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
node scripts/generate-platform-feature-matrix.mjs --check
node scripts/verify-platform-feature-matrix-change.mjs <base-sha> <head-sha>
```

本清单与 proposed Note 属设计文档，未修改产品代码、共享契约、矩阵或测试；所有源码定位在
基线 `1e78b59b` 核对，M1 相关结论以 PR #1476 合并后的最终形态为准。
