# Agent 笔记：Maven 设置必须到达语言服务

状态：已实现

## 先说结论

Lithe 以前只把 `settings.xml` 这一个字段转给 JDT LS（Eclipse 的 Java 语言
服务），而且只有用户手动填写时才转。结果是：Maven 命令行用工程配置的安装读
到 F 盘仓库和阿里云镜像，JDT LS 却回落到出厂默认，在 `C:\Users\<user>\.m2`
另外下载一整套依赖。同一个工程被解析到两个本地仓库，磁盘翻倍，下载绕过镜像，
依赖没下全时启动报 `Unresolved compilation problems`。

现在的规则只有一条：**Lithe 会运行哪个 Maven，JDT LS 就必须看到那个 Maven
会读的设置。** 开发者以后新增任何影响依赖解析的 Maven 配置项，都要同时回答
“它怎么到达语言服务”，否则命令行和语言服务会再次分叉。

## 问题

三个独立缺陷叠在一起，表现为同一个现象。

**一、字段在 Core 里被丢掉。** `jdt_configuration()` 构造的
`MavenJdtConfiguration` 只有 `profiles / settings_path / project_paths /
source_paths` 四个字段。上游 `MavenLaunchContextRequest` 里带着的
`local_repository_path` 和 `maven_executable_path` 在这里直接消失，下游
`java_settings()` 因此只能发 `java.configuration.maven.userSettings` 一条。
全仓库搜不到 `globalSettings`。

Maven 自己的设置解析顺序是“用户级 `~/.m2/settings.xml` 叠加安装级
`<maven home>/conf/settings.xml`”。安装级那份从来没转给 JDT LS，而典型的国内
开发机恰恰把仓库位置和镜像写在安装级里、根本没有用户级文件。m2e（JDT LS 内置
的 Maven 集成）于是零配置启动，回落到 `${user.home}/.m2/repository` 和
`repo.maven.apache.org`。

**二、送达时机太晚。** `adapt_initialization_options()` 只注入
`extendedClientCapabilities` 和 `bundles`，不注入 `settings`。Maven 配置只能
走 `initialized` 之后的 `didChangeConfiguration` 和被动的
`workspace/configuration` 应答。JDT LS 在处理 `initialize` 时就配置 m2e 并紧接
着启动项目导入，所以哪怕路径填对了，也要等首次导入按默认值解析完才送达。

**三、设置面板的“自动检测”是空头支票。** Maven 设置面板四个输入框统一用
`自动检测` 作占位符，但代码里没有任何一处检测 `settings.xml` 或本地仓库。
用户正因为看到“自动检测”才放心留空。

此外，「运行配置」和「Maven 设置」各有一个「Maven 主目录」输入框，语义不同但
用户不会这样理解。数据流只有“运行配置读 Maven 面板”的单向兜底
（`resolve-run-project.ts`），反方向没有，所以在运行配置里填的 Maven 主目录
对语言服务零影响。

## 决策

**1. 安装级设置转成 `globalSettings`。** Core 从配置的 Maven 主目录或
`<home>/bin/mvn*` 启动器推出 `conf/settings.xml`，作为
`java.configuration.maven.globalSettings` 交给 JDT LS。

推导失败时返回空，这是刻意的：项目 Wrapper（`mvnw`）不在任何安装目录里，
没有安装级设置；此时 JDT LS 停留在自身默认，而这正是直接敲 `mvnw` 会得到的
结果。两边仍然一致。

**2. 设置随 `initialize` 一起送达。** `adapt_initialization_options()` 把
`settings.java` 注入 `initializationOptions`，赶在 m2e 配置和首次导入之前。
注入采用覆盖式合并：扩展目录自带的键保留，Lithe 拥有的键权威。

**3. Maven 选择统一成一条优先级链。**

```text
Maven 设置面板的显式配置
  → 运行配置的机器工具链
  → 项目 Wrapper / 宿主发现到的安装
```

两个平台都把**解析后**的安装写进 Maven 启动上下文，而不是把空值传下去。

这样在任意一处填 `D:\apache-maven-3.9.16`，语言服务和命令行都会用它。

