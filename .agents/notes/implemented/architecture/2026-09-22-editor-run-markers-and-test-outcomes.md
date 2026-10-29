# Agent 笔记：编辑器 Run 标记与逐方法测试结果

状态：已实现

## 先说结论

Issue #790 要求像 IDEA 一样在 Java 编辑器行号旁显示运行按钮：`main` 方法旁一个 ▶，
测试类旁一个双三角，测试方法旁一个 ▶，跑过的测试显示通过（绿勾）或失败（红色）。
决定是：**哪些声明能运行由 JDT 回答，图标和状态怎么算由 Rust Core 统一计算，
逐方法的结果来自实际测试运行的报告**。两端只负责画图标、弹菜单和调用
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

### 状态来自当前操作的后端报告

macOS 的 Maven 测试已切换到 Build Provider：JDT 仍提供类和方法标识，Maven 插件
通过 Apache Surefire parser 读取实际配置目录中的本次报告。宿主不再调用
`maven.testResults`、扫描固定 XML 目录或根据测试源码寻找 POM。Windows 还在使用
旧共享命令；删除它们前须先迁移当前 Windows 消费者，这不代表 macOS 保留回退。

报告按工程／类／方法保留状态、参数化调用次数和耗时；相同方法的重复调用取最严重
状态，仅在所有调用都有安全的毫秒数时显示总耗时。缺失、负值、非有限值或无法安全
表示的时间不能伪造为零。macOS 结果树和编辑器标记按当前 Provider 模型的工程身份
隔离同名类，重跑仅替换本次返回的规范方法结果，不解释一个不透明测试标识来清空
其他方法的失败。

整类重跑按后端明确返回的覆盖范围清除旧方法；单方法重跑保留兄弟方法和其他工程。
没有覆盖范围时只替换报告中的精确用例，不能从选择器猜测执行范围。

报告节点保留插件、实例、当前工程 ID 与 suite/case；没有源码关联仍可重新请求原
后端运行，但 Debug 必须有 JDT 提供的源码关联。保存、模型/配置变化、工作区切换和
取消保留同一操作身份；旧输出、PID 或报告不能覆盖新运行。协议、资源边界和
Surefire 精确选择证据见 [原生执行决策](2026-10-26-build-provider-task-execution.md)。

Windows 启动指定测试类前继续重新向 JDT 查询文件并验证类归属；编辑、切换文件或
语言服务状态变化立即撤销旧标记。不能从类名或文件名推导另一个启动目标。

### 投影在 Core

`java.runMarkers` 是纯函数：输入 `javaMainMethods`、`javaTestItems` 和已记录的
`testCases`，输出按行排序的标记（行号、结束行、类型、菜单名称、启动目标、状态）。
类的状态规则：下面任一方法失败就是失败；至少一个通过且没有失败就是通过。
内部类的 `Outer$Inner`（报告）与 `Outer.Inner` 写法视为同一个类。

### 平台只做呈现和调度

macOS 顶栏保存完整的 `LanguageTestScope`（工作区、文件、类/方法）与 provider ID；测试面板切换范围后覆盖旧目标，顶栏 Run/Debug 按同一 scope 分派，不能把工作区或文件重建成上一次单方法目标。名称由 scope 生成，文件或单方法调试准备完成后采用 JDT 解析出的启动名称并保留原 scope，避免顶栏 Pause/Resume 的名称关联丢失；用户已切换目标时迟到结果不能覆盖新选择。顶栏 Run 在有测试目标时优先走测试分派，即使底层普通配置还在运行也不能重启它，运行图标和背景也按当前目标呈现。选择普通运行配置时清除测试目标。是否支持该范围的调试仍由既有测试调试准备流程判断。顶栏 Debug 在已有运行或暂停会话时仍先比较当前测试目标；目标改变就重新准备所选测试，只有同一目标才重启旧会话。


Tests 结果树只展示当前运行的 `results`，且仅投影到 `activePlan.providerID` 对应分组；状态和耗时也不能跨提供者使用。关闭或清空当前结果后恢复完整发现列表，供编辑器标记使用的 `testOutcomes` 历史缓存继续保留，但不得用它恢复结果树。Tests 结果树的渲染、选中查询和默认选中共用节点集合，报告合成出的类/方法必须能按完整标识重跑；已有 JDT 节点继续保留源码关联。报告本身不能证明源码归属，缺少关联时禁用 Debug，不能从类名猜路径后启动另一个测试。

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
- 代价：每次停止输入后多一次 `resolveMainMethod` 请求；Maven 插件需要捕获上游实际配置的本次报告；
  报告读取失败会明确终结当前操作，不用旧文件补成成功。
- macOS 当前 Maven 路径按实际 Mojo 的操作前后内容变化捕获，不再只按修改时间判断；
  Windows 的旧 Core 报告读取器仍保留时间戳限制，需在 Provider 宿主迁移时删除。

## 验证

- `./scripts/verify-rust-core.sh`：`java_main_methods`、`java_run_markers`、
  `maven_test_reports` 单元测试，`shared/fixtures/java/run-markers-v1.json` 兼容性
  fixture，以及可选的真实 JDT 冒烟测试（设置 `LITHE_JDTLS_SMOKE_ROOT` 时断言 Java 25
  实例 `main` 有标记、`private main` 没有）。
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-windows-boundaries.sh`
- `./scripts/test-macos.sh`：`ExecutionModuleTests`、`BuildSystemServiceTests`、`LanguageTestPresentationTests`、`LanguageIntelligenceModuleTests` 与真实 Maven Provider 回归。

## 适用范围

- `rust/lithe-core/src/lsp/languages/java_main_methods.rs`
- `rust/lithe-core/src/lsp/languages/java_run_markers.rs`
- `rust/lithe-core/src/project/maven_test_reports.rs`
- `windows/tauri/src/features/run/services/java-run-markers.ts`
- `windows/tauri/src/features/editor/engines/monaco/java-run-markers.ts`
- `frontend/editor/src/run-markers.ts`
- `macos/Sources/Lithe/Models/AppModel/AppModel+JavaRunMarkers.swift`
- `macos/Sources/LitheExecutionModule/Services/LanguageTestService.swift`
