import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { invoke } from "./tauri-core";

export interface IdeRequestNotification {
  hostID: string;
  requestID: string;
}

// Windows WebView's monotonic clock advances during suspension and is independent
// of Date.now()/system clock corrections. This adapter is Windows-specific.
export const ideRequestTime = () => performance.now();

export async function openIdeConnection(
  args: Record<string, unknown>,
  receive: (event: IdeRequestNotification) => Promise<void>,
) {
  // Register before open can publish its descriptor or deliver a notification.
  // Each event is independent; an undelivered event cannot hold later IDs hostage.
  const dispose = await listen<IdeRequestNotification>("lithe-ide-request", ({ payload }) => {
    if (typeof payload?.hostID === "string" && typeof payload?.requestID === "string") {
      void receive(payload);
    }
  }, { target: { kind: "Webview", label: getCurrentWebview().label } });
  try {
    const result = await invoke<{ hostID: string; configuration: unknown }>(
      "ideHost.control", { action: "open", arguments: args },
    );
    return { ...result, dispose };
  } catch (error) {
    await dispose();
    throw error;
  }
}