**这条链上不允许启动进程。** 它跑在 Maven 工程加载里，而 Java 编辑器打开文件
时会先 `await` 这个加载再启动语言服务（`resolve-editor-lsp-launch.ts`）。
现成的 `run_discover_toolchains` 会对每个候选跑 `mvn -version` / `java -version`，
首次运行 Wrapper 甚至会去下载一份 Maven 发行版 —— 把它放在这里等于让每次
首开 Java 文件都赌一次网络。所以 Windows 侧新增了 `maven_resolve_installation`：
候选顺序与 `resolve_maven_executable` 一致（覆盖 → 可用的 Wrapper → 机器安装），
但只做 `is_file()` 判断，不起进程。

开发者以后往这条链上加层时，先问“它会不会起进程或等网络”。会的话，放到后台
解析并在结果回来后刷新，不要放进加载路径。

**4. 本地仓库通过生成的设置文档传递。** JDT LS 没有“本地仓库”这个首选项，
该值只能写在 `settings.xml` 里。所以当用户填了本地仓库时，Core 以生效的设置
文件为底稿做一次**保留式 XML 改写**——只替换 `<localRepository>` 节点，
`<mirrors>`、`<servers>`、`<proxies>`、注释和缩进原样带过——作为 `userSettings`
传下去。安装级设置仍在 `globalSettings` 上，Maven 会把两者合并。生成文档的
存放位置和命名规则见下文“设置变更必须让 JDT LS 重新解析（#970）”。

绝不凭空合成一份只含 `<localRepository>` 的文档：那会丢掉镜像配置，把下载从
阿里云打回 Maven Central。这是本次事故里代价最大的一条。

底稿读不到时（路径过期、文件被删、盘没挂载）**降级而不是失败**：跳过改写，
把原路径原样交给 JDT LS，并往会话日志写一条 warn 说明仓库覆盖未生效。
理由是失败半径不对称 —— 丢掉的是一个可选设置项，而让 `start_server` 失败会
让整个工作区没有补全、跳转和诊断。不要为了“配置错误就该响亮失败”把语言服务
一起拖下水。

## 考虑过的备选方案

- **配置读不到时让会话启动失败。** 被否。第一版这样做过，复审时发现失败半径
  （整个 Java 语言服务）和成因（一个可选设置项）严重不匹配，而且只有配了本地
  仓库的用户才会踩到，行为不一致。改为降级加 warn 日志。
- **给 JDT LS 传 `-Dmaven.repo.local` JVM 参数。** 被否。m2e 的仓库位置来自
  settings 解析结果，这个系统属性是否被尊重取决于 m2e 版本，我们无法在没有
  Windows 环境的情况下证明它成立。不上无法验证的机制。
- **合成只含 `<localRepository>` 的最小 settings.xml 当 userSettings。** 被否。
  用户配置了 settings.xml 时，这份合成文档会取代它，镜像随之丢失。只有在用户
  没有任何 settings.xml 时才退化成这种最小文档，此时本来就没有镜像可丢。
- **把用户的 settings.xml 放进 `globalSettings` 槽位、合成文档放 userSettings。**
  被否。这样能免去 XML 改写，但会挤掉安装级设置；三份文件两个槽位，语义失真。
- **把两个「Maven 主目录」输入框合并成一个。** 被否。运行工具链和项目导入的
  作用域确实不同，合并会让“只想给某个运行配置换 JDK”的场景没法表达。改为共用
  一条解析链，保留两个入口。
- **Core 直接读 `.lithe/run/local.json` 拿运行工具链。** 被否。运行配置的本地
  层由宿主读取后传入 Core（`local_layer_document`），Core 自己读盘会破坏既有的
  持久化归属。解析链因此留在平台侧。

## 后果

收益：

- 命令行与语言服务解析同一个本地仓库，不再重复下载整套依赖。
- 镜像配置对语言服务生效，国内网络下的首次导入不再绕道 Maven Central。
- 「自动检测」名副其实：留空时按优先级链解析，而不是静默回落到出厂默认。

代价和例外：

- Wrapper 工程仍然得不到安装级设置。这是正确行为，但用户如果期望
  「配了 Maven 主目录就该全局生效」，需要显式填写而不是依赖 Wrapper。
- 本地仓库走生成文档这条路，意味着 JDT LS 状态目录里多出派生的设置副本。
  用户配置文件本身不被修改。副本的命名和生命周期见 #970 一节。
- Maven 上下文仍然不进日志。这次定位只能靠翻启动命令行里的 `-cp`，下次遇到
  类似问题依然会很慢。补日志是独立的后续工作。

