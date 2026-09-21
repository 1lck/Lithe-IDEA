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

### 4. 生成器 revision 提升

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
  `windows/tauri/src/features/run/components/run-pane.tsx`
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
