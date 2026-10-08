# Agent 笔记：Debug断点点击与装饰共享路径身份

状态：已实现

## 先说结论

将装饰已有的字面路径键提取到Debug工具函数；store切换与按文件查询共用它。点击移除同一file/line的历史别名记录，不更改存储原始路径，也不处理其他位置的断点。

## 问题

编辑器可显示Windows大小写/分隔符别名断点，但store按原始字符串切换和查询，第二次点击产生重复断点而非移除。

## 决策

将装饰已有的字面路径键提取到Debug工具函数；store切换与按文件查询共用它。点击移除同一file/line的历史别名记录，不更改存储原始路径，也不处理其他位置的断点。

## 考虑过的备选方案

不在store导入Monaco投影形成循环；不只修gutter点击而遗留按文件查询；不无差别lower-case所有POSIX路径；不迁移所有用户存储或引入原生文件读取。

## 后果

新增真实store/装饰/隔离localStorage回归并登记Windows CI。盘符路径沿用现有大小写规则，POSIX区分大小写；符号链接、远程路径和完整GUI/DAP后端验收不在此变更中。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/debugger/stores/debugger-breakpoints.test.ts`

## 适用范围

- `windows/tauri/src/features/debugger/utils/debug-source-path.ts`
- `windows/tauri/src/features/debugger/stores/debugger.store.ts`
- `windows/tauri/src/features/debugger/stores/debugger-breakpoints.test.ts`
- `windows/tauri/src/features/debugger/services/monaco-debug-decorations.ts`
- `.github/workflows/ci-windows.yml`
- `shared/platform-feature-matrix/features/debug-breakpoints.json`
