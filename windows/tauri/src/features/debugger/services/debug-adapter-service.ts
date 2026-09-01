import { invoke } from "@/platform/tauri-core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  DebugAdapterLaunch,
  DebugAdapterSessionInfo,
  DebugBreakpoint,
  DebugCommandResult,
  DebugLaunchConfig,
  DebugProcessOutput,
  DebugProtocolMessage,
  DebugSessionEnded,
} from "@/features/debugger/types/debugger.types";

interface DebuggerEventHandlers {
  onMessage?: (payload: DebugProtocolMessage) => void;
  onOutput?: (payload: DebugProcessOutput) => void;
  onSessionEnded?: (payload: DebugSessionEnded) => void;
}

async function startDebugAdapterSession(
  launch: DebugAdapterLaunch,
): Promise<DebugAdapterSessionInfo> {
  return await invoke<DebugAdapterSessionInfo>("debug_start_session", { launch });
}

export async function sendDebugAdapterRequest(
  sessionId: string,
  command: string,
  argumentsPayload?: unknown,
): Promise<DebugCommandResult> {
  return await invoke<DebugCommandResult>("debug_send_request", {
    sessionId,
    command,
    arguments: argumentsPayload,
  });
}

export async function stopDebugAdapterSession(sessionId: string): Promise<void> {
  await invoke("debug_stop_session", { sessionId });
}

export async function startDebugLaunchSession(
  config: DebugLaunchConfig,
  breakpoints: DebugBreakpoint[],
): Promise<DebugAdapterSessionInfo> {
  if (!config.adapterCommand) {
    throw new Error("Debug configuration is missing adapterCommand");
  }

  const session = await startDebugAdapterSession({
    command: config.adapterCommand,
    args: config.adapterArgs ?? [],
    cwd: config.cwd,
    env: config.env,
  });

  // Rust Core owns DAP initialization and the configurationDone handshake;
  // the host facade only queues the launch and breakpoint sets.
  await sendDebugAdapterRequest(session.id, config.request ?? "launch", {
    name: config.name,
    type: config.type ?? config.runtime,
    request: config.request ?? "launch",
    program: config.program,
    cwd: config.cwd,
    args: config.args ?? [],
    env: config.env ?? {},
  });

  await syncDebugBreakpoints(session.id, breakpoints);

  return session;
}

export async function syncDebugBreakpoints(
  sessionId: string,
  breakpoints: DebugBreakpoint[],
  knownFilePaths: string[] = [],
) {
  const breakpointsByFile = new Map<string, DebugBreakpoint[]>();
  const filePaths = new Set(knownFilePaths);

  for (const breakpoint of breakpoints) {
    filePaths.add(breakpoint.filePath);
    if (!breakpoint.enabled) continue;
    const fileBreakpoints = breakpointsByFile.get(breakpoint.filePath) ?? [];
    fileBreakpoints.push(breakpoint);
    breakpointsByFile.set(breakpoint.filePath, fileBreakpoints);
  }

  await Promise.all(
    Array.from(filePaths, (filePath) => {
      const fileBreakpoints = breakpointsByFile.get(filePath) ?? [];
      return sendDebugAdapterRequest(sessionId, "setBreakpoints", {
        source: { path: filePath },
        breakpoints: fileBreakpoints.map((breakpoint) => ({
          line: breakpoint.line + 1,
        })),
      });
    }),
  );
}

export async function subscribeDebuggerEvents(
  handlers: DebuggerEventHandlers,
): Promise<UnlistenFn> {
  const unlistenFns = await Promise.all([
    listen<DebugProtocolMessage>("debugger_message", (event) => {
      handlers.onMessage?.(event.payload);
    }),
    listen<DebugProcessOutput>("debugger_output", (event) => {
      handlers.onOutput?.(event.payload);
    }),
    listen<DebugSessionEnded>("debugger_session_ended", (event) => {
      handlers.onSessionEnded?.(event.payload);
    }),
  ]);

  return () => {
    for (const unlisten of unlistenFns) {
      unlisten();
    }
  };
}
