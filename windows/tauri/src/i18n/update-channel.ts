export const updateChannelEnglish = {
  "update.channel": "Update channel",
  "update.channelStable": "Stable (recommended)",
  "update.autobuildBuiltAt": "AutoBuild — Built at {timestamp}",
  "update.autobuildWarning": "AutoBuild is a rolling development release and is likely to contain many bugs and unfinished features. Ordinary users should stay on Stable.",
  "update.confirmAutobuild": "Use the AutoBuild rolling channel?",
  "update.useAutobuild": "I understand — use AutoBuild",
  "update.channelSaveFailed": "Could not save the update channel. Check application storage and try again.",
  "update.manualDownloadExplanation": "This channel requires a manual installer download. Open the selected release page, choose the Windows installer, save your work and close Lithe before running it. Lithe and Lithe-Dev install separately. On its first launch, Lithe-Dev copies Stable settings and workspaces if it has no user data; then both apps save settings and caches independently. Some accounts may need sign-in again. The displayed version may be lower or unchanged; it cannot determine whether this rolling build is newer. Lithe has not checked that you have the latest build.",
  "update.manualDownloadStatus": "Use the selected channel’s release page to download and install. Build freshness has not been checked.",
  "update.manualDownloadTitle": "Install from release downloads",
  "update.acknowledgeDownload": "I understand — open release downloads",
  "update.viewDownloads": "View release downloads",
};

export const updateChannelChinese: Record<keyof typeof updateChannelEnglish, string> = {
  "update.channel": "更新通道",
  "update.channelStable": "稳定版（推荐）",
  "update.autobuildBuiltAt": "AutoBuild — 构建自 {timestamp}",
  "update.autobuildWarning": "AutoBuild 是滚动开发版本，很可能存在大量错误和未完成功能。普通用户请继续使用稳定版。",
  "update.confirmAutobuild": "切换到 AutoBuild 滚动通道？",
  "update.useAutobuild": "我已了解，使用 AutoBuild",
  "update.channelSaveFailed": "无法保存更新通道，请检查应用存储后重试。",
  "update.manualDownloadExplanation": "此通道需要手动下载安装程序。请打开所选发布页面，选择 Windows 安装程序，保存工作并关闭 Lithe 后再安装。Lithe 与 Lithe-Dev 分别安装。Lithe-Dev 首次启动且没有自己的用户数据时，会自动复制正式版的设置和工作区，之后两版分别保存设置和缓存。部分账号可能需要重新登录。显示版本号可能更低或不变，无法据此判断滚动构建是否更新。Lithe 尚未检查当前构建是否为最新。",
  "update.manualDownloadStatus": "请从所选通道的发布页面下载并安装，尚未检查构建是否为最新。",
  "update.manualDownloadTitle": "从发布页面下载安装",
  "update.acknowledgeDownload": "我已了解，打开发布下载页面",
  "update.viewDownloads": "查看发布下载",
};
