export const runningServicesEnglish = {
  "runningServices.title": "Services Still Running",
  "runningServices.message":
    "{count} Run services started from this window are still running. Closing the window stops them and their child processes.",
  "runningServices.quitMessage":
    "{count} Run services started from this window are still running. Quitting Lithe stops them and their child processes.",
  "runningServices.updateMessage":
    "{count} Run services are still running. Installing the update restarts Lithe, which stops them and their child processes.",
  "runningServices.untitled": "Unnamed service",
  "runningServices.stopAndClose": "Stop and Close",
  "runningServices.stopAndQuit": "Stop and Quit",
  "runningServices.stopAndUpdate": "Stop and Update",
  "runningServices.stopping": "Stopping…",
  "runningServices.stopFailed": "Some services could not be stopped and are still running: {error}",
  "runningServices.settingsGroup": "When Quitting",
  "runningServices.setting": "Running Run services",
  "runningServices.settingDescription":
    "Applies when closing a window, quitting Lithe or installing an update. Services started from Lithe always stop with it, together with their child processes.",
  "runningServices.ask": "Ask before stopping",
  "runningServices.terminate": "Stop without asking",
};

export const runningServicesChinese: Record<keyof typeof runningServicesEnglish, string> = {
  "runningServices.title": "仍有服务在运行",
  "runningServices.message":
    "此窗口启动的 {count} 个运行服务仍在运行。关闭窗口会停止这些服务及其子进程。",
  "runningServices.quitMessage":
    "此窗口启动的 {count} 个运行服务仍在运行。退出 Lithe 会停止这些服务及其子进程。",
  "runningServices.updateMessage":
    "{count} 个运行服务仍在运行。安装更新会重启 Lithe，并停止这些服务及其子进程。",
  "runningServices.untitled": "未命名服务",
  "runningServices.stopAndClose": "停止并关闭",
  "runningServices.stopAndQuit": "停止并退出",
  "runningServices.stopAndUpdate": "停止并更新",
  "runningServices.stopping": "正在停止…",
  "runningServices.stopFailed": "部分服务未能停止，仍在运行：{error}",
  "runningServices.settingsGroup": "退出时",
  "runningServices.setting": "运行中的运行服务",
  "runningServices.settingDescription":
    "关闭窗口、退出 Lithe 或安装更新时生效。从 Lithe 启动的服务总会随之停止，包括它们的子进程。",
  "runningServices.ask": "停止前询问",
  "runningServices.terminate": "直接停止",
};
