// Transport types and the JS -> Rust envelope from gpui/editor/PROTOCOL.md.
//
// Every message is wrapped in { requestId, payload }. An empty requestId means
// "no reply expected"; a non-empty one is resolved by the host through
// window.lithe.resolve(requestId, value). Replies are always asynchronous: the
// editor must never assume that GPUI processed a message before the next one.

export type LitheMessageType =
  | "ready"
  | "edit"
  | "dirty"
  | "save"
  | "saveAs"
  | "focus"
  | "cursor"
  | "failure"
  | "diagnostics"
  | "lsp";

export interface LitheEnvelope {
  requestId: string;
  payload: { type: LitheMessageType } & Record<string, unknown>;
}

export interface LitheOpenPayload {
  id: string;
  filename: string;
  language?: string;
  text: string;
  readonly?: boolean;
}

export interface LitheConfigurePayload {
  dark?: boolean;
  background?: string;
  foreground?: string;
  fontFamily?: string;
  fontSize?: number;
  wrap?: boolean;
  minimap?: boolean;
  lineNumbers?: boolean;
  scrollBeyondLastLine?: boolean;
}

export interface LitheApi {
  open(payload: LitheOpenPayload): void;
  close(id: string): void;
  clear(): void;
  configure(payload: LitheConfigurePayload): void;
  /** Host-driven menu command: save the active model, like Ctrl/Cmd+S. */
  save(): void;
  /**
   * 另存为：把活动模型写到宿主选定的绝对路径。
   *
   * 路径来自 Rust 的原生保存对话框；成功与否由 `saveAs` 请求的回复决定。
   */
  saveAs(path: string): void;
  /**
   * Host-driven menu command: run a Monaco action. Rust forwards only action
   * ids from its whitelist, never raw menu text.
   */
  command(name: string): void;
  /** Host-driven menu command: return keyboard focus to the editor. */
  focus(): void;
  /**
   * 切换只读模式。
   *
   * Split Editor 的副窗格用它避免同一文件出现两个可写缓冲；只影响 Monaco 的
   * 编辑能力，保存与命令等入口保持不变。
   */
  setReadonly(readonly: boolean): void;
  /**
   * 定位到指定行（1-based）并聚焦编辑器。
   *
   * 搜索结果、诊断等宿主入口用它跳转；行号会夹到当前模型的范围内。
   */
  revealLine(line: number): void;
  resolve(requestId: string, value: unknown): void;
  setSaved(id: string, saved: boolean): void;
}

export interface LitheIpc {
  postMessage(message: string): void;
}

export interface LitheBridge {
  /** Send a fire-and-forget message (ready, dirty, focus, cursor, failure). */
  notify(type: LitheMessageType, fields?: Record<string, unknown>): void;
  /** Send a message whose payload Rust resolves through window.lithe.resolve. */
  request(type: LitheMessageType, fields?: Record<string, unknown>): Promise<unknown>;
  /** Fulfil a pending request. Unknown ids (for example after a reload) are ignored. */
  resolve(requestId: string, value: unknown): void;
}

/** PROTOCOL.md: the editor rejects a reply-less request after 10 seconds. */
const REQUEST_TIMEOUT_MS = 10_000;

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  try {
    const json = JSON.stringify(error);
    return json === undefined ? String(error) : json;
  } catch {
    return String(error);
  }
}

export function createBridge(): LitheBridge {
  let nextRequestId = 1;
  const pending = new Map<string, {
    resolve(value: unknown): void;
    timer: number;
  }>();

  function post(requestId: string, payload: LitheEnvelope["payload"]): void {
    const ipc = (window as Window & { ipc?: LitheIpc }).ipc;
    if (!ipc || typeof ipc.postMessage !== "function") {
      throw new Error("Lithe editor IPC is unavailable");
    }
    ipc.postMessage(JSON.stringify({ requestId, payload }));
  }

  return {
    notify(type, fields = {}) {
      try {
        post("", { type, ...fields });
      } catch (error) {
        // The host may still be attaching its IPC handler. Never let a status
        // update tear down the editor.
        console.error(`lithe: failed to send '${type}'`, error);
      }
    },

    request(type, fields = {}) {
      return new Promise<unknown>((resolve, reject) => {
        const requestId = String(nextRequestId++);
        const timer = window.setTimeout(() => {
          pending.delete(requestId);
          reject(new Error(`Lithe editor request '${type}' timed out`));
        }, REQUEST_TIMEOUT_MS);
        pending.set(requestId, { resolve, timer });
        try {
          post(requestId, { type, ...fields });
        } catch (error) {
          window.clearTimeout(timer);
          pending.delete(requestId);
          reject(error);
        }
      });
    },

    resolve(requestId, value) {
      if (typeof requestId !== "string") return;
      const entry = pending.get(requestId);
      if (!entry) return;
      pending.delete(requestId);
      window.clearTimeout(entry.timer);
      entry.resolve(value);
    },
  };
}
