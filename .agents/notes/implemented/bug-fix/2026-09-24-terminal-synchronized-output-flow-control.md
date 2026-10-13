# Agent 笔记：终端同步输出的有界缓冲和流控

状态：已实现

## 先说结论

终端应用层可以把 DEC 2026 同步帧合并后交给 xterm，但不能无限等待结束标记。同步状态最多保持 1 秒；应用层待写数据达到 500KB 时立即交给 xterm，并继续让协议状态和超时计时器运行。错误、退出和用户输入会主动 flush，避免控制流被挂起的帧挡住。

## 问题

`ESC[?2026h` 表示同步输出开始，`ESC[?2026l` 表示结束。程序崩溃、被 Ctrl+C 中断或输出帧过大时，结束标记可能不到达。若应用层一直保留待写数据，写入完成回调不会执行，PTY 流控计数持续增长；达到高水位后再暂停 PTY，会阻止结束标记到达并形成死锁。

## 决策

`TerminalOutputWriteBuffer` 使用三个有界条件：正常结束标记后的 40ms 合帧窗口、同步状态的 1000ms 超时、与终端输出高水位相同的 500KB 待写上限。达到待写上限时只 flush 当前批次，不清除同步协议状态；这样后续分片仍能识别结束标记，同时不会让应用层队列继续增长。

连接层在输出写入后再判断流控。如果本次写入因水位已 flush，或仍有同步帧待写，就不暂停 PTY；结束标记可以继续抵达。普通输出没有待写同步帧时仍使用原有高低水位暂停和恢复逻辑。终端输入、错误、退出和组件清理都会调用强制 flush，强制结束应用层等待状态，但 xterm 仍负责解析和渲染 DEC 2026。

正确做法：把分片交给 `TerminalOutputWriteBuffer`，达到上限时 flush，并保留协议状态直到结束标记或超时。不要在等待结束标记期间调用 PTY pause，也不要让待写字节数没有上界。

## 考虑过的备选方案

可以完全移除应用层缓冲，只依赖 xterm 6.0.0 自带的 DEC 2026 超时。但这会放弃现有 40ms 合帧行为，无法继续缓解分片输出造成的中间重绘；本次选择保留合帧，同时补齐超时和水位兜底。

## 后果

缺少结束标记时，最多等待 1 秒后恢复输出；大帧会按 500KB 批次交给 xterm，不会因为应用层队列达到高水位而阻塞 PTY。代价是超大同步帧可能分批写入，最终渲染一致性由 xterm 的 DEC 2026 处理。Windows 实机仍需验证 ConPTY 在暂停、恢复和 Ctrl+C 场景下的实际时序。

## 验证

运行 `bun test src/features/terminal`、`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 和 `./scripts/verify-windows-boundaries.sh`。缓冲测试覆盖只有开始标记、超时自动 flush、达到待写水位、结束标记分片、错误和清理路径。

## 适用范围

- `windows/tauri/src/features/terminal/utils/terminal-output-write-buffer.ts`
- `windows/tauri/src/features/terminal/hooks/use-terminal-connection.ts`
- `windows/tauri/src/features/terminal/utils/terminal-protocol.ts`
- `windows/tauri/src/features/terminal/utils/terminal-output-write-buffer.test.ts`
