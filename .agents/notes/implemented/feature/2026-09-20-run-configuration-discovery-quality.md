# Agent 笔记：运行配置的分类、命名与入口识别

状态：已实现

## 先说结论

同一个仓库里，"能跑的东西" 不都是这个项目的服务。若依 Plus（ruoyi-vue-pro）
这类 Java 项目里有三个 docker-compose 文件，Lithe 之前把里面的 19 个数据库
容器和项目自己的 Spring Boot 服务混在同一个「服务」列表里，还出现三条同名的
`compose up`；同时，扫描器把测试代码字符串里的示例 `public static void main`
当成了真实入口，生成了根本无法启动的配置。

现在由 Rust Core 统一决定三件事：每个配置属于「项目」还是「基础设施」
（category）、同名配置怎么加限定词、Java 入口只从语法树里认。宿主只负责按
category 分组展示。

## 问题

用户在 Windows 上打开若依 Plus 后，运行面板的「服务」里出现 19 条 compose
条目（admin、mysql ×2、redis、oracle、dm8、kingbase… 以及三条完全同名的
`compose up`），真正要启动的 `yudao-server` 淹没其中。「运行选中服务」默认
勾选的还是列表第一条，也就是某个数据库容器。

「应用」里还出现了 `MailTemplateServiceImplTest`。这个类里没有 main 方法，
只有 `@Test`；它的测试数据里有一段 HTML 字符串，内容是
`"<pre><code>public class Test {\n public static void main(String[] args)…"`。
旧的扫描用正则在原始文本上匹配 `static void main(`，于是字符串里的示例代码
变成了一条运行配置。

## 决策

### 1. 配置分「项目」和「基础设施」两类

`RunCategory`（`rust/lithe-core/src/execution/types.rs`）取值 `project` 或
`infrastructure`，默认 `project`，序列化时省略默认值，所以已有的
`generated.json` 内容不变。docker-compose 探测出来的服务和整栈条目标记为
`infrastructure`。

判断放在探测器里，不要放在宿主：宿主只读 category 分组。

#### 正确做法

- 新增探测器时，如果找到的是项目依赖的外部服务（数据库、消息队列、模拟器），
  在 `Detected` 上调用 `.as_infrastructure()`。
- 宿主把 `infrastructure` 放进单独分组，并且不要把它算进「运行全部服务」或
  默认勾选。

#### 不要这样做

- 不要因为 compose 条目碍事就不再探测它们。纯 docker 项目仍然需要它们。
- 不要在 Windows 或 macOS 各写一份「哪些算基础设施」的判断。

### 2. 同名配置由 Core 加限定词

配置 id 里带目录，所以本来就不重复；但界面只显示名字，三个 compose 文件各出
一条 `compose up` 时用户无法区分。Core 在生成阶段按组消歧：依次尝试 Maven
模块、工作目录、来源清单，取第一个能把该组内每条都区分开的候选，得到
`compose up (script/docker)`、`mysql (sql/tools)` 这样的名字。只出现一次的
名字不加任何后缀，id 也不受影响。

### 3. Java 入口只采用 JDT 的语义结果

后续架构决策已经替代这里最初采用 tree-sitter 识别 `main` 的实现：可运行类和
测试现在由 JDT / Java Test 判定，Core 只为 JDT 已确认的入口补充
`@SpringBootApplication` 产品分类，不再维护方法签名或测试注解规则。详见
`../architecture/2026-09-21-java-entrypoints-owned-by-jdt.md`。

`src/test` 下真实存在的 main 方法**仍然是合法入口**，继续用测试 classpath
启动。这一点由共享 fixture
`shared/fixtures/execution/maven-java-main-source-sets-v1.json` 保证，不要
为了让列表变短而整体排除测试源码。

### 4. Windows 按语言生态、运行类型和输出分三栏浏览

复合项目可能同时包含 Java、Node.js、Python 和 Rust。只按框架排列，用户要在
同一列表中寻找不同语言的构建任务和服务。Windows 先显示当前配置对应的语言
生态，再在中栏按具体运行类型分组，右栏显示所选配置详情及其输出。

这里的语言生态是界面导航，依据 Core 已提供的 provider（配置来源类型）投影，
不新增源码扫描或改变启动计划。Maven、Gradle、Spring Boot 属于 Java；npm、
pnpm、Bun 及前端框架属于 Node.js 生态。当前 npm 元数据不能证明源码是
JavaScript 还是 TypeScript，因此不根据名称、目录或启动命令猜测两者。
Swift、PHP 等已有明确 provider 的配置可归类，但这不代表增加了这些语言的
自动发现能力。未知 provider 放进“其他”，通用构建工具和基础设施各有入口。

切换语言只改变浏览选择，不停止后台进程。右栏依据当前配置选择输出，不能把
另一个配置的日志、运行状态或标准输入通道借给未启动的配置。外部操作选中配置时，
浏览器自动切换到其生态。语言栏和配置栏直接展示导航内容，不重复增加“语言／生态”
或当前语言的栏头，也不展示生态的配置数量，以减少重复信息和垂直空间占用。

