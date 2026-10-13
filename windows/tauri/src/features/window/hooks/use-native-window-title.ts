import { useEffect } from "react";
import { invoke } from "@/platform/tauri-core";
import { useKeymapStore } from "@/features/keymaps/stores/keymaps.store";
import { IS_WINDOWS } from "@/utils/platform";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useWorkspaceTabsStore } from "../stores/workspace-tabs.store";
import { createWindowTitleSource } from "../services/window-title-source";
import { startWindowTitleSync } from "../services/window-title-sync";
import { createWindowTitleFocus } from "../services/window-title-focus";

export function useNativeWindowTitle() {
  useEffect(() => {
    if (!IS_WINDOWS) return;
    const focus = createWindowTitleFocus(document);
    const source = createWindowTitleSource({
      registry: workspaceRuntimeRegistry,
      tabs: useWorkspaceTabsStore,
      keyboardContext: useKeymapStore,
      focus,
    });
    const stop = startWindowTitleSync({
      ...source,
      subscribeFocus: (listener) => {
        window.addEventListener("focus", listener);
        return () => window.removeEventListener("focus", listener);
      },
      update: (context) => invoke<void>("update_window_title_context", { context }),
      reportError: (error) => console.warn("[window-title] 原生窗口标题同步失败", error),
    });
    return () => {
      stop();
      focus.dispose();
    };
  }, []);
}
