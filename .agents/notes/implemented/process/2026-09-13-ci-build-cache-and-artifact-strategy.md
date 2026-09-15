# Agent 笔记：CI 构建缓存与测试产物策略

状态：已实现

## 先说结论

CI 缓存的是经过版本和依赖约束的中间构建结果，不缓存最终安装包。PR 按架构分别验证，主分支或手动运行时再组装通用包；测试安装包保留有限时间，并附带校验和，方便下载验证。

## 问题

Lithe 同时构建 macOS 双架构产品、通用 macOS 包和 Windows 安装包。Swift、
Rust Core、数据库辅助 crate 和前端构建的耗时来源不同；如果只缓存最终
可执行文件，容易复用错误的构建结果，也无法稳定获得测试安装包。

## 决策

macOS CI 与发布工作流统一使用 `macos-26` runner 上的 Xcode 26.6，编译器
固定为 `.swift-version` 中的 Swift 6.3.3。共用的 `setup-macos-toolchain` action
选择 Xcode 后校验实际编译器版本；不一致就立即失败，不能悄悄使用 runner 的
默认版本。SwiftPM 缓存键与完整性校验都读取这个版本文件。

此前在旧 runner 上通过 Swiftly 安装独立工具链失败，测试未能启动。因此改用
已预装的完整 Xcode，让 Swift、链接器和 SDK 保持匹配。升级编译器不改变应用
的 Swift 5 语言模式、测试的 Swift 6 语言模式或 macOS 13 最低运行版本。
后续升级必须一起验证安装选择、编译、测试和双架构打包。

macOS PR 构建分别产出 Apple Silicon（`arm64`）和 Intel（`x86_64`）包，
两个架构任务在资源允许时并行运行。推送到 `main` 或手动运行时，再使用相同
编译产物组装通用 DMG；Windows 构建一次 Release 包和前端类型检查，产出
Windows x64 NSIS 安装包。

CI 缓存 Cargo fingerprints、build script outputs 和依赖 outputs，不缓存
最终可执行文件。缓存覆盖 `rust/target/macos` 的 Rust Core 和 `rust/target`
的数据库辅助 crate；缓存键必须包含运行器架构、编译器、Xcode/SDK/macOS
版本、构建参数、依赖 manifest 和 build script。最终打包仍然重新运行必要的
构建步骤，确保产物来自当前验证过的源代码。

每个测试包同时提供 SHA-256 校验和。artifact 默认保留 14 天；DMG 和 NSIS
本身已经压缩，因此包裹 artifact 使用压缩级别 0。macOS CI 使用临时 ad-hoc
签名，Windows CI 安装包不假定已经配置发布者证书。

PR 的测试合并提交必须在构建摘要中可追溯。macOS 任一架构失败都使 macOS
gate 失败；架构任务使用 `fail-fast: false`，以便另一架构仍可完成并上传
诊断产物。文档-only 变更可以跳过产品打包，但需要完整验证时应通过工作流
手动运行请求。

并发缓存主要缩短串行等待和反馈时间，不承诺减少总 runner 分钟；队列等待
和可用 runner 数量属于 CI 基础设施因素，不能与编译优化混为一谈。

## 考虑过的备选方案

### 在旧 runner 上用 Swiftly 安装独立编译器

这能单独选择 Swift，但安装器失败会阻断所有后续验证，且 SDK 与编译器可能
来自不同版本。当前需要的 Swift 已随 Xcode 26.6 提供，所以使用预装 Xcode，
不再额外下载工具链。runner 删除固定 Xcode 时，工作流会明确报错，届时重新
验证并升级版本组合。

### 缓存最终可执行文件

可以减少部分打包时间，但容易受到源码、编译器、SDK 和构建参数变化影响，
也会掩盖当前提交是否真正完成构建，因此不采用。

### 只缓存下载依赖

能减少网络等待，但无法覆盖 Rust Core 和数据库辅助 crate 的主要编译成本，
因此扩展为缓存 Cargo 的中间输出和 build script 结果。

### 只构建一个 macOS 架构

可以降低 CI 成本，但无法发现另一架构上的编译、链接和打包问题。macOS 产品
仍保持双架构验证，只有通用包组装复用已经验证过的编译结果。

### 为所有 CI 任务强制上传完整安装包

会增加文档-only 或不需要产品包的构建时间和存储成本，因此只在产品构建 lane
被选中时上传测试包。

## 后果

- PR 能较早获得两个 macOS 架构和 Windows 产品包，问题定位更接近真实安装物。
- 缓存命中时可减少 Rust 相关重复编译，同时通过完整缓存键避免跨环境误复用。
- artifact、校验和、合并提交与 gate 结果共同提供可追溯的测试交付物。
- 冷构建、编译器变化、依赖变化和 runner 排队仍可能很慢，不能把缓存策略
  当作总耗时保证。
- 构建工作流调整时必须同步检查缓存键、包架构、gate 依赖和 artifact 保留期。

## 验证

- `actionlint .github/workflows/ci-macos.yml .github/workflows/ci-windows.yml`
- `./scripts/test-macos.sh`
- `./scripts/verify-windows-boundaries.sh`
- `gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'`
- `gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-windows-x64-*'`

具体下载方式、工作流入口和历史耗时记录见
[`docs/ci-builds.md`](../../../../docs/ci-builds.md)。

## 适用范围

- `docs/ci-builds.md`
- `.github/workflows/ci-macos.yml`
- `.github/workflows/ci-windows.yml`
- `rust/`
- `macos/`
- `windows/tauri/`
