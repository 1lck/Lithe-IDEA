export const runningServicesEnglish = {
  "runningServices.title": "Services Still Running",
  "runningServices.message":
    "{count} Run services started from this window are still running. Closing the window stops them and their child processes.",
  "runningServices.untitled": "Unnamed service",
  "runningServices.stopAndClose": "Stop and Close",
  "runningServices.stopping": "Stopping…",
};

export const runningServicesChinese: Record<keyof typeof runningServicesEnglish, string> = {
  "runningServices.title": "仍有服务在运行",
  "runningServices.message":
    "此窗口启动的 {count} 个运行服务仍在运行。关闭窗口会停止这些服务及其子进程。",
  "runningServices.untitled": "未命名服务",
  "runningServices.stopAndClose": "停止并关闭",
  "runningServices.stopping": "正在停止…",
};
