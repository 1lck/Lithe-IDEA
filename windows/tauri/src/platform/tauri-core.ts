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

const nativeCommands = new Set([
  "begin_frontend_terminal_session",
  "clipboard_clear",
  "clipboard_get",
  "clipboard_paste",
  "clipboard_set",
  "close_terminal",
  "core_cancel",
  "core_execute",
  "create_app_window",
  "create_terminal",
  "get_secure_secret",
  "frontend_trace",
  "get_bundled_extensions_path",
  "get_monospace_fonts",
  "get_symlink_info",
  "get_system_fonts",
  "get_system_theme",
  "list_shells",
  "move_file",
  "open_file_external",
  "read_file_custom",
  "read_local_file",
  "record_startup_milestone",
  "remove_secure_secret",
  "rename_file",
  "set_native_window_appearance",
  "set_project_root",
  "start_watching",
  "stop_watching",
  "store_secure_secret",
  "terminal_resize",
  "terminal_set_paused",
  "terminal_write",
  "take_pending_cli_open_requests",
  "warm_terminal_environment",
  "validate_font",
  "write_file",
]);

export function invoke<T>(
  command: string,
  args?: InvokeArgs,
  options?: InvokeOptions,
): Promise<T> {
  const requiredCapability = capabilityForCommand(command);
  if (requiredCapability && !isBackendCapabilityAvailable(requiredCapability)) {
    return Promise.reject(
      new Error(`${BACKEND_UNAVAILABLE_TOOLTIP}: ${requiredCapability} (${command})`),
    );
  }
  if (nativeCommands.has(command)) {
    return tauriInvoke<T>(command, args, options);
  }

  return tauriInvoke<unknown>("platform_invoke", { command, args: args ?? {} }, options).then(
    (value) => adaptCoreResult<T>(command, args as Record<string, any> | undefined, value),
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
  if (command.startsWith("notebook_run_") || command.startsWith("run_config_")) {
    return "runActions";
  }
  if (
    command.includes("acp_") ||
    command.includes("codex_") ||
    command.includes("ai_provider") ||
    command.includes("_chat") ||
    command === "get_available_agents"
  ) {
    return "agent";
  }
  if (
    command.includes("extension_secret") ||
    command.startsWith("install_extension") ||
    command.startsWith("uninstall_extension") ||
    command === "get_extension_path" ||
    command === "read_extension_entrypoint" ||
    command === "get_tool_path" ||
    command === "get_importable_ide_projects"
  ) {
    return "extensions";
  }
  return null;
}
