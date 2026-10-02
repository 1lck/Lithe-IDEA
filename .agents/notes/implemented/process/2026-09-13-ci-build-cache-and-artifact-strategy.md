# Agent 笔记：CI 构建缓存与测试产物策略

状态：已实现

## 先说结论

CI 缓存的是经过版本和依赖约束的中间构建结果，不缓存最终安装包。普通
PR 先通过编译和测试获得快速反馈；macOS 仅在包敏感改动时生成测试包，
Windows PR 不再生成安装包。Windows 安装包由 preview 和稳定版发布工作流
负责，避免发布产物阻塞日常代码验证。

## 问题

Lithe 同时构建 macOS 双架构产品、通用 macOS 包和 Windows 安装包。Swift、
Rust Core、数据库辅助 crate 和前端构建的耗时来源不同；如果只缓存最终
可执行文件，容易复用错误的构建结果，也无法稳定获得测试安装包。

## 决策

macOS CI 与发布工作流统一使用 `macos-26` runner 上的 Xcode 26.6，编译器
固定为 `.swift-version` 中的 Swift 6.3.3。共用的 `setup-macos-toolchain` action
选择 Xcode 后校验实际编译器版本；不一致就立即失败，不能悄悄使用 runner 的
默认版本。SwiftPM 缓存键与完整性校验都读取这个版本文件。这个基线不能因为
某台开发机升级了 Xcode 27 而改变，否则仍在 macOS 15 上工作的开发者会被迫
升级开发环境。

此前在旧 runner 上通过 Swiftly 安装独立工具链失败，测试未能启动。因此继续
使用完整 Xcode，让 Swift、链接器和 SDK 保持匹配。Xcode 27/SDK 27 只作为
开发者本机的兼容路径，不进入 CI 基线；`MacOS13SDKCompatibility.h` 仅在
macOS 13 SDK 上补充缺失的 `NSView.clipsToBounds` 声明，SDK 14 及更高版本
不会重复导入 AppKit，也不会触发模块定义冲突。这个修复同时覆盖旧 SDK 和
SDK 27。升级工具链不改变应用的 Swift 5 语言模式、测试的 Swift 6 语言模式
或 macOS 13 最低运行版本。

部分新版 SwiftPM 会把 `--triple` 的默认产品放在 `.build/out/Products`，
不再自动隔离 arm64 与 x86_64。构建脚本先读取 `swift build --show-bin-path`
判断实际布局：只有检测到这个新版布局时才使用 `.build/<triple>` 作为独立
scratch path；Xcode 26.6/Swift 6.3.3 继续使用原来的默认路径。插件构建同时
兼容旧版的 `Modules/` 目录和新版直接放在产品目录中的模块文件。

路径分类器先决定 PR 需要哪些验证。普通 `macos/Sources/` 改动由 Swift 测试
负责完整编译，不再重复生成两个 DMG。资源、SwiftPM 图、Rust bridge、平台
组合、打包脚本和工具链等改动仍分别产出 Apple Silicon（`arm64`）和 Intel
（`x86_64`）包，两个架构任务在资源允许时并行运行。需要任意分支的完整包时，
开发者可以手动运行工作流。

Git 性能基线和 Git 状态观察属于专项验证。只有 Git 生产代码、对应专项测试或
测试工具链发生变化时才运行；普通搜索、编辑器或设置界面改动不会为无关的
Git 性能测试增加等待时间。推送到 `main` 或手动运行时，再使用相同编译产物
组装通用 DMG。Windows PR 把前端验证与 Rust 测试放在两个独立 job 中并行
执行；Windows x64 NSIS 安装包只由 preview 和稳定版发布工作流生成。

Git 图形的离屏帧采样保留完整 1,000 行历史，但每次只绘制 40 行的可见区域，
分别覆盖开头、中间和末尾。绘制前把该区域的坐标映射到小位图，绘制后检查
实际有图形像素，避免中段被裁剪为空时得到虚假的快速结果。完整 1,000/5,000
行图结构、顺序和签名仍由独立用例与 Release 验证器检查；单帧中位数和整个
测试的时间上限保持不变。

