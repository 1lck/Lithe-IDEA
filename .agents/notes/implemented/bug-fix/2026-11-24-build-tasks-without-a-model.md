# Agent 笔记：省略模型的构建系统直接显示任务

状态：已实现

## 先说结论

只声明工作区级任务的构建系统可以省略模型。工作台发现这种实例时就能显示任务，Core 用空模型把任务放在实例根下。用户执行任务时，宿主才按该任务的调用计划解析工具。

## 问题

之前工作台把检测结果中没有模型来源的实例也送进构建提供者，也就是负责回答模型请求的插件进程。工具存在时，Core 会拒绝这个没有模型来源的请求。工具缺失时，面板会提前显示模型加载失败，用户看不到声明的任务。

## 决策

Core 的检测结果给出模型来源。来源为空时，工作台立即把实例标为可展示，任务分组继续交给 Core 的 `build.modelTree`。重新加载和插件设置刷新期间，实例继续可展示。只声明任务的实例也不会让运行配置快照提前变成空列表。执行任务仍按工作区信任和现有可执行文件规则处理。

## 考虑过的备选方案

让每个插件提供一个返回空结果的模型命令可以让旧宿主显示任务。这个做法会在打开项目时额外探测工具或启动子进程，也会让工具缺失阻挡任务列表。

## 后果

例如，只有工作区级 `clean` 任务的声明在打开项目后会直接显示 `clean`。与项目或目标绑定的任务仍需要对应的模型节点。模型同步日志只记录实际发生的模型加载。

## 验证

`desktop/internal/workbench/build_test.go` 中的 `TestBuildPanelShowsDeclaredTasksWithoutLoadingAModel` 打开含两个合成构建实例的工作区，通过真实 Core 检查构建树。它覆盖初次检测、重新加载和插件设置刷新，也校验这些操作没有创建模型同步会话。
`desktop/internal/workbench/runconfig_test.go` 覆盖工作区同时有声明式任务和正在加载的模型时，运行配置快照仍等待真实模型。

## 适用范围

`desktop/internal/workbench/build.go` 、`desktop/internal/workbench/settings_plugin_effects.go` 和 `desktop/internal/workbench/runconfig.go` 的共享桌面工作台。
