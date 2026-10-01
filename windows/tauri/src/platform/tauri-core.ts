import { deliverGitExecution, gitExecutionPreferences, type GitExecutionEvent } from "./git-execution-events";
import {
  Channel,
  convertFileSrc,
  invoke as tauriInvoke,
  type InvokeArgs,
  type InvokeOptions,
} from "@tauri-apps/api/core";
import {
  BACKEND_UNAVAILABLE_TOOLTIP,
  isBackendCapabilityAvailable,
  type BackendCapability,
} from "@/config/backend-capabilities";
import { adaptCoreResult } from "./core-result-adapter";

export { Channel, convertFileSrc };

/**
 * Commands the shared `platform_invoke` dispatcher owns: Git compatibility
 * names, AI commit generation, and dotted shared Core operations. Every other
 * command is a Tauri command registered in `src-tauri/src/main.rs` and is
 * invoked directly.
 *
 * The rule mirrors the dispatcher instead of listing native commands. A list
 * silently sends a newly registered host command to the dispatcher, which
 * rejects it as not implemented; that is how the Maven dependency tree broke
 * (#970). `tauri-core.routing.test.ts` checks the rule against `main.rs`.
 */
export function isPlatformDispatcherCommand(command: string): boolean {
  return (
    command.startsWith("git_") ||
    command.startsWith("ai_commit_") ||
    command.includes(".")
  );
}

/**
 * A rejected host command, normalized to an `Error`.
 *
 * Tauri rejects with whatever the Rust command serialized, usually a bare
 * string. Callers that report `error instanceof Error ? error.message : …`
 * would otherwise replace the host's reason with their generic fallback.
 * Fields of a structured rejection such as `code` and `details` are kept, and
 * `toString` returns the message so string interpolation reads as before.
 */
export class HostCommandError extends Error {
  readonly command: string;
  readonly code?: string;
  readonly details?: unknown;

  constructor(command: string, message: string, fields: Record<string, unknown> = {}) {
    super(message);
    this.name = "HostCommandError";
    this.command = command;
    for (const [key, value] of Object.entries(fields)) {
      if (key === "message" || key === "name" || key === "stack" || key === "command") continue;
      (this as Record<string, unknown>)[key] = value;
    }
  }

  override toString(): string {
    return this.message;
  }
}

export function toHostCommandError(command: string, error: unknown): Error {
  if (error instanceof Error) return error;
  if (typeof error === "string") return new HostCommandError(command, error);
  if (error && typeof error === "object") {
    const fields = error as Record<string, unknown>;
    const message =
      typeof fields.message === "string" && fields.message.trim()
        ? fields.message
        : safeJson(error);
    return new HostCommandError(command, message, fields);
  }
  return new HostCommandError(command, String(error));
}

function safeJson(value: unknown): string {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}


export function invoke<T>(
  command: string,
  args?: InvokeArgs,
  options?: Partial<InvokeOptions> & {
    gitExecutionSource?: "user" | "background" | "unknown";
    // Long-running shared commands publish progress as `platform_invoke` events.
    agentEvents?: Channel<unknown>;
  },
): Promise<T> {
  const { gitExecutionSource = "unknown", agentEvents, ...forwardedOptions } = options ?? {};
  // Execution provenance is local metadata; Tauri requires headers only when native options are supplied.
  const nativeOptions: InvokeOptions | undefined = Object.keys(forwardedOptions).length
    ? { ...forwardedOptions, headers: forwardedOptions.headers ?? {} }
    : undefined;
  const requiredCapability = capabilityForCommand(command);
  if (requiredCapability && !isBackendCapabilityAvailable(requiredCapability)) {
    return Promise.reject(
      new Error(`${BACKEND_UNAVAILABLE_TOOLTIP}: ${requiredCapability} (${command})`),
    );
  }
  const rejectAsError = (error: unknown): never => {
    throw toHostCommandError(command, error);
  };
  if (!isPlatformDispatcherCommand(command)) {
    return tauriInvoke<T>(command, args, nativeOptions).catch(rejectAsError);
  }

  if ((command.startsWith("git_") || command.startsWith("git.")) && command !== "git.consolePresentation") {
    const payload = { ...(args as Record<string, unknown> ?? {}) };
    const operationId = typeof payload.operationId === "string" ? payload.operationId : crypto.randomUUID();
    payload.operationId = operationId;
    const channel = new Channel<GitExecutionEvent>();
    channel.onmessage = (event) => {
      deliverGitExecution({ ...event, action: command,
        workingDirectory: event.workingDirectory ?? String(payload.repoPath ?? payload.root ?? "") });
    };
    return tauriInvoke<unknown>("platform_invoke", { command, args: payload, gitEvents: channel, gitExecution: { ...gitExecutionPreferences(), source: gitExecutionSource } }, nativeOptions).then(
      (value) => {
        return adaptCoreResult<T>(command, args as Record<string, any> | undefined, value);
      },
      rejectAsError,
    );
  }
  return tauriInvoke<unknown>(
    "platform_invoke",
    agentEvents === undefined
      ? { command, args: args ?? {} }
      : { command, args: args ?? {}, agentEvents },
    nativeOptions,
  ).then(
    (value) => adaptCoreResult<T>(command, args as Record<string, any> | undefined, value),
    rejectAsError,
  );
}

function capabilityForCommand(command: string): BackendCapability | null {
  if (command.startsWith("github_")) return "github";
  if (command.startsWith("docker_")) return "docker";
  if (command.startsWith("wsl_")) return "wsl";
  if (
    command.startsWith("ssh_") ||
    command.includes("remote_credential") ||
    command === "create_remote_terminal"
  ) {
    return "remote";
  }
  if (
    command.includes("database") ||
    command.includes("db_credential") ||
    command === "list_saved_connections" ||
    command === "save_connection" ||
    command === "delete_saved_connection" ||
    command === "test_connection"
  ) {
    return "database";
  }
  if (command.startsWith("debug_")) return "debugger";
  if (
    command === "run_discover_toolchains" ||
    command === "run_list_java_sources" ||
    command === "run_resolve_launch" ||
    command === "run_resolve_toolchains" ||
    command === "run_start_process" ||
    command === "run_stop_process" ||
    command === "run_write_documents" ||
    command === "run_write_generated" ||
    command === "run_write_stdin"
  ) {
    return "run";
  }
  if (command.startsWith("notebook_run_") || command.startsWith("run_config_")) {
    return "runActions";
  }
  if (
    command === "agent.status" ||
    command === "agent.install" ||
    command === "agent.uninstall" ||
    command === "agent.installCli" ||
    command === "agent.parseProviderConfiguration"
  ) {
    return "agent";
  }
  if (
    command.includes("acp_") ||
    command.includes("codex_") ||
    command.includes("ai_provider") ||
    command.includes("_chat") ||
    command === "get_available_agents"
  ) {
    // The legacy `features/ai` chat has no Windows backend. It keeps its own
    // gate so those commands still read "待开发" instead of reaching the
    // dispatcher that answers "not implemented".
    return "aiChat";
  }
  if (
    command.includes("extension_secret") ||
    command.startsWith("install_extension") ||
    command.startsWith("uninstall_extension") ||
    command === "get_extension_path" ||
    command === "read_extension_entrypoint" ||
    command === "get_importable_ide_projects"
  ) {
    // get_tool_path and install_language_tools are native commands; they stay
    // outside this gate so managed language tools work while the extension
    // store backend remains unavailable.
    return "extensions";
  }
  return null;
}
