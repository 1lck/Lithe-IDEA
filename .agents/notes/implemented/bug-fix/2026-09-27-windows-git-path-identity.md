# Agent 笔记：Windows Git 路径往返必须保持文件身份

状态：已实现

## 先说结论

Windows 的原生网络路径（UNC）和扩展长度路径（verbatim，带 `\\?\` 前缀）必须先规范化，再判断是否为绝对路径。Git 暂不支持路径分量末尾为 ASCII 点或空格，保留的 DOS 设备文件名、扩展路径内的 `.`/`..` 分量，以及盘符/UNC 之外的设备命名空间；遇到这些输入必须明确报错，不能通过去前缀或清理空白访问另一个文件。

## 问题

Issue #627 中，前端先判断绝对路径再替换反斜杠，把原生 UNC 文件拼进了当前仓库。Core 同时无条件去掉规范路径的扩展前缀，但该前缀会改变 Windows 的路径解析规则，去掉后不一定还是原来的目录。

## 决策

- 界面拼接仓库根之前，必须使用 Core 规范化后的路径；不得自行去掉扩展前缀、替换分隔符后再判断是否绝对路径。
- Core 在文件系统查找之前、规范化之后及读取 Git 返回路径时校验不支持的名字，返回 `invalid_request`。已删除工作树仍可使用原路径展示，但不能让这个回退吞掉不支持路径的错误。
- 去掉 Git 输出的行结束符时不使用会吞掉文件名空格的 `trim()`。正常盘符/UNC、中文、内嵌空格和长路径继续通过原生 Git 处理；不凭长度推断它们不可用。
- `remote://`、`wsl://` 保留协议和远端 POSIX 文件名语义，不对远端目录套用 Windows 尾部点/空格限制。
- 界面展示用的路径比较不得抛错或改写身份；执行入口使用带校验的结果，把错误交给已有的状态或错误提示。

正确例子：`\\?\C:\work\repo\src\main.ts` 解析为仓库 `C:/work/repo` 与相对文件 `src/main.ts`。
不要把 `\\?\C:\work\repo.` 改写成 `C:/work/repo`，也不要在校验失败后改用活动仓库继续操作。

## 考虑过的备选方案

全链路保留扩展前缀可以支持更多特殊名字，但当前界面、Git 工作目录和原生监听器都消费普通路径，局部保留不能保证往返身份一致。静默删除尾部点、空格或前缀会访问错误对象，因此采用显式拒绝，待所有消费者能够保留语义时再扩大支持范围。

## 后果

普通 UNC 文件不会再被错误拼接，危险的路径转换会变为可见错误。代价是含尾部点/空格的 Windows 仓库当前不能使用 Git 功能；这项限制必须由 Core 校验和共享样例一起维护，不能只在界面层放开。

## 验证

- Core 仓库的 `rust/fixtures/git/windows-paths.json` 是 Core 侧路径样例的共享输入。
- 桌面端 `scripts/desktop/desktop-go.sh test ./internal/core/...` 经 C ABI 调用 Core 的路径解析与 Git 命令。
- 长路径和末尾点/空格目录需要在 Windows 实机上确认请求被明确拒绝，而不是误用普通同名目录；这项验收尚未记录在本仓库。
- Core 的 watcher 测试用有界事件接收验证共享引用与独立 HEAD 元数据的通知，不用 sleep 等待防抖。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/mod.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/mod.rs)
- `desktop/internal/core/`（Git 命令桥接）
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`
