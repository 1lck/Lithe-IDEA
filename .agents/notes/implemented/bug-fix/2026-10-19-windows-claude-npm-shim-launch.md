# Agent 笔记：Windows Claude 适配器不能直接启动 npm 命令垫片

状态：已实现

## 先说结论

Windows 上通过 npm 安装的 `claude` 命令是一个 `.cmd` 文件。Claude 的 ACP
适配器把这个路径直接交给 Node.js 的 `child_process.spawn`，Windows 会以
`spawn EINVAL` 失败。现在只有能通过 shell 启动垫片的适配器才接收 `.cmd`
路径；Claude 在 Windows 保留 Claude Agent SDK 自带的原生启动器。

## 问题

用户已在 Windows 安装 Claude Code，Agent 设置也能检测到有效的 CLI 版本，
但连接 Claude 时只得到 `Internal error: { "details": "spawn EINVAL" }`。

根因不在 ACP 握手，而在启动参数：

- Lithe 的共享 Agent Host 把检测到的 CLI 绝对路径写入
  `CLAUDE_CODE_EXECUTABLE`。
- npm 在 Windows 为该命令生成 `claude.cmd`，实际原生程序位于包的
  `node_modules/@anthropic-ai/claude-code/bin/claude.exe`。
- Claude ACP 适配器优先使用该环境变量，并直接
  `spawn(process.env.CLAUDE_CODE_EXECUTABLE, args)`；Node.js 不能直接执行
  批处理文件。
- 安装 Claude 适配器时原本统一传入 `--omit=optional`，同时跳过了 SDK 的
  `@anthropic-ai/claude-agent-sdk-win32-x64` 原生依赖，使适配器没有可用的
  回退启动器。

## 决策

- `AgentCli` 增加 `accepts_windows_shim`，明确每个适配器能否接收 npm 的
  `.cmd` 垫片。Codex 的中继使用 `shell: true`，可以接收；Claude 适配器直接
  spawn，不能接收。
- Windows 上 Claude 适配器安装时不再传 `--omit=optional`，从而安装 SDK
  声明为 optional dependency 的本机原生 `claude.exe`。macOS 和 Codex 继续
  跳过 bundled 副本，避免重复下载。
- 启动 Claude 时不再把 `.cmd`/`.bat` 路径写入 `CLAUDE_CODE_EXECUTABLE`。
  Claude 适配器会按自身固定版本解析 bundled 原生启动器。
- 启动 Anthropic Messages 连接前移除继承的 `CLAUDE_CODE_EXECUTABLE`，再由
  Lithe 解析出的有效路径重新写入。这样用户 shell 里遗留的旧垫片路径也不会
  绕过本次判断。

正确做法：Windows 上让 Claude 适配器使用随适配器安装的 SDK 原生启动器；
Codex 仍可把 `codex.cmd` 交给带 shell 的中继。

不要这样做：给所有适配器统一去掉 `--omit=optional`，这会为 macOS 和 Codex
重复下载用户已有的 CLI；也不要让 Claude 适配器直接 spawn `.cmd`。

## 考虑过的备选方案

- 解析 npm `.cmd` 文件并取出其中的原生 `.exe`：可以省下一次下载，但依赖
  npm 垫片的文本格式和包内布局；包升级或改用其他安装器时容易再次失效。
- 让 Claude 适配器通过 `cmd.exe /c` 启动：适配器拥有启动实现，Lithe 无法
  只通过环境变量追加 shell 参数，而且会改变参数转义规则。
- 只清空 `CLAUDE_CODE_EXECUTABLE`：适配器会报“找不到原生二进制”，因为
  安装阶段已经把 optional 依赖省略了。

## 后果

- Windows 首次安装或重新安装 Claude 适配器时会多下载一个平台原生
  `claude.exe`，换取不依赖用户 CLI 的启动垫片格式。
- 已安装旧版适配器的测试机需要重新安装 Claude 适配器，才能获得该原生
  启动器。
- 真实 CLI 版本检测仍保留，界面继续提示 Claude Code 过旧或缺失；本次修复
  只改变适配器实际启动哪个可执行文件。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-agent-host`
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-agent-host`
- `windows/tauri`: `bun run typecheck`
- `rust/lithe-agent-host/src/tests.rs` 覆盖 `.cmd` 只转发给接受垫片的适配器，
  `.exe` 仍写入 `CLAUDE_CODE_EXECUTABLE`。
- `rust/lithe-agent-host/src/install.rs` 覆盖 Windows 上 Claude 不省略 optional
  依赖、Codex 继续省略。
- Windows 真机使用 bundled `claude.exe` 2.1.280 完成验证：ACP 连接返回
  `ready`，新建会话、发送消息、Anthropic mock 流式回复和 `turnFinished`
  均正常；关闭连接后没有 Claude 子进程残留。

## 适用范围

`rust/lithe-agent-host/src/catalog.rs`、`install.rs`、`lib.rs` 及其测试。
macOS 的启动路径不变；Codex 的 `CODEX_PATH` 与 shell 中继不变。
