# Agent 笔记：Windows 内容搜索分页与替换一致性

状态：已实现

## 先说结论

Windows 的内容搜索使用 Core 的真实分页游标，并在截断前过滤路径；匹配行和列也由 Core 提供。替换先对已读取的文本快照生成计划，再由宿主确认缓冲区或磁盘身份后写入。

## 问题

旧接口把一批命中数当作文件分页状态，过滤发生在截断之后，后面的文件可能永远不可见。搜索使用 Core 的逐行规则，而替换使用 JavaScript 正则；例如整词 `foo` 会错误替换 `$foo`。Unicode 小写展开还会让小写文本与原始文本的字节偏移不同。

## 决策

普通工作区内容搜索复用 Core 的绑定查询游标；多根工作区的外层游标记录当前根，跨页命中同一文件时合并。包含与排除条件在 Core 截断前生效，原始行与 UTF-16 匹配范围用于显示和定位。WSL 等提供者由宿主分批读取文本，Core 对每批应用相同匹配规则，不为每个文件单独跨进程调用。

替换只向 Core 提交文本快照和匹配选项，不让 Core 写文件。打开的文件在更新前检查所属工作区生命周期、缓冲区身份和原文；本地关闭文件用平台条件保存检查字节身份并保留编码。提供者文件目前没有原子条件写接口，只能在写入前重新读取并检查；不要把该检查宣称为原子保证。

正确例子：搜索到 `😀 foo` 时，Core 返回 UTF-16 范围，替换前再次确认原文仍是快照。不要先按小写文本的字节位置切原始 Unicode 字符，也不要在过滤前截断后宣称已搜完。

## 考虑过的备选方案

只在前端把被过滤的页丢弃仍可能丢失被旧接口截断的后续结果；再维护一套 JavaScript 正则会继续让搜索和替换分歧。预先读取所有命中并在前端分页会扩大首屏内存和延迟。

## 后果

正文游标按路径和行前进，索引变化插入游标之前的命中需要重新搜索。单文件在两个页中出现时必须合并结果。批量替换在失败时等待已开始的写入结束，不能承诺跨文件事务回滚；提供者文件的原子条件写仍需平台能力。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core --test-prefix tests::project::search_ --max-ms 30000 --report .artifacts/test-stability/search-project.json`
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core --test-prefix project::files::event_filter_tests:: --max-ms 30000 --report .artifacts/test-stability/search-replacement-core.json`
- Windows 使用稳定性脚本分别运行 `file-search-api.test.ts`、`provider-content-search.test.ts`、`editor-app.store.test.ts` 和内容搜索会话测试；测试覆盖跨根与同文件续页、过滤优先、Unicode、缓冲区变化、工作区重开和磁盘身份冲突。
- macOS 搜索套件确认原有 Search Everywhere 消费者兼容新增可选字段；真实项目与 WSL 写入验收仍需单独进行。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/files.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/files.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/search_paging.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/search_paging.rs)
- `windows/tauri/src/features/file-search/lib/file-search-api.ts`
- `windows/tauri/src/features/global-search/`
