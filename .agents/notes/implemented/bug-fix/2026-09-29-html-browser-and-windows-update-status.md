# Agent 笔记：HTML 在浏览器中打开使用系统默认浏览器

状态：已实现

## 先说结论

HTML 文件的“在浏览器中打开”必须交给系统默认网页浏览器（HTTP 处理程序），不能依赖 HTML 文件关联，因为用户可能把 HTML 默认交给文本编辑器。有未保存修改时先走受保护保存，再把磁盘上的文件交给浏览器；此操作不创建服务器、不下载资源，也不写安装目录或 app bundle。

## 问题

Issue #966 中，“在浏览器中打开”按钮调用的是普通文件打开接口。HTML 文件一旦关联到文本编辑器，按钮就会把文件打开到编辑器里，而不是浏览器。

## 决策

- 外部浏览器走系统默认网页浏览器，不走文件关联。桌面端的入口是 `editor.openInBrowser`（`desktop/internal/workbench/browser_preview.go`），经 Viva 的 `OpenPathInBrowser` 交给系统默认浏览器。
- 有未保存修改或正在保存时，先经受保护的保存路径写盘，成功后才打开；保存失败或被取消时不打开浏览器。
- 外部浏览器读取的是磁盘上的已保存文件，内嵌预览继续读取编辑缓冲区。两者的内容可以不同，界面不应把它们混为一谈。

正确做法：通过系统默认网页浏览器打开文件。
不要这样做：按文件扩展名或文件关联选择打开程序。

## 考虑过的备选方案

本地 HTTP 静态服务器能支持模块脚本和自动刷新，但需要端口、文件访问边界和工作区清理责任。这里只需要选择浏览器，直接复用系统能力可以避免引入服务器生命周期。

## 后果

HTML 不再因为文件关联跳进编辑器。代价是普通文件预览仍受浏览器 `file` URL 的限制，与内嵌预览的行为可能不同。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestOpenInBrowserGivesTheFileToTheDefaultBrowser`
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`
- 实机验证仍需完成：把 HTML 关联改为编辑器，再检查浏览器按钮是否打开默认浏览器。Linux 环境不能代替 macOS 与 Windows 上的默认浏览器验证。

## 适用范围

- `desktop/internal/workbench/browser_preview.go`
- `desktop/internal/workbench/browser_preview_test.go`