### 项目环境设置入口（2026-09-22）

两个平台都从「设置 → 项目 · JDK 与 Maven」管理项目默认环境。Windows 的 Maven
工具窗口齿轮也跳到这里。各服务的启动参数、环境变量、工作目录与工具链覆盖
统一在「设置 → 运行配置」编辑，复用原有保存链路，不改变本机／项目作用域。
运行窗口移除逐服务齿轮和编辑弹窗，保留选择、启动、停止及只读详情；编辑器
行号旁的编辑命令直接打开设置并选中对应配置。Node 配置也使用同一设置入口。
设置对话框已打开时这些入口同样必须跳转：Windows 每次指定分类的请求都会递增
`settingsTabRequest`，重复请求同一分类也会重新定位，不能只依赖分类值变化。

Windows 运行存储区分「重载同一项目」和「切换项目」。保存项目默认值、运行面板
挂载等同一项目的 `loadProject` 只重新读取文档与工具链：先等进行中的识别发布结果，
保留等待 JDT 准备完成后的刷新和编译失败后待确认的启动；只有切换到其他项目才取消
这些工作。错误做法是每次重载都递增版本并取消，导致刚保存完 JDK 时 Java 入口不再
自动补齐、待确认的启动被静默取消。「设置 → 运行配置」另外只在存储尚未绑定当前
项目时加载，避免打开设置本身触发无意义的重读。

Windows 保存项目环境在默认值和 Maven 本机配置写入后即视为完成，按钮立即恢复；
随后的运行配置刷新可能要等进行中的识别，因此单独返回并在结束后报告失败，不能让
保存本身等待识别。

macOS 的项目 JDK、Maven 与 Maven JDK 以 `.lithe/run/local.json` 为唯一真源，
UserDefaults 中的项目运行时设置只是它的镜像，供 Maven 进程和环境检查使用。
`runConfig.inspect` 返回的本机 `toolchain` 在未生成配置时也会读取；运行功能读完
项目文档后，镜像以它为准覆盖这三个字段。本机层尚未保存过默认值（`toolchain`
为空）时保留现有镜像，下一次保存再写入本机层；文档无法解析时两边都不改。错误
做法是「镜像为空才补」：旧版服务编辑器只写本机层，镜像里的旧值会在关闭设置时
反向覆盖运行实际使用的 JDK。

Core 的服务编辑器保存每次都会重写本机层 `toolchain`，因此编辑器必须传有效默认值：
本机层已保存的默认值，未保存过时用镜像（`RunService.saveEditorChanges` 以
`savedProjectToolchain ?? 镜像` 选取）。错误做法是传解析结果 `projectToolchain`：
本机层没有默认值时它是空值，写入后「从未保存」变成「显式自动」，镜像随之被清空，
运行改用自动检测的 JDK。

macOS 的项目设置表单必须在运行功能读完当前项目文档后再填入初始值，关闭设置时的
自动保存也只在 `ProjectLoadState.hasLoadedDocuments(for:)` 成立时写入。运行功能
加载中持有的是空工具链；此时保存会把用户已保存的项目 JDK 覆盖成空值。
表单在填入初始值之前保持禁用，关闭设置时也只在准备完成后才保存，与 Windows 加载期间
禁用表单一致：准备期间的修改无法写入本机层，读完文档后以本机层为准会把它静默还原；
尚未合并 Maven 配置的表单值也不能写回 Maven 本机设置。

不要在设置中复制一套运行参数解析或另存一份配置。正确做法是设置页复用运行
功能模型及原有编辑表单；错误做法是在运行面板和设置各保留一个独立草稿入口。
代价是编辑前需要进入设置，但所有配置的位置一致，运行界面也不再堆积齿轮。

项目设置保存必须调用 `runConfig.updateOptions` 的本机工具链分支，不得选择一个
服务、把它当前解析后的参数重新保存一遍。正确做法是只更新本机 `toolchain`，
保留原有 `configurations`；错误做法是把继承结果写成服务覆盖，导致项目默认值
下次变化时服务不再跟随。macOS 的运行配置端口为此增加独立保存操作。

