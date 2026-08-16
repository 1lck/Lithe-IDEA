// Mock implementation for Tauri APIs
// This allows the UI to compile and run without the Rust backend

// @tauri-apps/api/core
export const invoke = async (cmd: string, args?: any): Promise<any> => {
  console.warn(`[Mock] Tauri invoke called: ${cmd}`, args);

  if (
    [
      "get_system_fonts",
      "get_monospace_fonts",
      "take_pending_cli_open_requests",
      "load_all_chats",
      "list_shells",
      "list_installed_extensions_new",
      "get_available_agents",
      "wsl_list_distributions",
    ].includes(cmd)
  ) {
    return [];
  }

  if (cmd === "get_bundled_extensions_path") return "/mock/extensions";
  if (cmd === "uses_native_window_chrome") return false;
  if (cmd === "get_system_theme") return "dark";

  return null;
};

export const convertFileSrc = (path: string): string => path;

export class Channel<T> {
  constructor(public onmessage: (event: T) => void) {}
}

// @tauri-apps/api/app
export const getVersion = async (): Promise<string> => {
  return "0.11.0-web";
};

// @tauri-apps/plugin-opener
export const openUrl = async (url: string): Promise<void> => {
  console.log(`[Mock] Opening URL: ${url}`);
  window.open(url, "_blank");
};

// @tauri-apps/plugin-dialog
export const save = async (options?: any): Promise<string | null> => {
  console.warn("[Mock] Save dialog called", options);
  return null;
};

export const open = async (
  target?: string | Record<string, unknown>,
): Promise<string | string[] | null | void> => {
  if (typeof target === "string") {
    console.warn("[Mock] Shell open:", target);
    window.open(target, "_blank");
    return;
  }

  console.warn("[Mock] Open dialog called", target);
  return null;
};

export const message = async (message: string, options?: any): Promise<void> => {
  console.warn("[Mock] Message dialog:", message, options);
  alert(message);
};

export const ask = async (message: string, options?: any): Promise<boolean> => {
  console.warn("[Mock] Ask dialog:", message, options);
  return confirm(message);
};

export const confirm = async (message: string, options?: any): Promise<boolean> => {
  console.warn("[Mock] Confirm dialog:", message, options);
  return window.confirm(message);
};

// @tauri-apps/plugin-fs
export const writeTextFile = async (path: string, contents: string): Promise<void> => {
  console.warn(`[Mock] Write file: ${path}`, contents);
};

export const readTextFile = async (path: string): Promise<string> => {
  console.warn(`[Mock] Read file: ${path}`);
  return "";
};

export const readDir = async (path: string): Promise<any[]> => {
  console.warn(`[Mock] Read directory: ${path}`);
  return [];
};

export const readFile = async (path: string): Promise<Uint8Array> => {
  console.warn(`[Mock] Read file bytes: ${path}`);
  return new Uint8Array();
};

export const writeFile = async (path: string, contents: Uint8Array): Promise<void> => {
  console.warn(`[Mock] Write file bytes: ${path}`, contents.byteLength);
};

export const copyFile = async (source: string, destination: string): Promise<void> => {
  console.warn(`[Mock] Copy file: ${source} -> ${destination}`);
};

export const createDir = async (path: string): Promise<void> => {
  console.warn(`[Mock] Create directory: ${path}`);
};

export const mkdir = createDir;

export const removeFile = async (path: string): Promise<void> => {
  console.warn(`[Mock] Remove file: ${path}`);
};

export const removeDir = async (path: string): Promise<void> => {
  console.warn(`[Mock] Remove directory: ${path}`);
};

export const remove = async (path: string): Promise<void> => {
  console.warn(`[Mock] Remove path: ${path}`);
};

export const BaseDirectory = {
  AppData: 22,
} as const;

export const exists = async (path: string): Promise<boolean> => {
  console.warn(`[Mock] Check exists: ${path}`);
  return false;
};

// @tauri-apps/plugin-process
export const relaunch = async (): Promise<void> => {
  console.warn("[Mock] Relaunch called");
  window.location.reload();
};

export const exit = async (code?: number): Promise<void> => {
  console.warn("[Mock] Exit called with code:", code);
  window.close();
};

// @tauri-apps/plugin-updater
export const check = async (): Promise<any> => {
  console.warn("[Mock] Update check called");
  return null;
};

export class Update {
  async download(): Promise<void> {
    console.warn("[Mock] Download update called");
  }
  async install(): Promise<void> {
    console.warn("[Mock] Install update called");
  }
}

