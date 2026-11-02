# MavenSupport

Maven 的项目事实由既有 Core Maven hostIntegration 提供；生命周期命令由实际 Maven 执行。
Java 导入、编译状态、main class 和启动 classpath 继续由 JDT LS/Java Debug 提供。

此目录是可冻结的实际插件源码，尚未加入正式发行或市场索引。包保留
`buildSystems:1`、`packageTrust:1` 与 `publisherPackage`，安装和执行仍需宿主能力、正常签名验证及用户审批。
不下载工具；用户提供实际工具安装或项目 Wrapper。Gradle 调用使用 `--no-daemon`。

使用 `scripts/plugins/host-acceptance/java_workflow_packages.py` 冻结验收输入。
受控签名仅用于一次隔离宿主验收，不构成生产准入或完整产品验证。