正确做法：模拟滚动窗口的一帧，把可见区域作为绘制输入。不要把全部历史
重复绘制 220 次当作单帧采样：这会把画面之外的工作混进测试总耗时，在共享
runner 上可能出现断言都通过、计时工具仍因超过十秒而失败的情况。

CI 缓存 Cargo fingerprints、build script outputs 和依赖 outputs，不缓存
最终可执行文件。缓存覆盖 `rust/target/macos` 的 Rust Core 和 `rust/target`
的数据库辅助 crate；缓存键必须包含运行器架构、编译器、Xcode/SDK/macOS
版本、构建参数、依赖 manifest 和 build script。最终打包仍然重新运行必要的
构建步骤，确保产物来自当前验证过的源代码。

每个安装包同时提供 SHA-256 校验和。artifact 默认保留 14 天；DMG 和 NSIS
本身已经压缩，因此包裹 artifact 使用压缩级别 0。macOS CI 使用临时 ad-hoc
签名；Windows preview 与稳定版发布工作流分别执行各自的签名策略。

PR 的测试合并提交必须在构建摘要中可追溯。被分类器选中的 macOS 任一架构
失败都使 macOS gate 失败；架构任务使用 `fail-fast: false`，以便另一架构仍可
完成并上传诊断产物。Windows gate 分别检查前端和 Rust job：被选中的 job 必须
成功，未被选中的 job 必须跳过。需要 Windows 安装包时手动运行 preview 发布
工作流，不在 PR CI 中等待完整 Release 编译和 NSIS 打包。

并发缓存主要缩短串行等待和反馈时间，不承诺减少总 runner 分钟；队列等待
和可用 runner 数量属于 CI 基础设施因素，不能与编译优化混为一谈。

Windows 安装器失败时，Bun 可能已经退出，但并行的生命周期脚本仍在运行，
继续占用依赖目录；直接删除目录会让原本可以重试的下载故障变成文件锁错误。
每次安装现在由独立 PowerShell worker 拥有：启动 Bun 前把 worker 加入
Job Object（Windows 用于管理整棵子进程树的对象），设置最后一个句柄关闭时
终止成员进程。句柄不继承给子进程，由 worker 的进程生命周期持有；worker
正常结束、失败或被取消时，系统释放句柄并终止残留脚本；每次安装还有默认
300 秒的 worker 内部期限，超时退出码为 124，不能只依赖 CI 总超时。父安装器再清理
部分缓存和依赖。文件系统释放锁可能稍晚，删除重试有单调计时的 10 秒期限，
超时明确失败，不无限等待。缓存清理后撤销旧 verified 标记，冷安装成功才
重新生成完整性清单。只重试一次，不把永久安装错误隐藏成成功。

正确做法：worker 拥有 Bun 及其脚本，结束后再清理当前工作树生成目录；
不要按进程名结束所有 Node/Bun，因为用户其他工作树或应用可能正在使用它们。
这些句柄和安装目录属于本次安装，不新增可复用资源；只有经过锁文件、Bun
版本与完整性清单校验的下载缓存可以跨工作树复制，安装包仍只读。

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

### 失败后仅限制安装并发或等待固定时间

不采用。相同 Bun 版本的本地生命周期探针表明，串行选项也不能保证失败后
没有残留脚本；固定等待则无法证明进程结束。直接结束全部 Node 还会影响
其他任务。Windows Job Object 提供系统级所有权和取消清理，代价是每次安装
多启动一个 PowerShell worker，安装路径的回归测试需要在 Windows 上运行。

### 只构建一个 macOS 架构

可以降低 CI 成本，但无法发现另一架构上的编译、链接和打包问题。macOS 产品
仍保持双架构验证，只有通用包组装复用已经验证过的编译结果。

### 为所有 CI 任务强制上传完整安装包

会增加文档-only 或不需要产品包的构建时间和存储成本。macOS 只在产品构建
lane 被选中时上传测试包；Windows PR 不上传安装包。