// @tauri-apps/api/window
export const getCurrentWindow = () => ({
  startDragging: async () => {
    console.warn("[Mock] Window dragging called");
  },
  close: async () => window.close(),
  minimize: async () => console.warn("[Mock] Minimize called"),
  maximize: async () => console.warn("[Mock] Maximize called"),
  toggleMaximize: async () => console.warn("[Mock] Toggle maximize called"),
  isMaximized: async () => false,
  hide: async () => console.warn("[Mock] Hide called"),
  show: async () => console.warn("[Mock] Show called"),
  setTitle: async (title: string) => {
    document.title = title;
  },
  setFullscreen: async (fullscreen: boolean) => {
    console.warn("[Mock] Set fullscreen:", fullscreen);
  },
  isFullscreen: async () => false,
  setDecorations: async (decorations: boolean) => {
    console.warn("[Mock] Set decorations:", decorations);
  },
  setResizable: async (resizable: boolean) => {
    console.warn("[Mock] Set resizable:", resizable);
  },
  setAlwaysOnTop: async (alwaysOnTop: boolean) => {
    console.warn("[Mock] Set always on top:", alwaysOnTop);
  },
  center: async () => console.warn("[Mock] Center window called"),
  requestUserAttention: async (type?: any) => {
    console.warn("[Mock] Request user attention:", type);
  },
  setFocus: async () => {
    window.focus();
  },
  onCloseRequested: (handler: any) => {
    console.warn("[Mock] onCloseRequested registered");
    return () => {};
  },
  onFocusChanged: (handler: any) => {
    console.warn("[Mock] onFocusChanged registered");
    return () => {};
  },
  onResized: (handler: any) => {
    console.warn("[Mock] onResized registered");
    return () => {};
  },
  onDragDropEvent: async (handler: any) => {
    console.warn("[Mock] Window drag-and-drop registered");
    return () => {};
  },
});

// @tauri-apps/api/webviewWindow
export const getCurrentWebviewWindow = () => ({
  label: "main",
  startDragging: async () => {
    console.warn("[Mock] Window dragging called");
  },
  close: async () => window.close(),
  minimize: async () => console.warn("[Mock] Minimize called"),
  maximize: async () => console.warn("[Mock] Maximize called"),
  toggleMaximize: async () => console.warn("[Mock] Toggle maximize called"),
  isMaximized: async () => false,
  hide: async () => console.warn("[Mock] Hide called"),
  show: async () => console.warn("[Mock] Show called"),
  setTitle: async (title: string) => {
    document.title = title;
  },
  setFullscreen: async (fullscreen: boolean) => {
    console.warn("[Mock] Set fullscreen:", fullscreen);
  },
  isFullscreen: async () => false,
  setDecorations: async (decorations: boolean) => {
    console.warn("[Mock] Set decorations:", decorations);
  },
  setResizable: async (resizable: boolean) => {
    console.warn("[Mock] Set resizable:", resizable);
  },
  setAlwaysOnTop: async (alwaysOnTop: boolean) => {
    console.warn("[Mock] Set always on top:", alwaysOnTop);
  },
  center: async () => console.warn("[Mock] Center window called"),
  requestUserAttention: async (type?: any) => {
    console.warn("[Mock] Request user attention:", type);
  },
  setFocus: async () => {
    window.focus();
  },
  onCloseRequested: (handler: any) => {
    console.warn("[Mock] onCloseRequested registered");
    return () => {};
  },
  onFocusChanged: (handler: any) => {
    console.warn("[Mock] onFocusChanged registered");
    return () => {};
  },
  onResized: (handler: any) => {
    console.warn("[Mock] onResized registered");
    return () => {};
  },
  listen: async (event: string, handler: any) => {
    console.warn("[Mock] Window listen:", event);
    return () => {};
  },
  once: async (event: string, handler: any) => {
    console.warn("[Mock] Window once:", event);
    return () => {};
  },
  emit: async (event: string, payload?: any) => {
    console.warn("[Mock] Window emit:", event, payload);
  },
  onDragDropEvent: async (handler: any) => {
    console.warn("[Mock] Window drag-and-drop registered");
    return () => {};
  },
});

export const getAllWebviewWindows = async () => [getCurrentWebviewWindow()];

// @tauri-apps/plugin-store
export const load = async (path: string, options?: any) => ({
  get: async (key: string) => null,
  set: async (key: string, value: any) => {},
  save: async () => {},
  entries: async () => [],
  keys: async () => [],
  values: async () => [],
  has: async (key: string) => false,
  delete: async (key: string) => false,
  clear: async () => {},
  length: async () => 0,
  reload: async () => {},
  onKeyChange: (key: string, handler: any) => () => {},
  onChange: (handler: any) => () => {},
});

export class Store {
  constructor(path: string) {
    console.warn("[Mock] Store created:", path);
  }

  async get(key: string) {
    return null;
  }

  async set(key: string, value: any) {}

  async save() {}

  async entries() {
    return [];
  }

  async keys() {
    return [];
  }

  async values() {
    return [];
  }

  async has(key: string) {
    return false;
  }

  async delete(key: string) {
    return false;
  }

  async clear() {}

  async length() {
    return 0;
  }

  async reload() {}

  onKeyChange(key: string, handler: any) {
    return () => {};
  }

