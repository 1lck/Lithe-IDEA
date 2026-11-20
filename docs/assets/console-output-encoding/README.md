# 控制台输出编码截图证据

这是设置页的实际 Viva 无头截图。设置页由本次新增，旧版没有对应页面；未伪造旧版对照图。图片不包含用户项目或个人路径。

- macOS：桌面基于 `0119f4107`，任务提交 `7a6e35315`，配套 Core PR [#128](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/128)；main 更新后的 Viva 版本已重新采集。编码候选使用真实 Core 的 `windows: true` 策略以检查较长候选文本，**不是 macOS 默认**；macOS 实际默认候选只有 UTF-8。
- Windows：桌面基于 `4d1b88f03` 加本任务补丁，Core `3ec738a` 加最终 UTF-8/Windows GBK 补丁；Windows 11 原生 x64 SSH 主机，Go 1.27.3、Rust 1.100.0 GNU 目标。本次基线更新之前采集，最新 Viva 版本未在 Windows 重拍，PR 保持 Draft。
- 场景：`page` 为设置页，`choices` 为输出编码菜单；每端含英文/中文、深色/浅色，共 8 张。每张 1800×1400 像素。
- 命令：`LITHE_VISUAL_OUTPUT_DIR=<输出目录> scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/settingswindow -run '^TestVisualConsoleEncoding$' -count=1 -timeout=90s`，当时通过 `LITHE_CORE_RUST_DIR` 链接配套 Core。
- 完整应用窗口的 Run、Build、Tests、复制和链接操作未逐项验收；截图和编码组件测试不替代该验收，功能矩阵保持 `pending`。

目录 `macos/` 和 `windows/` 保存上述实际采集的 PNG，PR 使用分支链接嵌入。
