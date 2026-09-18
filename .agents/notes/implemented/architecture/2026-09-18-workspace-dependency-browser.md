# Agent 笔记：工作区依赖浏览器与语言 Provider 边界

状态：已实现

## 先说结论

依赖侧栏展示的是当前工作区已经解析出的依赖，不是机器上的全局缓存目录。依赖发现由语言 Provider 完成，侧栏只消费语言无关的依赖树模型。Provider 使用运行服务传入的源码根、资源根和 classpath，不再维护第二套项目路径配置。

本阶段先实现 Java Provider。它只投影运行时已经解析的 classpath，并接入每个服务实际使用的 JDK `lib/src.zip`；目录、JAR 和其他文件统一进入依赖节点模型，归档内容和源码关联由后续内容 Provider 扩展。

## 问题

Rust、Java、Node 等语言获取依赖源码的方式不同：Rust 通常直接拥有 package 源码目录，Java 可能只有 binary JAR 和可选的 source JAR，其他语言还可能返回生成的虚拟树。如果把这些差异写进 `ProjectSidebarView`，每接入一种语言都要改 UI，并且容易误把全局缓存显示成当前项目依赖。

## 决策

- `LitheCoreContracts` 定义 `DependencyResolutionContext`、`DependencyNode`、`DependencyGraph` 和 `WorkspaceDependencyProvider`。
- context 的路径由运行服务或执行模块提供；Provider 不扫描 home 目录、全局缓存或自行读取项目配置来推导依赖。
- Java Provider 使用 `classpath` 生成稳定排序的依赖根节点，并按 URL 类型标记目录、归档和不可用文件。
- `DependencyResolutionContext` 必须带有服务标识。多模块或多服务可以分别解析自己的 JDK 和 classpath，聚合展示时按归一化资源路径去重。
- 项目 JDK 源码和应用内置的 JDTLS JDK 是两类资源：前者来自服务配置的 JDK home，后者不能混入项目依赖树。
- 依赖关系发现和依赖内容浏览分开。Java 的 Maven/Gradle 解析、source JAR 关联和 `.class` 反编译不应成为通用 UI 模型的字段分支。

正确做法是由运行服务解析 classpath 后构造 `DependencyResolutionContext`，再交给 `JavaDependencyProvider`。不要在侧栏中直接扫描 `~/.m2`，也不要根据依赖坐标猜测本地文件位置。

## 考虑过的备选方案

- **侧栏直接扫描 Maven 本地仓库**：可以快速显示很多 JAR，但无法证明它们属于当前 workspace，也无法处理自定义仓库和 Gradle 项目，因此否决。
- **为 Java 单独定义一套树模型**：短期实现较少，但 Rust/Node 接入时必须复制 UI 和状态模型，因此改用语言无关节点和 Provider 接口。
- **把 archive 解压或反编译逻辑放进通用节点模型**：会让模型依赖 Java 细节；当前只携带 source 类型，内容读取留给后续 Provider。

## 后果

依赖面板能够复用执行模块已经确认的路径，显示范围和运行时一致，新增语言只需实现 Provider。多个服务可以保留自己的解析边界，同时在 UI 层聚合共享 JDK。代价是第一阶段只具备 classpath/JDK source 投影，尚未提供 JAR 条目懒加载、source JAR 选择和 `.class` 反编译；这些能力必须在内容 Provider 中补齐。

## 验证

- `swift build --target LitheExecutionModule`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `macos/Sources/LitheCoreContracts/Dependencies/DependencyContracts.swift`
- `macos/Sources/LitheExecutionModule/Dependencies/JavaDependencyProvider.swift`
- `macos/Sources/LitheExecutionModule/Application/ExecutionFeatureModels.swift`
- 未来依赖侧栏及其他语言 Provider
