import type { WindowTitleContext } from "../utils/window-title-context";

interface WindowTitleSyncDependencies {
  readContext: () => WindowTitleContext;
  subscribe: (listener: (force?: boolean) => void) => () => void;
  subscribeFocus: (listener: () => void) => () => void;
  update: (context: WindowTitleContext) => Promise<void>;
  reportError: (error: unknown) => void;
  schedule?: (callback: () => void) => void;
}

interface PendingContext {
  context: WindowTitleContext;
  key: string;
  force: boolean;
}

export function startWindowTitleSync(dependencies: WindowTitleSyncDependencies): () => void {
  const schedule = dependencies.schedule ?? queueMicrotask;
  let disposed = false;
  let scheduled = false;
  let forced = false;
  let inFlight = false;
  let observedKey: string | null = null;
  let successfulKey: string | null = null;
  let pending: PendingContext | null = null;

  const sendLatest = () => {
    if (disposed || inFlight || !pending) return;
    const next = pending;
    pending = null;
    // 聚焦时重新提交，让宿主有机会补偿其他窗口变化引发的标题设置失败。
    if (next.key === successfulKey && !next.force) return;

    inFlight = true;
    void (async () => {
      try {
        await dependencies.update(next.context);
        successfulKey = next.key;
      } catch (error) {
        // 宿主可能已应用标题但应答失败，旧成功缓存不能证明当前原生标题。
        successfulKey = null;
        if (!disposed) dependencies.reportError(error);
      } finally {
        inFlight = false;
        sendLatest();
      }
    })();
  };

  const request = (force = false) => {
    if (disposed) return;
    forced ||= force;
    if (scheduled) return;
    scheduled = true;
    // 等当前同步状态转换完成后再读取，项目和文件始终来自同一工作区。
    schedule(() => {
      scheduled = false;
      if (disposed) return;
      const forceUpdate = forced;
      forced = false;
      try {
        const context = dependencies.readContext();
        const key = JSON.stringify(context);
        if (key === observedKey && !forceUpdate) return;
        observedKey = key;
        pending = { context, key, force: forceUpdate || pending?.force === true };
        sendLatest();
      } catch (error) {
        dependencies.reportError(error);
      }
    });
  };

  const unsubscribe = dependencies.subscribe((force) => request(force));
  let unsubscribeFocus: () => void;
  try {
    unsubscribeFocus = dependencies.subscribeFocus(() => request(true));
  } catch (error) {
    unsubscribe();
    throw error;
  }
  request();

  return () => {
    if (disposed) return;
    disposed = true;
    pending = null;
    unsubscribe();
    unsubscribeFocus();
  };
}
