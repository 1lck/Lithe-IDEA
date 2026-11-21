# Agent 笔记：工作区信任与安全模式对齐 IntelliJ IDEA

状态：已实现

## 先说结论

打开一个没有信任记录的文件夹前，桌面端先问“信任并打开项目？”，三个选择和 IntelliJ IDEA 一样：信任项目、以安全模式预览、不打开；可以勾选“信任父文件夹中的所有项目”。安全模式（Safe Mode，只浏览代码、不运行项目代码的打开方式）下不加载构建模型，运行、构建、测试和重新加载前都先问“信任项目？”，编辑器上方有“安全模式，功能受限”的提示条。信任记录是本机的，由 Core 存进偏好目录的工具链目录（`toolchains/global.json`），不写项目。

## 问题

Maven 这类命令来源的模型会运行 `mvn`，pom 里的扩展和插件就是仓库代码。打开项目时自动加载模型（见 [运行配置检测](../architecture/2026-10-29-run-configuration-detection-in-memory.md)）以后，打开一个陌生仓库就会运行它的代码。原来唯一的门槛是工具链各层不选工作区里的程序（`mvnw`、`gradlew`），模型命令、运行、测试本身没有按信任把关，也没有任何界面告诉用户。

## 决策

- **三种状态由 Core 判定。** Core 的工具链目录记着信任过的工作区、明确不信任的工作区和信任的位置（父文件夹）。`toolchains.catalogState` 返回 `workspaceTrust`（`trusted`、`distrusted`、`unknown`，以及可以提供的父文件夹）；显式决定优先于位置，和 IDEA 的 `TrustedPaths` 一致。根目录、盘符和网络共享根不作为可信位置提供。Core 返回的父文件夹路径在生成复选框标签时转换为当前平台的显示格式，再缩写主目录或长路径。
- **Core 拒绝会运行项目代码的计划。** 计划请求带 `projectCodeAllowed`；为假时，命令模型（清单标了 `executesProjectCode`）、执行类提供者计划和声明了运行项目代码的提供者都会被拒绝，错误码 `plugin.build.untrustedWorkspace`。宿主只负责把项目当前的信任带进请求（`desktop/internal/workbench` 中 11 处请求都填 `p.trust.allowed()`），不自己判断哪些计划危险。
- **先问再打开。** `openProjectHere` 先读信任（`toolchain.ReadWorkspaceTrust`），再决定直接打开、以安全模式打开或提问；选“不打开”时当前项目原样保留，新开的项目页签直接关掉。“以安全模式预览”记成不信任，下次打开不再问，和 IDEA 的 `setProjectTrusted(false)` 相同。
- **安全模式下的动作先问。** `startRun`、`runBuildTask`、`startTests`、运行当前文件和重新加载模型前，安全模式会弹出“信任项目？/ 保持安全模式”。信任保存成功后才执行原动作；保存失败按未信任处理。自动加载的模型不运行，构建窗口在模型位置显示安全模式说明。
- **设置页和对话框是同一份记录。** 构建设置里撤销或授予工作区信任后，工作台重新读取信任并应用；离开安全模式时重新加载被跳过的模型和失败的语言服务器。
- **可信位置有自己的设置页（#2207）。** 设置 › 工具 › 可信位置列出 Core 读出的 `trustedLocations`。增删都是草稿：每项改动单独交给 Core 的 `toolchains.editCatalog`（字段 `trustedLocations`）预演，页面显示 Core 算出的结果；Core 拒绝根目录（`plugin.toolchain.rootLocation`）和超过 256 项（`plugin.toolchain.trustListFull`），拒绝只丢掉这一项改动。“撤销修改”去掉该文件夹的全部改动，而不是追加一项反向改动，否则恢复的文件夹会跑到列表末尾。底栏应用时先写工具链、再写可信位置；两边共用偏好目录的 `toolchains/global.json`，任一方写入后把另一方读到的内容标记为过期，过期的列表在写入前先重新读取，改动相互抵消时不写文件。写入成功后工作台重试失败的语言服务器并重新判定当前项目的信任。

## 考虑过的备选方案

- **只靠工具链层不选 `mvnw`。** 被否：`mvn` 本身也会执行 pom 里的扩展，这道门槛挡不住模型命令和测试。
- **宿主按插件类型判断哪些动作危险。** 被否：危险与否取决于清单和计划类型，属于 Core 的计划逻辑；放在宿主会在每个平台重复一份并逐渐漂移。
- **打开后再问。** 被否：打开时就会恢复布局、加载模型，问之前代码可能已经运行；IDEA 也是先问再打开。
- **把信任写进项目的 `.lithe/`。** 被否：仓库可以自带“已信任”，等于没有门槛。

## 后果

- 测试 harness 默认把所有工作区当作信任（`Options.trustEveryWorkspace`，相当于 IDEA 单元测试模式关闭信任检查）；测试信任流程的用例要显式关掉。
- 安全模式下不启动会运行项目代码的语言服务器和 Git 由 #2208 处理；远程工作区的可信条目（#2231 的 S04）还没有界面，等远程连接界面一起做。
- 通过 IDE API 发起的构建任务在安全模式下会被拒绝，同时提示用户信任。

## 验证

- `desktop/internal/workbench/workspace_trust_test.go`：信任后打开并记住、勾选父文件夹后同级项目也被信任、不打开不留下任何状态、安全模式不加载模型且动作先问、提示条信任后消失。
- Core 的 `rust/crates/toolchain` 和 `rust/crates/build` 测试，以及 `build-plans.json`、`toolchain-global-catalog.json` 两份 fixture 覆盖状态判定和计划拒绝。
- `desktop/internal/toolchain/trusted_locations_test.go`（真实 Core）：预演不写文件、保存后嵌套项目被信任、过期列表写入被拒、相互抵消的改动不写文件、根目录被拒并指出是哪一项。`desktop/internal/settingswindow/trusted_locations_view_test.go`：草稿标记与撤销、拒绝只丢一项、应用前重读过期列表、写入后回读失败时重新读取。截图见 `docs/assets/trusted-locations/`。

```bash
scripts/desktop/desktop-go.sh test ./internal/workbench/ -run 'TestTrusting|TestDontOpen|TestSafeMode'
scripts/desktop/desktop-go.sh test ./internal/toolchain ./internal/settingswindow -run 'TrustedLocations'
```

## 适用范围

所有会运行项目代码的桌面端动作：加载构建模型、运行、调试、构建任务、测试、运行前任务。新增这类动作时，请求里必须带 `ProjectCodeAllowed`，用户触发的入口要先经过 `requireProjectTrust` 或 `askToTrustProject`。