  onChange(handler: any) {
    return () => {};
  }
}

// @tauri-apps/plugin-os
export const platform = () => "windows";
export const version = async () => "0.0.0";
export const type = async () => "Web";
export const arch = () => "x86_64";
export const locale = async () => "en-US";
export const hostname = async () => "localhost";
export const tempdir = async () => "/tmp";

// @tauri-apps/api/path
export const basename = async (path: string, ext?: string): Promise<string> => {
  const parts = path.split(/[/\\]/);
  let name = parts[parts.length - 1] || "";
  if (ext && name.endsWith(ext)) {
    name = name.slice(0, -ext.length);
  }
  return name;
};

export const dirname = async (path: string): Promise<string> => {
  const parts = path.split(/[/\\]/);
  parts.pop();
  return parts.join("/") || "/";
};

export const extname = async (path: string): Promise<string> => {
  const name = path.split(/[/\\]/).pop() || "";
  const lastDot = name.lastIndexOf(".");
  return lastDot > 0 ? name.slice(lastDot) : "";
};

export const join = async (...paths: string[]): Promise<string> => {
  return paths.join("/").replace(/\/+/g, "/");
};

export const homeDir = async (): Promise<string> => {
  return "/home/user";
};

export const appDataDir = async (): Promise<string> => {
  return "/home/user/.local/share";
};

export const documentDir = async (): Promise<string> => {
  return "/home/user/Documents";
};

export const downloadDir = async (): Promise<string> => {
  return "/home/user/Downloads";
};

// @tauri-apps/api/event
export const listen = async (event: string, handler: any) => {
  console.warn("[Mock] Event listen:", event);
  return () => {};
};

export const once = async (event: string, handler: any) => {
  console.warn("[Mock] Event once:", event);
  return () => {};
};

export const emit = async (event: string, payload?: any) => {
  console.warn("[Mock] Event emit:", event, payload);
};

// @tauri-apps/api/webview
export const getCurrentWebview = () => ({
  listen: async (event: string, handler: any) => {
    console.warn("[Mock] Webview listen:", event);
    return () => {};
  },
  once: async (event: string, handler: any) => {
    console.warn("[Mock] Webview once:", event);
    return () => {};
  },
  emit: async (event: string, payload?: any) => {
    console.warn("[Mock] Webview emit:", event, payload);
  },
  onDragDropEvent: async (handler: any) => {
    console.warn("[Mock] Webview drag-and-drop registered");
    return () => {};
  },
});

// @tauri-apps/plugin-http
export const fetch = async (url: string, options?: any): Promise<any> => {
  console.warn("[Mock] HTTP fetch:", url, options);
  return window.fetch(url, options);
};

export class Client {
  async request(options: any) {
    console.warn("[Mock] HTTP Client request:", options);
    return window.fetch(options.url, options);
  }
}

// @tauri-apps/plugin-deep-link
export const onOpenUrl = async (handler: any) => {
  console.warn("[Mock] Deep link onOpenUrl registered");
  return () => {};
};

export const revealItemInDir = async (path: string): Promise<void> => {
  console.warn("[Mock] Reveal item in directory:", path);
};

// @tauri-apps/plugin-clipboard-manager
export const readText = async (): Promise<string | null> => {
  console.warn("[Mock] Clipboard readText called");
  try {
    return await navigator.clipboard.readText();
  } catch {
    return null;
  }
};

export const writeText = async (text: string): Promise<void> => {
  console.warn("[Mock] Clipboard writeText called");
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    console.warn("[Mock] Clipboard write failed");
  }
};

export class Command {
  constructor(public program: string, public args: string[] = []) {
    console.warn("[Mock] Command created:", program, args);
  }

  async execute(): Promise<any> {
    console.warn("[Mock] Command execute:", this.program, this.args);
    return { code: 0, stdout: "", stderr: "" };
  }

  async spawn(): Promise<any> {
    console.warn("[Mock] Command spawn:", this.program, this.args);
    return {
      code: 0,
      stdout: "",
      stderr: "",
      kill: async () => {},
    };
  }
}

// Default export for wildcard imports
export default {
  invoke,
  getVersion,
  openUrl,
  save,
  open,
  message,
  ask,
  confirm,
  writeTextFile,
  readTextFile,
  readDir,
  createDir,
  removeFile,
  removeDir,
  exists,
  relaunch,
  exit,
  check,
  Update,
  getCurrentWindow,
  getCurrentWebviewWindow,
  getAllWebviewWindows,
  load,
  Store,
  platform,
  version,
  type,
  arch,
  locale,
  hostname,
  tempdir,
  basename,
  dirname,
  extname,
  join,
  homeDir,
  appDataDir,
  documentDir,
  downloadDir,
  listen,
  once,
  emit,
  getCurrentWebview,
  fetch,
  Client,
  onOpenUrl,
  readText,
  writeText,
  Command,
};
