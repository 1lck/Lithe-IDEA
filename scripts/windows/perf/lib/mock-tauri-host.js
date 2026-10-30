// In-page stand-in for the Tauri host, injected before the Windows frontend
// loads so the production bundle runs in plain Chromium. It answers the host
// commands that opening a project and editing files need from an in-memory
// file system, and returns null for everything else. Unanswered commands are
// counted so a scenario can report what it did not exercise.
//
// Self-contained: Playwright injects the source text, so no imports.
(() => {
  const fixture = window.__LITHE_PERF_FIXTURE__ ?? { root: "C:/perf/empty", files: {} };
  const root = fixture.root;

  const files = new Map();
  const directories = new Set([root]);
  const addParents = (path) => {
    for (let index = path.lastIndexOf("/"); index > root.length; index = path.lastIndexOf("/", index - 1)) {
      directories.add(path.slice(0, index));
    }
  };
  for (const [relative, text] of Object.entries(fixture.files)) {
    const path = `${root}/${relative}`;
    files.set(path, text);
    addParents(path);
  }

  const normalize = (path) => String(path ?? "").replaceAll("\\", "/").replace(/\/+$/, "");
  const nameOf = (path) => path.slice(path.lastIndexOf("/") + 1);
  const childrenOf = (directory) => {
    const prefix = `${directory}/`;
    const names = new Map();
    for (const path of [...directories, ...files.keys()]) {
      if (!path.startsWith(prefix)) continue;
      const rest = path.slice(prefix.length);
      if (!rest || rest.includes("/")) continue;
      names.set(rest, directories.has(path));
    }
    return [...names].sort(([a], [b]) => a.localeCompare(b));
  };

  let revision = 0;
  const identityOf = (path) => `${path}#${files.get(path)?.length ?? 0}#${revision}`;
  const documentOf = (path) => ({ content: files.get(path), encoding: "UTF-8", identity: identityOf(path) });

  // Tauri callbacks: `transformCallback` ids double as event listener ids.
  let nextId = 1;
  const callbacks = new Map();
  const listeners = new Map();
  const stores = new Map();
  const commandCounts = new Map();
  const unanswered = new Map();
  const unansweredSamples = new Map();
  const count = (map, command) => map.set(command, (map.get(command) ?? 0) + 1);

  // Every invoke serializes its arguments across the WebView boundary, so text
  // payloads are what a keystroke or save costs the real host in bytes.
  let payloadBytes = 0;
  const payloadByCommand = new Map();
  const measuredPayload = (args) => {
    if (!args) return 0;
    let total = 0;
    for (const value of Object.values(args)) {
      if (typeof value === "string") total += value.length;
      else if (value && typeof value === "object") total += JSON.stringify(value)?.length ?? 0;
    }
    return total;
  };

  const emit = (event, payload) => {
    for (const [id, handler] of listeners.get(event) ?? []) {
      callbacks.get(handler)?.({ event, id, payload });
    }
  };

  const store = (command, args) => {
    const operation = command.slice("plugin:store|".length);
    if (operation === "load") {
      const rid = nextId++;
      stores.set(rid, new Map());
      return rid;
    }
    if (operation === "get_store") return null;
    const entries = stores.get(args?.rid) ?? new Map();
    switch (operation) {
      case "get":
        return [entries.get(args.key) ?? null, entries.has(args.key)];
      case "set":
        entries.set(args.key, args.value);
        return null;
      case "has":
        return entries.has(args.key);
      case "delete":
        return entries.delete(args.key);
      case "entries":
        return [...entries.entries()];
      case "keys":
        return [...entries.keys()];
      case "values":
        return [...entries.values()];
      case "length":
        return entries.size;
      case "clear":
      case "reset":
        entries.clear();
        return null;
      default:
        return null;
    }
  };

  // Mirrors `decide_document_lifecycle` in rust/lithe-core for the transitions
  // autosave drives. Conflict flows have no scenario and keep their state.
  const decideLifecycle = (state, event) => {
    const { revision, savedRevision } = state;
    if (event.type === "saveStarted" && state.status === "dirty") {
      return {
        state: { status: "saving", revision, savedRevision, saveRevision: revision, operationId: event.operationId },
        action: "writeToDisk",
      };
    }
    if (event.type === "saveSucceeded" && state.status === "saving" && state.operationId === event.operationId) {
      return {
        state:
          revision === state.saveRevision
            ? { status: "clean", revision }
            : { status: "dirty", revision, savedRevision: state.saveRevision },
        action: "none",
      };
    }
    if (event.type === "saveFailed" && state.status === "saving" && state.operationId === event.operationId) {
      return { state: { status: "dirty", revision, savedRevision }, action: "reportSaveFailure" };
    }
    if (event.type === "saveSucceeded" || event.type === "saveFailed") return { state, action: "ignoreStaleResult" };
    return { state, action: "none" };
  };

  // A language server that is ready and answers every request with nothing: the
  // frontend's own cost is what the scenarios measure, not a server's. Events
  // reach the frontend through the `lsp.waitEvents` long poll, as from Core.
  let nextLspOperation = 1;
  let documentVersion = 0;
  let pendingLspEvents = [];
  let wakeEventPump = null;
  const queueLspEvent = (event) => {
    pendingLspEvents.push(event);
    wakeEventPump?.();
  };
  const waitLspEvents = (timeoutMilliseconds) =>
    new Promise((resolve) => {
      const finish = () => {
        clearTimeout(timer);
        wakeEventPump = null;
        const events = pendingLspEvents;
        pendingLspEvents = [];
        resolve({ events });
      };
      const timer = setTimeout(finish, timeoutMilliseconds);
      if (pendingLspEvents.length > 0) finish();
      else wakeEventPump = finish;
    });
  const startLspRequest = () => {
    const operationId = `perf-lsp-${nextLspOperation++}`;
    setTimeout(() => queueLspEvent({ type: "requestCompleted", operationId, result: null }), 0);
    return { operationId };
  };

  // Shared Core operations arrive as a JSON request string and answer with a
  // JSON envelope. Operations without a handler fail the way an unavailable
  // backend capability does, so callers take their normal error path.
  const coreHandlers = {
    "lsp.startServer": () => {
      setTimeout(() => queueLspEvent({ type: "stateChanged", state: "ready" }), 0);
      return { sessionId: "perf-language-session", state: "initializing" };
    },
    "lsp.waitEvents": (payload) => waitLspEvents(payload.timeoutMilliseconds ?? 30_000),
    "lsp.syncDocument": () => ({ documentVersion: ++documentVersion, changed: true }),
    "lsp.saveDocument": () => ({}),
    "lsp.closeDocument": () => ({}),
    "lsp.workspaceFilesChanged": () => ({}),
    "lsp.updateWorkspaceConfiguration": () => ({}),
    "lsp.updateMavenConfiguration": () => ({}),
    "lsp.request": startLspRequest,
    "java.workspacePolicy": () => ({ shouldStart: false, changes: [] }),
    "maven.scan": () => null,
    "spring.index": () => ({ properties: [], values: [], propertyReferences: [] }),
    "mybatis.index": () => ({ statements: [] }),
    "history.record": () => ({}),
    "document.lifecycle": (payload) => decideLifecycle(payload.state, payload.event),
    "workspace.snapshot": () => ({
      root: { name: nameOf(root), path: "", isDirectory: true, children: [] },
      files: [...files.keys()].map((path) => path.slice(root.length + 1)),
    }),
    // Same control-character policy as the Core contract for `document.classifyText`.
    "document.classifyText": (payload) => ({
      isPlainText: !/[\u0000-\u0008\u000E-\u001F\u007F]/.test(String(payload.text ?? "")),
    }),
  };
  const core = async (requestText) => {
    const request = JSON.parse(requestText);
    const handler = coreHandlers[request.command];
    const name = `core:${request.command}`;
    count(commandCounts, name);
    if (!handler) {
      count(unanswered, name);
      if (!unansweredSamples.has(name)) unansweredSamples.set(name, JSON.stringify(request.payload ?? null).slice(0, 300));
      return JSON.stringify({
        id: request.id ?? null,
        ok: false,
        error: { code: "unavailable", message: `${request.command} is not available in the performance host` },
      });
    }
    return JSON.stringify({ id: request.id ?? null, ok: true, data: await handler(request.payload ?? {}) });
  };

  const handlers = {
    "plugin:event|listen": (args) => {
      const id = nextId++;
      if (!listeners.has(args.event)) listeners.set(args.event, new Map());
      listeners.get(args.event).set(id, args.handler);
      return id;
    },
    "plugin:event|unlisten": (args) => {
      listeners.get(args.event)?.delete(args.eventId);
      return null;
    },
    "plugin:event|emit": (args) => {
      emit(args.event, args.payload);
      return null;
    },
    "plugin:event|emit_to": (args) => {
      emit(args.event, args.payload);
      return null;
    },
    "plugin:app|version": () => "0.0.0-perf",
    "plugin:app|name": () => "Lithe",
    "plugin:os|platform": () => "windows",
    "plugin:os|os_type": () => "windows",
    "plugin:os|family": () => "windows",
    "plugin:os|arch": () => "x86_64",
    "plugin:os|version": () => "10.0.26100",
    "plugin:os|locale": () => "en-US",
    "plugin:os|hostname": () => "perf",
    "plugin:window|get_all_windows": () => ["main"],
    "plugin:window|scale_factor": () => 1,
    "plugin:window|is_maximized": () => false,
    "plugin:window|is_fullscreen": () => false,
    "plugin:window|is_focused": () => true,
    "plugin:dialog|open": () => root,
    claim_project_window: (args) => ({ label: "main", workspaceId: args.workspaceId }),
    get_system_fonts: () => [],
    take_pending_cli_open_requests: () => [],
    list_installed_extensions_new: () => [],
    list_shells: () => [],
    lsp_resolve_java_launch: () => ({
      providerId: "java",
      languageId: "java",
      executablePath: "java",
      arguments: [],
      cacheDirectory: `${root}/.perf-cache`,
      environment: {},
      javaRuntimes: [],
    }),
    declarative_plugins_state: () => [],
    declarative_plugins_rescan: () => [],
    declarative_plugins_web_windows: () => [],
    "plugin:fs|read_dir": (args) =>
      childrenOf(normalize(args.path)).map(([name, isDirectory]) => ({
        name,
        isDirectory,
        isFile: !isDirectory,
        isSymlink: false,
      })),
    "plugin:fs|exists": (args) => {
      const path = normalize(args.path);
      return files.has(path) || directories.has(path);
    },
    "plugin:fs|stat": (args) => {
      const path = normalize(args.path);
      const isDirectory = directories.has(path);
      if (!isDirectory && !files.has(path)) throw `No such file or directory: ${path}`;
      return {
        isFile: !isDirectory,
        isDirectory,
        isSymlink: false,
        size: files.get(path)?.length ?? 0,
        mtime: 0,
        atime: 0,
        birthtime: 0,
        readonly: false,
      };
    },
    "plugin:fs|read_file": (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) throw `No such file: ${path}`;
      return [...new TextEncoder().encode(files.get(path))];
    },
    "plugin:fs|read_text_file": (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) throw `No such file: ${path}`;
      return [...new TextEncoder().encode(files.get(path))];
    },
    get_symlink_info: (args) => ({ is_symlink: false, is_dir: directories.has(normalize(args.path)) }),
    read_document_file_details: (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) throw `No such file: ${path}`;
      return documentOf(path);
    },
    read_document_file: (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) throw `No such file: ${path}`;
      return files.get(path);
    },
    read_document_file_change: (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) return { status: "missing" };
      return args.identity === identityOf(path) ? { status: "unchanged" } : { status: "changed", document: documentOf(path) };
    },
    read_local_file: (args) => files.get(normalize(args.path)) ?? null,
    read_local_file_bounded: (args) => {
      const path = normalize(args.path);
      if (!files.has(path)) throw `No such file: ${path}`;
      const bytes = new TextEncoder().encode(files.get(path));
      return { bytes: [...bytes.subarray(0, args.maxBytes)], truncated: bytes.length > args.maxBytes };
    },
    save_document_file: (args) => {
      const path = normalize(args.path);
      files.set(path, args.content);
      revision += 1;
      return { status: "saved", identity: identityOf(path) };
    },
  };

  window.__TAURI_INTERNALS__ = {
    metadata: {
      currentWindow: { label: "main" },
      currentWebview: { windowLabel: "main", label: "main" },
    },
    transformCallback(callback, once) {
      const id = nextId++;
      callbacks.set(id, (data) => {
        if (once) callbacks.delete(id);
        callback?.(data);
      });
      return id;
    },
    unregisterCallback(id) {
      callbacks.delete(id);
    },
    convertFileSrc(path, protocol = "asset") {
      return `${protocol}://localhost/${encodeURIComponent(path)}`;
    },
    async invoke(command, args) {
      count(commandCounts, command);
      const measured = measuredPayload(args);
      payloadBytes += measured;
      const label = command === "core_execute" ? args?.request?.match(/"command":"([^"]+)"/)?.[1] ?? command
        : command === "platform_invoke" ? args?.command : command;
      payloadByCommand.set(label, (payloadByCommand.get(label) ?? 0) + measured);
      if (command.startsWith("plugin:store|")) return store(command, args);
      if (command === "core_execute") return core(args.request);
      if (command === "platform_invoke") {
        const name = `platform_invoke:${args?.command}`;
        count(commandCounts, name);
        // The dispatcher answers dotted Core operations with their data.
        const coreHandler = coreHandlers[args?.command];
        if (coreHandler) return coreHandler(args?.args ?? {});
        if (args?.command === "git_discover_repo" || args?.command === "git_discover_workspace_repos") {
          return args.command === "git_discover_repo" ? null : { repositories: [] };
        }
        count(unanswered, name);
        if (!unansweredSamples.has(name)) unansweredSamples.set(name, JSON.stringify(args?.args ?? null).slice(0, 300));
        throw `${args?.command} is not available in the performance host`;
      }
      const handler = handlers[command];
      if (!handler) {
        count(unanswered, command);
        if (!unansweredSamples.has(command)) unansweredSamples.set(command, JSON.stringify(args ?? null).slice(0, 300));
        return null;
      }
      return handler(args ?? {});
    },
  };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener() {} };
  // The OS plugin answers synchronously from this object; the keymap and path
  // handling read it at module load.
  window.__TAURI_OS_PLUGIN_INTERNALS__ = {
    platform: "windows",
    family: "windows",
    os_type: "windows",
    arch: "x86_64",
    exe_extension: "exe",
    eol: "\r\n",
    version: "10.0.26100",
  };

  window.__LITHE_PERF_HOST__ = {
    root,
    emit,
    commandCounts: () => Object.fromEntries(commandCounts),
    payloadBytes: () => payloadBytes,
    payloadByCommand: () => Object.fromEntries(payloadByCommand),
    unanswered: () => Object.fromEntries(unanswered),
    unansweredSamples: () => Object.fromEntries(unansweredSamples),
    resetCounts() {
      commandCounts.clear();
      unanswered.clear();
      payloadBytes = 0;
      payloadByCommand.clear();
    },
  };
})();
