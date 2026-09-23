# Agent 笔记：Tomcat 外部容器运行配置（exploded 部署）

状态：提议中

## 先说结论

为传统 `packaging=war` 的 Java Web 项目新增 `tomcat.external` 运行配置 provider。
用户在配置中指定 Tomcat 安装目录和项目的 exploded（展开）目录，Lithe 启动
Tomcat 时不把任何文件拷贝到 Tomcat 的 `webapps/`，而是在
`conf/Catalina/localhost/` 下生成一个 context XML，把 `docBase` 指向项目目录。
停止时删除该 context XML，保持 Tomcat 安装目录干净。

开发者以后新增外部容器类运行配置时，都走同一套模式：Core 生成 context 配置、
返回带 `executable.path` 的启动计划、平台层负责启停和清理；不要把 WAR 拷贝
逻辑写进 Core。

## 问题

Lithe 当前只识别 Spring Boot / Quarkus / Micronaut 这类自带嵌入式容器的框架。
大量老项目仍然是 `packaging=war`，依赖外部 Tomcat。用户希望像 IntelliJ IDEA
一样在 Lithe 里配置 Tomcat 路径和项目路径后一键启动，但不希望 Lithe 把文件
部署到 Tomcat 安装目录（避免污染、避免重复拷贝、改 JSP 能即时生效）。

## 提案

### 1. 新增 provider `tomcat.external`

用户通过"新建运行配置"选择 Tomcat 类型，填写：

- `tomcatHome`：Tomcat 安装目录的绝对路径。存放在 `.lithe/run/local.json`
  （机器本地层），不提交到 Git。
- `explodedPath`：项目内展开后的 Web 应用目录，工作区相对路径，默认
  `target/<artifactId>-<version>`。
- `contextPath`：上下文路径，如 `/myapp`，默认 `/<artifactId>`。
- `httpPort`、`shutdownPort`：Tomcat 端口，默认 8080 / 8005。
- `jvmArguments`、`environmentVariables`：传给 Tomcat JVM。

启动前自动执行 `mvn war:exploded`（通过 Maven 工具链），确保 exploded 目录
与最新源码一致。

### 2. 启动计划生成

`runConfig.createLaunchPlan` 对 `tomcat.external` 走专门分支：

1. 校验 `tomcatHome` 下存在 `bin/catalina`（`.sh` 或 `.bat`）。
2. 校验 `explodedPath` 下存在 `WEB-INF/web.xml`。
3. 在 `${tomcatHome}/conf/Catalina/localhost/` 生成 context XML：
   ```xml
   <Context docBase="/workspace/target/myapp" path="/myapp" reloadable="true" />
   ```
4. 返回启动计划：
   - `executable.path` = `${tomcatHome}/bin/catalina`（新增的绝对路径形式）
   - `arguments` = `["run"]`（前台运行，便于捕获日志）
   - `environment` = `CATALINA_HOME`、`JAVA_HOME`（来自 JDK 工具链）
   - `preLaunchSteps` = `mvn war:exploded -pl <module> -am`
   - `tomcat.contextXmlPath`、`tomcat.httpPort`、`tomcat.shutdownPort`
     供平台层启停时使用。

### 3. 启停与清理

- 启动：写 context XML → `catalina run` → 解析 stdout 中的
  `Server startup in xxx ms` 作为就绪信号 → 检测端口冲突。
- 停止：向 `shutdownPort` 发送 `SHUTDOWN`（Tomcat 标准关闭协议），超时后
  force-kill 进程。
- 停止后：删除 `${tomcatHome}/conf/Catalina/localhost/<contextName>.xml`。

### 4. 调试

通过 `CATALINA_OPTS` 注入 JDWP，然后用 Java Debug Server 附加。

## 考虑过的备选方案

### A. 让用户用 `command` 字段手写脚本

利用现有的 `process_launch_plan`，用户在 `.lithe/run/configurations.json`
里写 `command: catalina.sh`，再手动写 context XML。

否决原因：`executable.command` 要求 bare name（不能含路径分隔符），Tomcat
的 `catalina` 通常不在 PATH 里；且没有配置 UI，context XML 要用户手写，体验
离"IDEA 一样"太远。

### B. 拷贝 WAR 到 webapps

否决原因：用户明确要求"不把文件部署到 tomcat 路径上"。拷贝会污染 Tomcat
目录、改 JSP 不即时生效、每次启动都要重新打包。

### C. 用 `tomcat-maven-plugin` 的 `tomcat7:run`

否决原因：需要改项目 `pom.xml` 加插件，且 `tomcat7-maven-plugin` 与用户已
有的外部 Tomcat 9/10 安装目录是两回事，容易引入版本混乱。

## 验收标准

- 在 macOS 和 Windows 上，打开一个 `packaging=war` 的 Maven 项目，新建
  Tomcat 运行配置，填写 Tomcat 路径后能启动并访问 `http://localhost:8080/<context>`。
- Tomcat 的 `webapps/` 目录下没有新增任何文件或目录。
- `conf/Catalina/localhost/` 下有一个对应 context XML，停止后被删除。
- 修改 exploded 目录下的 JSP 后刷新页面能看到变化（无需重启）。
- 调试模式下能在 Java 源码断点处停住。
- `tomcatHome` 不出现在 `.lithe/run/configurations.json`（项目层），只在
  `local.json`（机器本地层）。

## 风险

- Tomcat 10+ 使用 Jakarta EE（`jakarta.*`），老项目用 Java EE（`javax.*`），
  混用会启动失败。需要在配置时提示用户匹配版本。
- Windows 的 `catalina.bat` 与 macOS/Linux 的 `catalina.sh` 行为不同，平台
  层需要分别处理。
- context XML 的 `docBase` 是绝对路径，跨平台不可移植，但因为 `tomcatHome`
  本身就是机器本地路径，所以可接受。
- 多个 Tomcat 配置同时运行会端口冲突，需要复用现有的端口冲突检测逻辑。

## 适用范围

- Rust Core：`rust/lithe-core/src/execution/configuration.rs`
  （`create_user_configuration`、`create_launch_plan`、新增 `tomcat_launch_plan`）
- 共享合约：`shared/contracts/application-boundary.md`（新增 `executable.path`
  形式和 `tomcat.external` provider 说明）、`shared/fixtures/execution/tomcat.json`
- macOS：`LitheCoreContracts/Execution/`（`SharedLaunchPlan.Executable` 新增
  `.path`）、`LitheExecutionModule/Services/RunService.swift`、运行配置编辑视图
- Windows：`windows/tauri/src/features/run/`、`windows/tauri/src-tauri/src/run.rs`
