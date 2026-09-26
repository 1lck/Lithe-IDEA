# Agent 笔记：Windows Maven 工具链识别 mvnd

状态：已实现

## 先说结论

Windows 的 Maven 选择器接受 Maven Daemon（mvnd，复用后台 Java 进程执行 Maven 构建）的安装主目录、bin 目录和启动文件。它继续复用现有 Maven 导入、构建和运行流程，不增加第二套项目模型。Java 语言服务器使用 mvnd 内嵌 Maven 的全局配置，避免构建与代码分析读取不同的镜像设置。

## 问题

原目录解析只尝试 `bin/mvn.*`，选择 mvnd 的根目录无法得到启动文件。mvnd 的版本输出先包含 `Apache Maven Daemon`，旧解析器误把 `Daemon` 当成版本；它的 Maven 全局设置位于 `mvn/conf/settings.xml`，并非发行包根目录的 `conf/settings.xml`。

## 决策

- Windows 的工具链发现、无进程导入解析和执行解析共用目录候选生成器，支持 mvnd 原生客户端及脚本入口。自动模式仍优先考虑项目 Wrapper 和已有 Maven，之后补充 `MVND_HOME` 与 PATH 中的 mvnd。
- 显式目录选择必须解析到该目录的客户端，不得回退到系统 Maven。正确示例是选择 mvnd 根目录后执行 `bin/mvnd.exe`；不要改为执行其内嵌的 `mvn/bin/mvn.cmd`，否则用户没有真正用到守护进程。
- 版本字段保留已有 Maven 版本语义，从 mvnd 输出的内嵌 Maven 行解析版本，跳过 Daemon 标题。
- Core 只负责确定性地解析全局设置路径，识别已安装 mvnd 的 `mvn/conf/settings.xml`。JDT LS（Java 语言服务器）的项目模型仍由上游管理；这不是让 JDT LS 经由 mvnd 导入项目。
- 不增加全局 `mvnd --stop` 行为。mvnd 的守护进程和复用由上游客户端管理，不能关闭用户其他终端的构建服务。真实验证使用独立的临时守护进程注册目录，并在结束后清理。

## 考虑过的备选方案

仅让用户填写 `mvnd.exe` 会保留目录选择失败、错误版本和全局配置不一致的问题。退回内嵌普通 Maven 虽可执行相同目标，却违背用户选择 mvnd 的意图。另建 mvnd 项目模型会重复 Maven/JDT LS 的责任，因此均未采用。

## 后果

项目环境中的 Maven/mvnd 自动识别入口显示“自动”，手动选择后显示用户路径；没有检测到 Maven 或 mvnd 时，明确提示填写或选择安装目录。实际解析路径和失败提示继续由有效工具链状态展示。

既有 Maven 设置字段和运行配置无需迁移，用户可直接保存 mvnd 目录。代价是需要覆盖 Maven 与 mvnd 的不同布局；本次 Windows 发现入口之外的 macOS 自动发现尚未增加 mvnd 支持。mvnd 自身的 Java 配置和构建插件兼容性仍由该工具负责。

## 验证

- `.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1` 检查新增测试的有界等待与资源清理。
- `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1` 的 WindowsRust 与 SharedRust 范围记录独立测试时间。
- `windows/tauri/src-tauri/src/run.rs` 的 mvnd 用例覆盖根目录、bin、启动文件、含空格路径、显式选择优先级、无效路径和版本解析；默认单测不启动外部工具。真实目录集成测试需要显式设置 `LITHE_TEST_MVND_HOME` 并运行 ignored 用例。
- `rust/lithe-core/src/tests/languages.rs` 验证 mvnd 三种路径都向 JDT LS 提供内嵌 Maven 的设置；文件缺失时不使用错误的根目录设置。
- `scripts/build-windows.ps1 -Configuration Release` 验证 Windows 宿主和前端构建。

## 适用范围

- `windows/tauri/src-tauri/src/run.rs`
- `windows/tauri/src/i18n/locale.ts`
- `rust/lithe-core/src/project/maven.rs`
- `rust/lithe-core/src/tests/languages.rs`

上游依据：[Apache Maven Daemon](https://github.com/apache/maven-mvnd)；本机 mvnd 1.0.6 的版本输出和发行包布局用于实机验证，机器路径不写入产品源码。