Windows PR 曾经只要命中产品 lane 就先生成完整 NSIS 包，导致前端与 Rust
测试必须等待 Release 编译结束。安装包不是合并判断的输入，且 preview 发布
工作流已经提供可安装产物，因此 Windows PR 完全移除打包步骤，而不是仅把它
挪到另一个仍会阻塞 gate 的 job。

### 为每个 Swift 源码 PR 强制生成双架构安装包

Swift 测试已经编译完整 Lithe 目标。再生成两个 DMG 会在普通界面或业务逻辑
改动上重复消耗约二十分钟 macOS runner 时间，并把必要反馈推迟到最慢的打包
任务结束。双架构验证因此保留给真正影响包内容和构建边界的改动；开发者需要
临时安装包时使用手动工作流。

### 提高 Git 帧采样的总时间上限

这能容纳重复绘制完整历史的耗时，却保留了与可见窗口不符的工作量，也削弱
其他测试的时间门禁。因此修正采样范围与位图坐标，继续使用原有上限；完整
图的正确性检查不减少，批量绘制不能替代可见区域的帧成本测量。

## 后果

- 普通 macOS Swift PR 更快得到必需检查结果；被选中的打包改动仍获得两个架构
  的真实安装物。
- Git 专项验证不会再延长无关 Swift 改动的反馈时间。
- 帧采样只绘制可见区域，减少与屏幕无关的测试工作；它不衡量完整历史的一次
  批量导出，也不等同于需要显式开启的真实窗口帧率采样。
- Windows 前端失败与 Rust 失败可以独立、并行反馈，不再等待 NSIS 安装包。
- 缓存命中时可减少 Rust 相关重复编译，同时通过完整缓存键避免跨环境误复用。
- artifact、校验和、合并提交与 gate 结果共同提供可追溯的测试交付物。
- 冷构建、编译器变化、依赖变化和 runner 排队仍可能很慢，不能把缓存策略
  当作总耗时保证。
- 构建工作流调整时必须同步检查缓存键、包架构、gate 依赖和 artifact 保留期。

## 验证

- `actionlint .github/workflows/ci-macos.yml .github/workflows/ci-windows.yml`
- `./scripts/test-macos.sh`
- `./scripts/test-git-performance-baseline.sh`
- `./scripts/build-macos.sh --configuration debug --triple arm64-apple-macosx`
- `./scripts/build-macos.sh --configuration debug --triple x86_64-apple-macosx`
- `./scripts/build-official-plugins.sh --configuration debug --triple arm64-apple-macosx`
- `./scripts/build-official-plugins.sh --configuration debug --triple x86_64-apple-macosx`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-windows-boundaries.sh`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory . --max-ms 30000 --report .artifacts/test-stability/windows-dependency-install.json -- scripts/windows-frontend-install.test.ts`：Windows 无网络夹具用 IPC 确认子进程占用目录，再让安装失败，验证清理后冷重试成功、永久失败仍报错、成功退出也不留子进程、超时触发本地期限，且不清除有效缓存。
- `gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'`
- `gh workflow run release-preview-windows.yml -f source_branch=<branch>`

具体下载方式、工作流入口和历史耗时记录见
[`docs/ci-builds.md`](../../../../docs/ci-builds.md)。

## 适用范围

- `docs/ci-builds.md`
- `.github/workflows/ci-macos.yml`
- `.github/workflows/ci-windows.yml`
- `scripts/classify-ci-changes.sh`
- `scripts/install-windows-frontend-dependencies.ps1`
- `scripts/invoke-windows-bun-install.ps1`
- `scripts/windows-frontend-install.test.ts`
- `scripts/test-classify-ci-changes.sh`
- `scripts/build-macos.sh`
- `scripts/build-official-plugins.sh`
- `scripts/verify-rust-core.sh`
- `scripts/MacOS13SDKCompatibility.h`
- `rust/`
- `macos/`
- `windows/tauri/`