语言栏直接通过拖动调整和折叠：向左拖过收起阈值后变成带无障碍名称和悬停提示的
图标栏，向右拖过展开阈值后恢复文字并跟随拖动宽度。收起和展开使用不同阈值，
避免边界附近的微小移动反复切换。键盘方向键也可收起及恢复保存的展开宽度；
中栏保留独立宽度。窗口变窄时自动收起语言栏，不覆盖
用户保存的展开偏好，空间恢复后重新展开。两条分隔条复用已有拖动会话，只在每帧
更新局部 DOM 的宽度与紧凑标记，文字和图标对齐由 CSS 根据标记切换，不在拖动
过程中重建 React 页面；同时限制语言栏和中栏宽度，为输出保留空间。结束或卸载时持久化一次
并释放监听。窗口尺寸变化会结束正在进行的拖动，避免继续使用旧的尺寸边界。

正确示例：Java 栏中同时展示 Spring Boot 服务和 Maven 构建任务，仍保留各自
的 execution（服务、应用或任务）及进程会话。不要为了语言分组把 Java Main
改成 service，也不要让语言切换触发启动或停止。

保留旧框架平铺列表层级更浅，但复合项目定位成本高，因此采用三栏。
把 JS/TS 强行拆开会依赖未提供的语言事实，因此当前使用 Node.js 生态。
收益是跨语言定位清晰；代价是增加一层浏览选择和少量横向空间。macOS 保留
现有列表，本次三栏是 Windows 展示变化，不修改共享发现与执行语义。
固定语言栏实现更简单，但会持续占用输出空间，因此保留拖动和手动折叠。
专门的底部折叠按钮会占用空间，也让调宽和折叠成为两套操作，因此使用同一个
分隔条完成。语言行、类型行和实例行使用一致的紧凑行高，移除列表上下留白，
选中实例使用平直的整行背景，减少孤立圆角块与上下错位。
不要在拖动每一帧写入偏好或重建整个运行页面，也不要把自动收起保存为手动折叠，
否则扩大窗口后用户原本的布局不会恢复。

### 5. 生成器 revision 提升

`GENERATOR_REVISION` 从 `4` 提到 `5`，已有工作区会重新生成配置，用户不需要
手动删除 `.lithe/run/generated.json`。

## 考虑过的备选方案

- **直接不探测 docker-compose**：被否。纯 docker 项目会失去唯一的运行入口，
  而问题其实出在展示方式，不是探测本身。
- **只探测仓库根或 `script/docker` 这类"部署目录"的 compose 文件**：被否。
  规则靠猜目录名，`sql/tools` 这种位置一样可能是用户真正要启动的东西。
- **排除 `src/test` 下的全部 main 方法**：被否。共享 fixture 和既有实现都
  明确支持"测试源码里的 main 用测试 classpath 启动"，用户实际也有这种工具类
  （`DefaultDatabaseQueryTest` 就带真实 main）。真正的缺陷是假阳性，不是
  测试源码本身。
- **在宿主侧按 provider 前缀（`compose.`）分组**：被否。两个平台会各写一份
  相同判断，而且新增探测器时容易漏改。

## 后果

- 若依 Plus 的「服务」只剩 `yudao-server`，compose 条目进入可折叠的
  「Docker 服务」分组；默认勾选的服务因此变成真正的项目服务。
- 字符串和注释里的示例代码不再产生幻影配置，`entryCount` 也随之变准。
- macOS 目前仍按 execution 分组浏览，compose 条目会继续出现在它的 Services
  作用域里；名字已经带目录限定，分组适配是后续工作。
- 入口识别从正则改成解析，单文件成本略增，但与既有的 JUnit 发现共用同一套
  解析器，没有引入新依赖。
- 新增探测器如果忘记标 `infrastructure`，条目会落回「项目」分组；这是可见的
  错误，不会让配置消失。

## 验证

- Rust：`cargo test --manifest-path rust/Cargo.toml -p lithe-core`
  覆盖三条回归：`compose_detections_are_reported_as_infrastructure`、
  `repeated_detection_names_are_qualified_by_directory`、
  `java_entries_ignore_main_methods_inside_strings_and_comments`，以及
  `java_syntax` 中的入口签名单元测试。
- Windows：`bun test src/features/run` 覆盖 category 映射与分组过滤。
- Windows 三栏：`./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/run`
  覆盖生态归类、语言切换、外部选中、重新扫描、无重复栏头与计数、拖动期间不写偏好、
  拖动折叠与展开、阈值附近防抖、保存宽度及窄栏键盘恢复、窗口变窄与卸载清理，
  以及输出会话隔离。
- 共享契约：`./scripts/verify-shared-contracts.sh`，契约文本与
  `shared/contracts/run-configuration-v2.schema.json` 同步更新。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/types.rs`、
  `rust/lithe-core/src/execution/detectors/mod.rs`、
  `rust/lithe-core/src/execution/detectors/compose.rs`、
  `rust/lithe-core/src/execution/configuration.rs`、
  `rust/lithe-core/src/languages/java.rs`、
  `rust/lithe-core/src/languages/java_syntax.rs`
- Windows：`windows/tauri/src/features/run/utils/run-configuration.ts`、
  `windows/tauri/src/features/run/components/run-pane.tsx`、
  `windows/tauri/src/features/run/components/run-configuration-browser.tsx`、
  `windows/tauri/src/features/run/utils/run-configuration-language.ts`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