Windows 设置使用 `runConfig.inspect` 的 `checkFingerprint: false` 读取默认值，
不要求先生成运行配置，也不为打开设置遍历全部源文件。自动检测的安装仅供候选
展示，不能把检测结果当作用户已经保存的选择。Maven JDK 留空时，Windows 的
Maven 启动适配器读取项目默认 JDK；该解析不把继承结果写回配置。

Maven 目标执行不依赖运行配置文档有效：Windows 读取项目 JDK 默认值失败时，
记录不含原始错误或机器路径的警告，回退到宿主 JDK 选择，不能让损坏的
generated.json 阻止独立 Maven 任务。macOS 首次保存项目默认值必须先补齐
本机运行配置的 Git 忽略规则，保留用户已有内容。补齐按规则逐条判断：生成时写入的
不带前导 `/` 的写法同样算已存在，只有缺失或被其后的用户否定规则覆盖时才追加，
避免保存项目默认值时改动团队共享的 `.lithe/.gitignore`，这与 Windows 宿主的
`ensure_lithe_gitignore` 一致；设置中的重新识别也必须遵守
不支持版本的升级保护，并在运行服务入口再次拦截，不能只依赖按钮禁用。

现有 Maven 的本机配置仍由 Maven 存储管理，设置页同步其显式选择，保留 profiles、
settings.xml 和仓库路径。Windows 的 Run 本机文档与 Maven 本机文档是两次独立
写入；若后一步失败，界面明确提示默认值已保存，不伪装成整次回滚。原生 UI 和
进程行为仍需分别在 macOS、Windows 验证。

### 自动与继承值必须显示实际生效的工具链（#814）

设置里所有「自动」「使用项目 JDK」「继承项目」的位置，都显示启动时实际使用的 JDK 或
Maven、版本、路径和来源，例如「自动 → JDK 21.0.4 · 路径 · 来自 JAVA_HOME」。只显示
「自动识别」时，用户无法判断运行的是哪个 JDK，版本问题只能靠翻启动命令排查。

显示值必须来自启动所用的同一个解析器，不能在界面另行推算。Windows 宿主的
`run_resolve_toolchains` 直接调用 `run_resolve_launch` 使用的 `resolve_java_home` 与
`resolve_maven_executable`，并在工作线程探测版本；Maven Wrapper 只识别不执行，因为
首次运行可能下载发行版。macOS 把 `javaHomeURL`、`mavenJavaHomeURL`、`mavenExecutable`
改为调用返回值与来源的 `chooseJavaHome`、`chooseMavenJavaHome`、`chooseMavenExecutable`，
启动与设置共用一条链；设置只使用后台已检测的运行时，检测未完成时显示「正在检测」，
不在主线程同步探测。错误做法是取候选列表第一项当作「自动」结果：Windows 候选列表会
重新排序，与启动选择并不一致。

解析的输入也必须与启动一致。凡是显示自动值的页面都要确保已开始后台检测
（macOS `ensureRuntimesDiscovered`），不能只依赖项目页触发，否则从运行面板或编辑器
直接进入服务表单会一直停在「正在检测」。Windows 服务表单按启动顺序组合选择
（`launchToolchainSelection`：覆盖 → 项目默认 → Maven 工具窗口的显式值），只取 Maven
的显式值而不取其解析结果，否则自动选择会被显示成「已选择」。

检测中、未找到、配置路径无效都要明确显示；macOS 配置的 Maven JDK 无效时启动会回退到
项目 JDK，设置显示这次回退而不是隐藏它。版本低于项目要求沿用 Core 的
`toolchainVersionMismatch` 等诊断，按诊断中的 `toolchain` 挂到对应字段，平台端不重写
版本比较。运行面板保留一步进入「设置 → 运行配置」并定位当前服务的入口；两端设置窗口
每次分类请求都会重新定位，重复请求同一分类同样生效。

### 自动 JDK 选择（#815）

自动模式先满足项目已有的 Java 最低版本要求，再按来源选择。显式选择的项目 JDK、
服务 JDK 或 Maven JDK 不会被自动替换。两端共用 Core `runConfig.selectJava`，版本
比较复用现有需求诊断中的逻辑，兼容 Java 8 的 `1.8` 表达；不要在 Swift/TypeScript
各写一套版本比较，也不要重新解析 POM 或建立另一个项目模型。JDT LS 仍拥有语言
服务项目状态，本次只消费既有生成文档中的最低版本，选择机器上的启动工具。

