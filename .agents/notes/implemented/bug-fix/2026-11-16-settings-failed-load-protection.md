# Agent 笔记：读不出的偏好文件在下一次保存前另存，不被默认值覆盖

状态：已实现

## 先说结论

桌面端用默认值继续启动，不等于磁盘上的偏好文件可以被默认值替换。`store.Load` 读取或解码某个文件失败后，同一个 Store 下一次 `Save` 这个文件时，先把原文件改名为 `<名称>.unreadable-<UTC 时间>`（`store.SetAsideName`），再正常写入新值。原内容一字节不丢，之后的保存照常进行。设置无法读取时，桌面端启动后提示当前使用默认设置。首次保存移走原文件后，通知显示实际备份路径。

## 问题

#1943 中，损坏的 `settings.json` 让 `workbench.New` 用默认设置启动；之后改主题等操作调用 `saveSettings`，用默认值原子替换整个文件，出错位置之外的设置全部丢失。原子写入只防止写到一半中断，不能阻止用失败的读取结果覆盖原文件。

## 决策

### 正确做法

- `desktop/internal/store/store.go` 按文件名记录最近一次 Load 的致命读取或 JSON 解码错误。`Save` 先调用 `setAside`：在同一把锁内检查失败记录、改名、清除记录，所以并发的两次保存只会移走一次原文件，不会把第一次刚写好的新文件也移走。
- 改名失败时保留失败记录并让这次保存报错，原文件留在原处；文件已经不存在时没有要保留的内容，直接写入。
- Load 成功、文件不存在，或 `Remove` 成功（包括本来就不存在）时清除失败记录；删除失败不清除。
- 未知键、当前版本不能解码的字段类型仍由现有 `kept` / `Unread` 原样写回，不算致命失败，也不触发另存。
- 每个文件独立：某个文件读不出，不影响其他文件保存。

### 不要这样做

- 不要在加载失败后直接用默认值覆盖原文件。
- 不要改成“加载失败后拒绝保存”：Store 还保存最近项目、编辑器会话、插件启用状态等文件，拒绝保存会让这些文件在损坏后永远写不进去，每次保存都报错，直到用户手动删除文件。
- 不要把可恢复的字段类型不兼容当作致命失败，否则跨版本保留失效。

## 考虑过的备选方案

### 加载失败后拒绝保存（本 PR 初版）

能保住原文件，但对 Store 的所有文件生效，损坏的状态文件再也无法自愈；只对 `settings.json` 生效又要在通用存储层按文件名特判。已改为另存。

### 只在工作台层跳过保存

改动小，但其他 Store 使用者仍会在类似失败后覆盖原文件，所以由存储层统一处理。

## 后果

- 原内容保存在同目录的 `.unreadable-*` 文件里，用户可以对照修复后放回。
- 每次致命读取失败最多产生一个另存文件；文件不再被读取，不增加后台任务。
- 启动提示保留在通知历史。备份路径取自存储层实际完成的改名，因此替换文件写入失败时用户也能找到原内容。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/store -run 'TestSave|TestLoad|TestUnread' -count=1`

- `scripts/desktop/desktop-go.sh test -tags vivahead ./internal/workbench -run TestUnreadableSettingsWarnAtStartupAndIdentifyTheBackupOnSave -count=1`

## 适用范围

- `desktop/internal/store/store.go`
- `desktop/internal/store/store_test.go`
- `desktop/internal/workbench/app.go`
