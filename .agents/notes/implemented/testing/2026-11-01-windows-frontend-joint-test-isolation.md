# Agent 笔记：Windows 前端联合测试的模块隔离

状态：已实现

## 先说结论

Windows 前端正式计时入口在一次 Bun 1.3.14 调用中运行整个测试集合，并开启原生的 `--isolate`。每个文件拥有独立的全局对象和模块替身，其他文件仍然导入真实实现。导入阶段失败也必须保留报告，不能把没有枚举到测试当成通过。

## 问题

模块替身（`mock.module`，把被导入模块替换成测试实现）会影响同一全局对象里后续文件的导入。仅清空函数调用记录或调用 `mock.restore()` 不能恢复已替换的模块导出。因此一个文件中的设置、i18n 或 Tauri 替身会让其他文件失败，逐文件通过无法证明联合入口正确。

## 决策

- 正式入口复用 Bun 原生全局隔离，仍由一次命令发现和运行所有选中的文件，输出一份 JUnit（逐项测试结果）及其 JSON、HTML 视图。JSON 记录隔离方式，保留原有逐项和整套截止时间。
- 正确做法是运行 `test-stability-windows.ps1 -Scope Frontend`。不要用脚本循环逐个启动文件，再把结果拼成联合通过。
- 替身不能跨文件提供隐含前置条件；每个测试文件声明自己需要的输入，仍须清理本文件的监听、定时器和异步工作。
- Bun 因语法或依赖加载错误尚未生成 JUnit 时，计时入口写入失败的 discovery 项并退出失败；错误报告不能代替真实测试枚举。
- 如果 Bun 只报告了已通过的文件，却因为另一个文件导入失败而退出，报告还要保留命令失败项，避免部分结果被显示为全套通过。
- `windows/tauri/bunfig.toml` 显式把 SVG 指定为文件资源，保持生产环境 Vite 的 `?url` 导入含义。简单资源冒烟不能替代完整图标依赖图验证；不修改上游 XML 注释来迁就 JavaScript 解析器。

## 考虑过的备选方案

- 循环启动每个文件：能规避污染，但隐藏正式联合入口的问题，未采用。
- 给所有模块替身逐一增加恢复调用：Bun 的模块替换不会因 `mock.restore()` 恢复，不能解决已经缓存的导出。
- 修改或删除失败断言、跳过导入失败文件：会丢失回归约束，未采用。

## 后果

文件间不再依赖执行顺序，报告仍保留所有真实案例的结果。代价是每个文件初始化自己的全局环境；文件内部的资源清理和并发正确性仍由测试负责，不能用隔离取代。

## 验证

```powershell
./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1
./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend
node --test --test-timeout=120000 .agents/skills/write-stable-tests/scripts/test-verify-test-stability.mjs
```

最小反例用两个文件导入同一模块：第一个替换导出，第二个断言真实值。默认共享全局会失败；原生隔离在一次调用中运行两者并通过。具体源码快照的完整测试数量和失败以当次产物为准，不能沿用旧轮通过证据。

## 适用范围

适用于 `.agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs` 和 Windows 前端 Bun 测试。它不证明真实 WebView2、宿主进程、JDT 或插件工作流通过。