来源顺序为 JAVA_HOME、PATH、普通安装、Windows 项目内安装。来源相同时先按数值
版本降序，再按候选标识排序，避免目录枚举顺序左右结果。macOS 没有版本要求时
保留原有 JAVA_HOME/首个发现候选回退；Windows 无要求时仍按来源选取，但修正原本
覆盖 JAVA_HOME 优先级的字符串排序。没有任何兼容版本时继续保留回退选择，同时在
生效值旁显示安装兼容 JDK 的提示。损坏或未来版本的需求文件明确报错，不按无要求处理。

例如项目要求 Java 17、JAVA_HOME 为 8、PATH 为 17、普通目录有 21 时，自动选择
PATH 的 17；显式选择 8 仍保留 8，由既有启动诊断报告不兼容。不要仅让设置页显示
17，而启动仍取候选列表第一个 8。Windows 的发现结果也把实际自动候选放在首位，
保证 Run 诊断与宿主启动一致；macOS 的 Run、Maven、测试和设置经过同一个选择入口。

考虑过只改 Windows 排序，但这不能解决两端忽略项目要求的问题。也没有直接选最高
版本：兼容的 JAVA_HOME/PATH 是用户已有环境意图，应优先保留。选择策略只读取现有
工作区需求文档，不生成文件、探测进程或写入安装包。macOS 启动复用当前项目已经
探测的候选；尚未完成完整发现时只探测 Java 并保留到项目切换或显式刷新，不能为了
选择 Java 连带探测 Maven。无版本要求且 JAVA_HOME 可用时保留不探测的快速路径。
PATH 仅用于识别已有候选的来源（平台负责解析符号链接），不额外扩大默认候选集合；代价是需求变化后需要重新解析
选择，不能把上一次项目的结果缓存成全局默认值。

回归验证使用共享 `automatic-java-selection.json`，覆盖枚举反序、数值补丁版本、
旧版 Java 格式、兼容候选筛选、无要求/无匹配回退、空候选及损坏文档。macOS 的
`automaticJavaUsesProjectMinimumAndPreservesExplicitSelections` 验证设置选择、Maven
继承、显式覆盖与项目切换；Windows 的
`automatic_java_selection_reads_requirement_changes_without_probing` 验证同一工作区
需求变化和显式路径旁路。原生实机验收仍需覆盖 Run、Maven 目标和测试运行。

### Maven 设置页的检测边界（#844）

Windows Maven 设置页的空字段展示当前已保存配置下的生效值。例如选择了团队的
`settings.xml`，本地仓库留空时应显示该文件声明的仓库，不能显示忽略团队设置后
得到的 `~/.m2/repository`。Maven 安装使用启动上下文已经解析的路径；JDK 与独立
Maven 目标共用项目默认值继承逻辑。显式字段不再显示未启用的自动候选，检测中
也不继续显示上一份配置的路径。切换项目必须丢弃未保存草稿，即使两个项目的
已保存字段刚好相同。

检测命令在后台工作线程执行。Maven 路径只做文件检查，不运行 Wrapper；JDK
仅探测 Java 候选，不连带运行 Maven、Node。每次版本探测设三秒截止时间，复用
`lithe-git-host` 的原生进程执行器处理输出上限、进程树终止和有界清理，避免用户
打开设置就因 Wrapper 下载或卡住的版本命令冻结界面。

设置文件中的仓库提示复用 Core 已使用的 `quick-xml`，解码实体和 CDATA（XML 中
保留原始文字的区段），只读取 `settings` 的直接子元素，并读完整个文档后再接受
结果。不能截取标签间的原始字符串，否则 `D:/R&amp;D` 会变成错误目录，缺失闭合
标签也可能被当作路径。这里只提供只读提示，不生成 Maven 的完整生效模型；
`${user.home}` 以外的属性保持原文，完整插值和最终构建配置仍由 Maven 负责。

### 设置变更必须让 JDT LS 重新解析（#970）

**先说结论：** 改 Maven 设置或点“重新加载”，都必须让 JDT LS 真的重新解析依赖。
Lithe 不自己判断“要不要重解析”，而是按 JDT LS 上游（vscode-java 同一套）的机制
把变化交给它：设置文件路径变了，JDT LS 会强制更新所有 Maven 项目；用户手动
重新加载，就发 `java/projectConfigurationsUpdate`（上游的“更新项目”，不看 pom
有没有改）。

