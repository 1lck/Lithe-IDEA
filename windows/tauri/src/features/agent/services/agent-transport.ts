/**
 * Windows transport for one Agent connection.
 *
 * macOS reaches the shared host through the `lithe_agent_*` C ABI. Windows uses
 * the three long-lived Tauri commands registered by `src-tauri/src/agent.rs`,
 * so ACP protocol behavior, sessions, cancellation, and process cleanup stay in
 * `rust/lithe-agent-host` and only the byte path differs.
 *
 * The subscription is established before `agent_open`, so the host cannot emit
 * an event for a connection the panel is not yet listening to.
 */

import { invoke } from "@/platform/tauri-core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { AgentConnectionState } from "../types/agent.types";

/** Launch configuration in the shared `AgentLaunch` shape. */
export interface AgentLaunchConfiguration {
  /** Catalog agent to run from its Lithe-managed install; `null` runs `command`. */
  agentId: string | null;
  command: string | null;
  args: string[];
  cwd: string;
  dataDirectory: string | null;
  authentication: "apiKey" | "codexSubscription";
  provider: {
    protocol: "responses" | "chatCompletions" | "anthropicMessages";
    baseUrl: string;
    apiKey: string;
    name?: string | null;
    model?: string | null;
    allowInsecureHttp?: boolean;
  } | null;
}

/** One live connection: an ordered command sink plus a bounded close. */
export interface AgentTransportConnection {
  send(command: unknown): Promise<void>;
  close(): Promise<void>;
}

export interface AgentTransport {
  /**
   * Start the agent and deliver its events in order. Rejects when the host
   * refuses the launch configuration; the caller then shows the message.
   */
  open(
    connectionID: string,
    launch: AgentLaunchConfiguration,
    onEvent: (event: unknown) => void,
  ): Promise<AgentTransportConnection>;
}

/** Event name the Tauri host uses for every connection of a window. */
const AGENT_EVENT_NAME = "agent_event";

interface AgentEventEnvelope {
  connectionId: string;
  event: unknown;
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

export function createTauriAgentTransport(): AgentTransport {
  return {
    async open(connectionID, launch, onEvent) {
      let unlisten: UnlistenFn | null = null;
      try {
        // Every connection of this window shares one event name, so the panel
        // filters by its own id instead of receiving another project's traffic.
        unlisten = await listen<AgentEventEnvelope>(AGENT_EVENT_NAME, ({ payload }) => {
          if (payload?.connectionId === connectionID) onEvent(payload.event);
        });
        await invoke("agent_open", {
          request: {
            connectionId: connectionID,
            workspacePath: launch.cwd,
            launch: {
              agentId: launch.agentId ?? undefined,
              command: launch.command ?? undefined,
              args: launch.args,
              cwd: launch.cwd,
              dataDirectory: launch.dataDirectory ?? undefined,
              authentication: launch.authentication,
              provider: launch.provider ?? undefined,
            },
          },
        });
      } catch (error) {
        unlisten?.();
        throw asError(error);
      }

      const release = unlisten;
      let closed = false;
      return {
        async send(command) {
          await invoke("agent_send", { connectionId: connectionID, command });
        },
        async close() {
          if (closed) return;
          closed = true;
          try {
            await invoke("agent_close", { connectionId: connectionID });
          } finally {
            release?.();
          }
        },
      };
    },
  };
}

/** Connection states a failed launch can report, for the panel's message mapping. */
export function failedState(message: string): AgentConnectionState {
  return { status: "failed", message };
}
