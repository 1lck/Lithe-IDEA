# Agent 笔记：编辑器 Run 标记与逐方法测试结果

状态：已实现

## 先说结论

Issue #790 要求像 IDEA 一样在 Java 编辑器行号旁显示运行按钮：`main` 方法旁一个 ▶，
测试类旁一个双三角，测试方法旁一个 ▶，跑过的测试显示通过（绿勾）或失败（红色）。
决定是：**哪些声明能运行由 JDT 回答，图标和状态怎么算由 Rust Core 统一计算，
逐方法的结果从 Maven 写出的 XML 报告里读取**。两端只负责画图标、弹菜单和调用
已有的运行、测试、调试流程。开发者以后改标记规则时只改 Core 的
`java.runMarkers`，不要在 Windows 或 macOS 里各写一份。

## 问题

用户只能在运行面板里找配置来运行 `main`，右键菜单也只有“运行测试类”。要做成 IDEA
那样，需要回答三个问题：

1. **图标画在哪一行。** 这必须是 JDT（Eclipse 的 Java 语言服务，Lithe 已内置）的判断，
   否则会重蹈 #769 的覆辙：Lithe 自己的语法规则跟不上 Java 25 的新 `main` 写法。
2. **跑完后每个方法是通过还是失败。** Maven 控制台文字只列出失败和出错的方法，
   通过和跳过的方法没有名字，跑整个类时无法给每个方法上色。
3. **两端怎么保持一致。** 放置规则、菜单名称、类的状态怎么由方法汇总，这些如果两端
   各算一份，很快就会不一样。

## 决策

### 位置来自 JDT

- `main` 方法：新增 LSP 操作 `javaMainMethods`，Core 调用 Java Debug 插件的
  `vscode.java.resolveMainMethod`（VS Code 的 “Run | Debug” 也用它），返回方法名所在
  范围和 `mainClass`。`mainClass` 与 `javaEntrypoints` 生成的运行配置一致，点击后直接
  运行那条配置，不新建第二种启动方式。
- 测试：沿用已有的 `javaTestItems`（Java Test 插件）。类的范围覆盖整个类体，方法的
  范围从方法名到方法体结束，所以“光标在哪个测试里”可以精确判断。
- JDT 只给出 `main` 方法名的位置，不给类体范围，所以 `main` 只在方法那一行画图标，
  不在类名那一行画；光标规则用“这一行的 `main`，否则文件里第一个 `main`”兜底。

### 状态来自 XML 报告

- `maven.testResults` 增加可选的 `reports` 参数：模块目录（或测试文件路径，由 Core
  找最近的 `pom.xml`）、所选类名、运行开始时间。Core 读取 Surefire/Failsafe
  写出的 `TEST-<类名>.xml`，按方法汇总为 `testCases`。
- **只读本次运行写的报告**：修改时间早于运行开始时间的报告属于上一次运行，一律忽略。
  这取代了原来“XML 报告由平台自己读”的约定，因为两端都需要，而解析和汇总是确定性
  规则，属于 Core。
- 参数化测试的 `name(Type)[1]`、`name[2]` 合并到同一个方法，最严重的结果为准；
  以显示名开头、无法对应方法的记录丢弃。报告的数量、大小和方法数都有上限。
- 平台保存“每个方法最近一次结果”：整类运行替换该类（含内部类）的结果；单方法运行
  只替换所选类中的所选方法，保留同类其他方法及内部类的历史结果。因此重跑一个通过
  的方法不会清除另一个方法的失败，也不会让类图标错误地变绿。
- Windows 启动指定测试类前，重新向 JDT 查询该文件并验证类归属。同文件内多个顶层类
  和内部类都使用 JDT 返回的类名；目标已消失时拒绝启动，不回退到文件名推导出的另一类。
- Windows 的发现结果与投影结果绑定到同一文档代次。编辑、切换文件或语言服务状态变化
  后立即禁用旧标记；延迟响应及失败响应不能恢复旧位置。Monaco 内容变化时同步清除
  点击目标和打开的菜单，避免装饰已移动而点击仍按旧行号查找。

### 投影在 Core