**问题。** #970 的用户在 JDT LS 导入过程中改了 Maven 设置，结果 Spring、MyBatis
等第三方 import 全红，但界面没有任何错误。代码里有三处缺陷叠在一起：

1. 保存设置只标记“需要重新加载”，从不通知运行中的 JDT LS；Maven 配置只在
   `initialize` 时送过一次。
2. 重新加载的做法是停掉 JDT LS 再启动。重启会复用 `-data` 工作区状态，而
   JDT LS 导入时对已导入项目只检查 pom 时间戳和摘要
   （`MavenProjectImporter.updateProjects` → `needsMavenUpdate`），pom 没变就跳过。
   上次没解析成功的依赖会一直缺失。
3. JDT LS 判断“设置是否变化”只比较设置文件的**路径字符串**
   （`StandardPreferenceManager.update`）。以前生成的设置固定写在
   `<缓存>/maven/settings.xml`，改本地仓库或镜像后路径不变，JDT LS 看不出变化；
   所有项目还共用这一个文件，会互相覆盖。

**决策。**

- **设置副本按内容命名。** JDT LS 收到的每一份设置文档都复制到该会话的
  `-data` 目录下 `.lithe/maven/`，文件名带内容哈希
  （`user-settings-<哈希>.xml`、`global-settings-<哈希>.xml`）。内容一变路径就变，
  JDT LS 自己的变化检测才能生效。用户级副本的来源依次是：配置的 settings.xml →
  Maven 默认的 `~/.m2/settings.xml`（与命令行一致）→ 只配了本地仓库时的空文档。
  安装级 `conf/settings.xml` 同样复制。副本放在 `-data` 里，随 JDT 缓存保留期
  清理、随“重建 Java 索引”删除，不写发行包，也不改用户文件。读不到的文档
  按原路径传并写 warn 日志，沿用上文“降级而不是失败”的原则。
- **配置变化实时送达。** 新增 Core 操作 `lsp.updateMavenConfiguration`：替换会话
  持有的 Maven 配置；设置副本路径变了就发 `workspace/didChangeConfiguration`
  （JDT LS 会强制更新所有 Maven 项目，导入中途也会排队执行）；profile 变了就
  重启 profile 任务。握手前到达的更新由 `initialized` 后那次设置通知带上。
  显式的强制重载单独保留，合并重复请求后在 `ServiceReady`（项目已导入）时执行，
  不能因为设置没变而丢弃。
  两个平台保存 Maven 设置、切换 profile 时都调用它，不再弹“需要重新加载”。
- **重新加载改为强制更新。** 会话还在时，“重新加载”发
  `lsp.updateMavenConfiguration` 并带 `reloadProjects`，Core 在设置未变时发
  `java/projectConfigurationsUpdate`。只有会话不存在、或会话拒绝更新时才停止并
  重新启动。
- **profile 任务期间的变更不丢。** 任务完成时只把它开始时的配置记为“已应用”；
  如果期间配置被替换，无论旧任务成功还是失败，都自动再跑一轮。超时后的取消
  是建议性的，必须等待旧请求全部收到终态响应才启动新配置；同一份失败配置不
  自动无限重试。
- **解析失败要让用户看见。** m2e 的解析结果就是 pom.xml 上的错误诊断
  （缺少构件、父 POM 解析失败等）。两个平台都把工作区内 pom.xml 的错误诊断
  列在 Maven 工具窗口，并对每个不同的问题集合发一次可跳转的通知；原来的
  “Maven configuration applied” 提示只代表 profile 命令返回了，不代表依赖解析
  成功，已经移除。

正确做法：改一项 Maven 设置 → 调 `lsp.updateMavenConfiguration` → 让 JDT LS 按
上游规则重解析。不要这样做：重启 JDT LS 来“应用”设置，或者用固定文件名改写
设置文档——两者都会让 JDT LS 以为什么都没变。

**考虑过的备选方案。**

- **设置一变就删掉 JDT 工作区再冷启动。** 被否。能保证重解析，但每次改设置都
  丢掉整个索引，冷导入大工程要几分钟，而上游已经有等价且增量的机制。
- **在 Lithe 里自己跟踪“哪些项目需要更新”。** 被否。这是 m2e/JDT LS 的项目
  状态，Lithe 另记一份会成为第二真相源，违反“复用上游子系统”的规则。
