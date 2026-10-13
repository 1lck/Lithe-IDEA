# Agent 笔记：Windows 终端网页链接直接打开

状态：已实现

## 先说结论

Windows 终端中点击识别出的网页链接，直接交给系统默认浏览器。
取消原先每次点击都显示的外部链接确认框，localhost 与其他网页链接使用同一入口。
文件路径仍由原有文件链接入口打开，网页打开失败继续记录错误。

## 问题

`loadWebLinksAddon` 在用户点击链接后额外调用 Tauri 原生 `ask` 确认框，
确认之后才打开浏览器。本地开发服务也被视作外部链接，重复确认打断终端使用。

## 决策

保留 xterm 网页链接扩展（`WebLinksAddon`，负责识别并响应网页链接）的现有
点击回调，直接 `await open(uri)`。删除确认调用、只服务确认的设置/翻译导入，
以及中英文确认文案。系统浏览器打开仍由现有 Tauri shell 插件处理，
不增加其他浏览器启动入口，不改变识别规则与平台权限配置。

## 考虑过的备选方案

- 只豁免 localhost：仍会让其他开发服务地址重复确认，不符合用户取消确认的要求。
- 增加“下次不再询问”设置：增加设置和持久化状态，用户明确要求直接取消确认，因此不采用。

## 后果

点击网页链接少一次操作；用户点击即触发默认浏览器打开。
macOS 没有改动。确认对话框不能再作为网页链接动作的前置步骤，
文件路径打开、终端复制和其他操作的确认策略继续由各自入口负责。

## 验证

- `cd windows/tauri && bun run typecheck`、`bun run build`。
- `bun test src/features/terminal` 检查现有终端行为回归。
- `node scripts/verify-agent-notes.mjs`、`node scripts/generate-platform-feature-matrix.mjs --check`。
- 在 Windows 产品终端分别点击 localhost、127.0.0.1 和 HTTPS 链接，
  确认直接进入默认浏览器；文件路径继续打开 IDE 文件，打开失败仍记录错误。
  构建和前端回归不代替这组原生验收。

## 适用范围

- `windows/tauri/src/features/terminal/hooks/use-terminal-addons.ts`
- `windows/tauri/src/i18n/locale.ts`
