# Agent 笔记：运行面板使用 Maven 面板的工具链配置

状态：已实现

## 先说结论

Windows 用户在 Maven 面板配置了 Maven 主目录后，运行面板仍可能提示未选择 Maven，阻止运行。
原因是启动会读取 Maven 面板配置，但启动前的诊断只读取 Run 自己的选择和系统自动发现结果。
现在诊断也读取同一工作区的 Maven 配置作为默认值，再交给宿主探测实际可执行文件、Core 校验版本。

## 问题

Issue #727 的 Maven 路径只保存在 Maven 面板中，不在系统 PATH 或 Run 显式选择里。
旧诊断缺少候选，触发 missingToolchain 并禁用运行按钮，即使实际启动路径已能读取该配置。

## 决策

- 保留 Run 显式选择的优先级；没有显式选择时，使用工作区 Maven 面板的路径，再回落到自动发现。
- 只对有 Maven 消费者的项目加载 Maven 上下文，使用明确的 workspaceId，避免读取其他窗口的配置。
- Maven 主目录和可执行文件继续由现有宿主解析；前端不伪造工具链候选、不绕过版本校验。
- Maven 面板路径变化时刷新运行面板。每次加载带递增编号，旧请求的成功或失败都不能覆盖新结果。
- 默认值只用于诊断，不写回 Run 配置。比如 Maven 面板从安装目录 A 改到 B，未显式选择 Maven 的 Run 配置应跟随 B，而不是被首次读取时复制的 A 锁住。

## 考虑过的备选方案

- 只隐藏 missingToolchain 提示：会放过不存在的路径，也无法保留版本不兼容的诊断，因此不采用。
- 把 Maven 面板配置复制进 Run 的持久化文件：会产生两份需要同步的路径，且后续修改优先级不清，因此不采用。
- 重写宿主 Maven 发现：已有发现接口支持主目录及可执行文件，只缺调用时传入正确的选择，不需要增加一套解析器。

## 后果

用户可以只配置一次 Maven，诊断与启动使用一致的默认值；无效路径和版本不兼容仍显示正常错误。
存在 Maven 消费者时，加载运行面板需要等待工作区 Maven 上下文；修改路径也会重新探测工具链。
本次不改变 JDT 的项目构建、Maven goal 执行或共享 Core 契约。

## 验证

- `windows/tauri/src/features/run/services/resolve-run-project.test.ts`：面板路径、可执行文件、Run 显式优先、无效路径、版本不兼容及非 Maven 项目。
- `windows/tauri/src/features/run/stores/run-project-load.test.ts`：旧加载结果不能恢复已消除的告警。
- `windows/tauri/src/features/run/stores/run-maven-context.test.ts`：实际启动等待相同工作区的 Maven 上下文。
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs -- src/features/run/services/resolve-run-project.test.ts src/features/run/stores/run-project-load.test.ts src/features/run/stores/run-maven-context.test.ts`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `windows/tauri/src/features/run/services/resolve-run-project.ts`
- `windows/tauri/src/features/run/stores/run.store.ts`
- `windows/tauri/src/features/run/components/run-pane.tsx`
