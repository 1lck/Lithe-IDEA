import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";

export function getRunWindowLabel(): string {
  return getCurrentWebviewWindow().label;
}
