# Lithe

Lithe 是一款面向 AI 编程工作流的原生 macOS 代码浏览与 Git 审查工具。

## 当前能力

- IDEA 风格的 Welcome Screen 和工作台
- 打开本地目录、最近项目和文件树
- 多标签原生文本编辑、保存和基础语法着色
- Java 方法定义跳转与引用查找（Eclipse JDT LS）
- 项目目录内置交互式终端
- 文件名与项目全文搜索
- FSEvents 外部文件变化监听和编辑冲突提示
- 磁盘型 Local History、项目级时间线、版本 Diff 与整文件恢复
- Git Changes、并排 Diff、文件暂存、撤销与提交
- Git 分支与标签树、可搜索提交时间线、提交文件目录树和提交详情
- Maven 根项目、模块、Profiles 与 Lifecycle 浏览，支持执行构建任务和查看 Build Output
- Java Current File、Spring Boot 与 Maven Module 基础运行配置，支持输出、停止、重启、配置持久化和多个 Maven Module 独立会话
- JDT LS Java 实时诊断、编辑器诊断下划线和 Problems 面板
- Java Debug：Current File、Maven/Spring Boot 和 Remote JVM/Tomcat JDWP attach，支持断点、继续/暂停、单步和线程/调用栈/变量查询

当前完成度、性能基线和后续计划见 [开发进度](./docs/开发进度.md)。

## 构建

需要 Swift 6.2 或更高版本。Java 语义导航还需要 Eclipse JDT LS：

```bash
brew install jdtls
```

构建应用：

```bash
swift build --disable-sandbox
swift run --disable-sandbox Lithe
```

生成可直接打开的本地 App Bundle：

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

最低支持 macOS 14。当前使用 Swift Package Manager，不依赖第三方包。

## 产品边界

Lithe 不内置 AI 或测试运行器。外部 AI 工具负责生成代码；Lithe 负责浏览项目、Java 代码导航、Maven 构建、运行配置、Java Debug、终端操作、观察外部变化和审查 Git 修改。Java 语言服务器仅在首次请求定义或引用时按需启动，关闭项目时停止。Local History 只把文本快照写入磁盘，内容按需加载，不作为 Git 的替代品。

完整范围见 [需求开发书](./docs/需求开发书.md)。IDEA 交互参考整理在 [IDEA UI 源码参考](./docs/IDEA-UI源码参考.md)。

## 目录结构

```text
Lithe-IDEA/
├── Sources/Lithe/   # SwiftUI / AppKit 源码
├── Resources/       # Info.plist 与应用图标
├── scripts/         # 本地打包脚本
├── docs/            # 需求、进度与设计参考
├── Package.swift
└── README.md
```

`.build/`、`dist/` 和视觉验收截图均为可重建产物，不纳入仓库。
