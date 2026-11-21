# Agent 笔记：控制台保留原始字节并逐行解码

状态：已实现

## 先说结论

运行、构建和测试的进程输出必须以原始字节交给 Rust Core。Core 按行选择编码，再移除终端转义并返回文字和颜色范围。应用的“工具 › 控制台”设置可以固定编码；自动模式的候选顺序来自同一个 Core 解析结果。

## 问题

Windows 程序向管道写入时可能使用系统 ANSI 代码页，例如简体中文系统的 GBK。Go 字符串可以保留这些字节，但直接把它作为 JSON 文本发送会先把非法 UTF-8 替换成乱码；到了 Core 已无法恢复。一次构建中的不同程序还可能分别输出 UTF-8 和 GBK，不能给整个控制台猜一次编码。

## 决策

- 平台适配器只读管道字节并报告是否为 Windows。默认在所有平台使用 UTF-8，仅 Windows 为不能按 UTF-8 读取的行增加 GBK 回退，不依赖系统语言或 ANSI 代码页；用户和插件仍可显式声明其他编码。
- Core 使用 `encoding_rs` 的编码表逐行选择。自动候选依次是插件显式声明、UTF-8，以及仅 Windows 的 GBK，去重；显式设置只用指定编码。候选都不能无损读取时，选择替换字符最少的结果，平手按候选顺序。
- 字节先按换行拆分，再解码；只支持换行和 ESC 不会出现在多字节字符内的兼容 ASCII 编码，因此不接受 UTF-16。跨块字符和未结束行由 Core 状态保留，桌面端不得先修正 UTF-8。
- 每个控制台启动时保存设置快照；后续设置变更只影响新控制台。后台进程观察器通过原子快照读取偏好，不直接访问界面线程持有的可变设置。
- 设置的自动候选由 Core 返回，编码显示名与文件编码选择器共用。加载、失败和自动候选都有明确文本；ⓘ 解释候选顺序和生效时机。解码失败沿用已有后台失败事件，每个控制台只记录一次降级。
- 插件通过通用的 `outputEncoding` 可选字段声明输出编码。运行时或构建工具专属参数由插件决定，不在宿主按工具名添加分支。完整接口与夹具只在 Core 仓库维护。

正确做法：将 `B9 B9 BD A8` 原样编码为 base64 发送，Core 得到“构建”，再供复制、搜索和链接识别使用。不要先把这些字节作为 JSON 的文本字段发送，也不要在平台层另外维护编码猜测顺序。

## 考虑过的备选方案

- 统一给程序添加 UTF-8 参数：不同运行时参数不同，子进程也可能不遵守；不能解决通用宿主的字节丢失，工具专属设置仍属于插件。
- 整个控制台只选一次编码：无法处理 UTF-8 和系统编码按行混合的输出。
- Go 端解码后发送文本：会让平台层持有第二份编码规则，改用 Core 统一处理。

## 后果

原始字节穿过 JSON 边界后仍可恢复，现有颜色、复制、搜索、链接和输出快照沿用解码后的文本。代价是 base64 传输和未结束行预览；块大小、行长度、样式数量继续受 Core 限额约束。自动模式是候选校验，不是任意语言的可靠识别；存在字节歧义时需要插件声明或用户固定编码。已按用户指定在 SSH Windows 11 原生 x64 主机验证管道、编码、设置与竞态；完整应用窗口的 Run、Build、Tests 及复制、链接操作仍须逐项验收，无头截图不能替代它。宿主固定到 Core PR [#128](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/128) 的 `604699f` 修订，包含最终 UTF-8/Windows GBK 策略与插件声明契约；本地也可用 `LITHE_CORE_RUST_DIR` 链接配套 Core 工作区。

## 验证

- macOS 定向计时记录 94 项通过，Windows 11 原生 x64（SSH 主机）记录 95 项通过；真实 stdout/stderr 子进程先写半个 GBK 字符，收到 stdin 握手后再写余下字节。两端相关工作台和设置测试均通过竞态检测，中英文明暗设置截图均已生成。未进行完整应用窗口验收。
- Apple M4 上 release 桥接基准每批约 256 KiB、32 KiB 分块、5 次中位数：纯 UTF-8 的旧 text 通道 3.156 ms、新 bytes 通道 3.631 ms（约 +15%），99% UTF-8 行混入 1% GBK 行 3.551 ms。Go 累计分配约从 1.91 MiB/批增至 2.55 MiB/批；不代表常驻内存，不包含 Rust 分配或 UI 绘制。这是同一 Core 保留的 text 通道对照，不是旧版二进制；混合结果在波动范围内，不能据此声称零开销或更快。原始报告保存在本地 `.artifacts/console-encoding/`。
- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench ./internal/pluginservice ./internal/buildprocess ./internal/settingswindow -count=1`：重放所链接 Core 的编码与样式夹具，验证声明传递、跨块字符、设置快照、设置选择与恢复。
- `LITHE_VISUAL_OUTPUT_DIR=.artifacts/console-encoding/screenshots scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/settingswindow -run '^TestVisualConsoleEncoding$' -count=1`：检查中英文、明暗主题的设置页和编码下拉。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认平台生产路径保持发行目录只读。

## 适用范围

- `desktop/internal/core/output_style.go`
- `desktop/internal/workbench/output_style.go`
- `desktop/internal/workbench/console_encoding.go`
- `desktop/internal/buildprocess/`
- `desktop/internal/settingswindow/console_view.go`
- `shared/platform-feature-matrix/features/console-output-encoding.json`