- **保持固定文件名，另外发一次 `projectConfigurationsUpdate`。** 被否。m2e 会
  缓存已加载的 settings，路径不变时不会重新读取，强制更新仍然用旧镜像和旧仓库。

**代价。** JDT 状态目录里多出小的设置副本，其中可能包含用户 settings.xml 里的
服务器凭据；它们位于平台提供的用户缓存目录，Unix 新文件权限为 `0600`。
配置生成和发布使用会话专用串行锁，磁盘操作不占用协议锁；临时文件独占创建并带
进程内唯一编号，避免并发写入覆盖。旧副本保留到 JDT 工作区缓存过期或重建索引时
一起清理，因为通知写入管道并不代表 JDT LS 已读取文件。不能在下一次生成时删除
上一份副本；否则导入中的服务可能读到已经不存在的路径。这些副本属于会话可变
状态，禁止跨工作树复用，见资源清单 `jdt-maven-settings` 排除项。强制
更新会重新解析所有 Maven 项目，大工程上比“什么都不做”慢，但这正是用户点重新加载
时要的结果。

**验证。** Rust Core `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib`
覆盖内容寻址（内容变路径变、相同内容复用、旧副本保留、临时文件所有权、默认用户设置、读不到时降级），
以及 `update_maven_configuration` 的四条路径（设置变化、强制更新、握手前更新、
profile 变化、失败或超时期间变更补跑、握手前无设置变化的强制重载）。Windows `bun test src/platform src/features/maven`
覆盖命令路由、错误包装、实时同步、重新加载先走强制更新、pom 问题提取；macOS
`LanguageIntelligenceModuleTests`、`ExecutionModuleTests` 覆盖原地更新、回退重启和
设置实时同步。

## 验证

- Rust Core：`cargo test --manifest-path rust/lithe-core/Cargo.toml`
  覆盖主目录与启动器两种写法都能推出 `conf/settings.xml`、Wrapper 与无 `conf`
  的安装正确返回空、`initializationOptions` 注入且不吃掉扩展目录的键、
  Profile 指纹随安装变化，以及生成文档保留镜像/注释、插入缺失节点、展开空元素、
  转义路径中的 `&`、不误伤 profile 内的同名元素。完整校验运行
  `./scripts/verify-rust-core.sh`。
- Rust Core 注释规范：`./scripts/verify-rust-core-comments.sh`。
- Windows 前端：`bun test src/features/maven` 覆盖优先级链、各层失败时的降级、
  面板留空时把解析结果带进启动上下文、清空路径时丢弃上一次的解析结果。
  边界校验运行 `./scripts/verify-windows-boundaries.sh`。
- Windows 宿主：`cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
  maven_resolution_without_probing` 覆盖 Wrapper 优先、主目录与启动器两种覆盖
  写法、残缺 Wrapper 不被选中。