`java.runMarkers` 是纯函数：输入 `javaMainMethods`、`javaTestItems` 和已记录的
`testCases`，输出按行排序的标记（行号、结束行、类型、菜单名称、启动目标、状态）。
类的状态规则：下面任一方法失败就是失败；至少一个通过且没有失败就是通过。
内部类的 `Outer$Inner`（报告）与 `Outer.Inner` 写法视为同一个类。

### 平台只做呈现和调度

| | Windows（React/Monaco） | macOS（WKWebView 中的共享 Monaco） |
| --- | --- | --- |
| 图标位置 | 行号旁图标列的中间通道 | 右侧通道（左侧是实现标记，中间是断点） |
| 点击图标 | 弹出菜单：运行、修改运行配置 | Monaco 菜单：运行、调试、修改运行配置 |
| 右键菜单 | 一个“运行 'X'”项 | “Run 'X'”“Debug 'X'” |
| 快捷键 | `Ctrl+Shift+F10` | `⌃⇧R` 运行、`⌃⇧D` 调试 |
| 测试运行 | Maven store，`-Dtest=类#方法`，可选内部类 | 测试服务 `.testCase` |

Windows 的调试还没有正式接入，所以 Windows 菜单暂不提供“调试”。图标使用
intellij-community 的 `runConfigurations/testState` 图标（Apache 2.0）。

正确做法示例：

```text
要改“测试方法跳过时显示什么” → 改 Core 的 java.runMarkers 与共享 fixture
```

不要这样做：

```text
在 monaco-editor.tsx 里根据测试名称判断状态，或在 Swift 里再实现一遍类状态汇总
```

## 考虑过的备选方案

- **Lithe 自己扫描源码找 `main` 和 `@Test`**：已被 #769 证明会跟不上 Java 版本，拒绝。
- **解析 Maven 控制台文字得到逐方法结果**：文字里没有通过和跳过的方法名；
  `reportFormat=plain` 的输出随 Surefire 版本变化，拒绝。
- **改用 Java Test 插件自带的 JUnit 执行器**：它能实时回报结果，但测试不再经过 Maven，
  会改变插件、Profile 和 Surefire 配置的行为，属于另一项架构决定，本次不做。
- **两端各自计算标记**：实现量小一点，但放置和状态规则会漂移，拒绝。
- **在 macOS 原生视图里弹菜单**：需要把网页坐标换算成屏幕坐标；主编辑器已经是 Monaco，
  使用 Monaco 自己的菜单与右键菜单外观一致，采用后者。

## 后果

- 收益：两端标记规则相同；Java 新写法只需升级 JDT；测试结果精确到方法，包括
  参数化测试和内部类。
- 代价：每次停止输入后多一次 `resolveMainMethod` 请求；Core 需要读取模块下的报告目录；
  POM 里用无法解析的属性配置 `reportsDirectory` 时读不到报告，只显示普通 ▶。
- 跑完测试后如果报告被修改时间更早的文件覆盖（例如时钟回拨），状态不会更新，
  这是按时间识别“本次报告”的已知限制。

## 验证

- `./scripts/verify-rust-core.sh`：`java_main_methods`、`java_run_markers`、
  `maven_test_reports` 单元测试，`shared/fixtures/java/run-markers-v1.json` 兼容性
  fixture，以及可选的真实 JDT 冒烟测试（设置 `LITHE_JDTLS_SMOKE_ROOT` 时断言 Java 25
  实例 `main` 有标记、`private main` 没有）。
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/test-macos.sh`：`MavenTestOutcomeTests` 与测试服务报告请求断言。

## 适用范围

- `rust/lithe-core/src/lsp/languages/java_main_methods.rs`
- `rust/lithe-core/src/lsp/languages/java_run_markers.rs`
- `rust/lithe-core/src/project/maven_test_reports.rs`
- `windows/tauri/src/features/run/services/java-run-markers.ts`
- `windows/tauri/src/features/editor/engines/monaco/java-run-markers.ts`
- `frontend/editor/src/run-markers.ts`
- `macos/Sources/Lithe/Models/AppModel/AppModel+JavaRunMarkers.swift`
- `macos/Sources/LitheExecutionModule/Services/LanguageTestService.swift`