- Maven 设置：Windows 宿主 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
  maven::settings_xml` 覆盖实体、CDATA、命名空间、注释和不完整 XML；同一宿主的
  `toolchain_probe_` 测试覆盖已到期的探测和两个输出流。前端
  `maven-detected-value.test.tsx`、`maven-project-jdk.test.ts`、`maven.store.test.ts`
  验证显示与启动选择一致，`maven-settings-panel.test.tsx` 验证项目切换丢弃草稿。
- 共享契约：`./scripts/verify-shared-contracts.sh`。
- 测试稳定性：`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`。
- 生效值显示：Windows 宿主 `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml
  displayed_` 覆盖显示的 Maven 即启动会运行的 Wrapper、无效选择与启动一致地报错；
  前端 `bun test src/features/run/utils/effective-toolchain.test.ts
  src/features/run/hooks/use-resolved-toolchains.test.tsx` 覆盖文案、需求诊断筛选、
  过期结果不覆盖新结果与输入防抖。macOS `MavenRuntimeTests` 覆盖来源判断、检测未完成
  不同步探测、Maven JDK 回退与 Maven 选择链，`WorkbenchFeatureModelTests` 覆盖重复
  分类请求。
- 项目环境设置入口：`cargo test --manifest-path rust/lithe-core/Cargo.toml
  project_environment_saves_before_generation` 用共享 fixture
  `shared/fixtures/run-configuration/project-environment.json` 覆盖未生成配置时保存
  默认值、保留服务覆盖以及 `checkFingerprint` 的两种行为。Windows 运行
  `bun test src/features/settings src/features/maven src/features/run/services/java-main-launch.test.ts`，
  覆盖默认值读写、Maven 保存重试、编辑器跳转、中文搜索，以及打开「设置 → 运行配置」
  不重载同一项目；`run.store` 测试覆盖同一项目重载保留 JDT 刷新与待确认启动、
等待进行中的识别发布，以及切换项目仍会取消；`project-environment` 测试覆盖保存在
运行配置刷新完成前返回、刷新失败与 Maven 写入失败的报告。macOS 运行 `./scripts/test-macos.sh`，
  `RunConfigurationIntegrationTests` 覆盖未生成配置时保存、Git 忽略规则逐条补齐且
  重复保存不改动文件、不支持版本的识别拦截，只有读完当前项目文档后才允许保存
项目默认值，未生成配置时读取本机默认值，以及服务编辑器保存写入有效默认值；`MavenRuntimeTests` 覆盖镜像以本机层
为准且不改动其他 Maven 设置。

## 适用范围

- Rust Core Maven 域：`rust/lithe-core/src/project/maven.rs`
- Rust Core JDT 适配：`rust/lithe-core/src/lsp/languages/jdt.rs`
- Rust Core 语言服务引擎：`rust/lithe-core/src/lsp/interface/engine.rs`
- Rust Core 设置副本：`rust/lithe-core/src/lsp/languages/jdt_maven_settings.rs`
- Windows 实时同步与问题展示：`windows/tauri/src/features/maven/services/java-maven-configuration.ts`、
  `windows/tauri/src/features/maven/services/reload-maven-workspace.ts`、
  `windows/tauri/src/features/maven/utils/maven-resolution-problems.ts`
- macOS 实时同步与问题展示：
  `macos/Sources/LitheLanguageIntelligenceModule/Services/LanguageToolingSessionManager.swift`、
  `macos/Sources/Lithe/Models/Java/MavenResolutionProblems.swift`
- Windows 前端：`windows/tauri/src/features/maven/services/resolve-maven-toolchain.ts`、
  `windows/tauri/src/features/maven/stores/maven.store.ts`
- Windows 宿主：`windows/tauri/src-tauri/src/run.rs`（`maven_resolve_installation`）
- macOS：`macos/Sources/LitheExecutionModule/Services/MavenService.swift`
- 项目环境与运行配置设置入口：
  - Rust Core：`rust/lithe-core/src/execution/configuration.rs`（`runConfig.inspect`、
    `runConfig.updateOptions` 工具链分支）
  - 共享契约：`shared/contracts/rust-core-api.md`、
    `shared/fixtures/run-configuration/project-environment.json`
  - macOS：`macos/Sources/Lithe/Views/App/RunConfigurationSettingsView.swift`、
    `macos/Sources/Lithe/Views/App/ProjectRuntimeSettingsView.swift`、
    `macos/Sources/LitheExecutionModule/Services/RunService.swift`（`saveProjectToolchain`）、
    `macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacRunConfigurationStore.swift`、
    `macos/Sources/Lithe/Models/AppModel/AppModel+FeatureState.swift`（项目设置填充与保存）、
    `macos/Sources/Lithe/Services/Java/ProjectRuntimeService.swift`（`adoptProjectToolchain`、
    `chooseJavaHome` 等解析链）、
    `macos/Sources/Lithe/Views/App/EffectiveRuntimeLabel.swift`
  - Windows：`windows/tauri/src/features/settings/components/project-environment-settings.tsx`、
    `windows/tauri/src/features/settings/components/run-configuration-settings.tsx`、
    `windows/tauri/src/features/settings/services/`、
    `windows/tauri/src/features/run/stores/run.store.ts`（`loadProject` 同项目重载）、
    `windows/tauri/src/features/run/utils/effective-toolchain.ts`、
    `windows/tauri/src/features/run/hooks/use-resolved-toolchains.ts`、
    `windows/tauri/src-tauri/src/run.rs`（`run_resolve_toolchains`）、
    `windows/tauri/src/features/maven/api/maven-host-api.ts`（`resolveMavenLaunch`）
- 相关笔记：
  `.agents/notes/implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md`
