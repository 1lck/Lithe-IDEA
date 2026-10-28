import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { SearchField } from "@/ui/search";
import { NativePanel } from "./native-panel";
import { NativePanelStateStore } from "./native-panel-state";
import type { NativeCallContext, NativeUI } from "./native-ui.types";
import fixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-controls.plugin.json";

/** Controlled presentation only: the complete manifest and its requirements stay
 * unchanged. ReadOnly belongs to the shared primitive, not native schema 1. */
export function mountNativeFormGridBrowserTest(host: HTMLDivElement) {
  const ui = fixture.ui.toolWindows[0].native as unknown as NativeUI;
  const calls: { action: string; context: NativeCallContext }[] = [];
  const root = createRoot(host);
  const store = new NativePanelStateStore();
  host.style.width = "900px";
  root.render(
    <LocaleProvider language="en-US">
      <div style={{ height: 950, display: "flex" }}>
        <NativePanel
          identity={{
            pluginId: fixture.id,
            packageIdentity: "browser-form-grid-fixture",
            hostWindowId: "browser-test",
            workspaceId: "controlled-workspace",
            windowId: fixture.ui.toolWindows[0].id,
            panelId: ui.id,
          }}
          title={fixture.ui.toolWindows[0].title}
          ui={ui}
          port={{
            validate: async () => [],
            functions: {
              load: async () => ({ nodes: [] }),
              invoke: async (action, context) => {
                calls.push({ action: action.id, context: structuredClone(context) });
                return { nodes: [] };
              },
            },
          }}
          store={store}
          onClose={() => {}}
        />
      </div>
      <div data-readonly-probe>
        <SearchField
          aria-label="ReadOnly primitive"
          value="fixed query"
          readOnly
          onChange={() => {
            throw new Error("readOnly search emitted a change");
          }}
        />
      </div>
    </LocaleProvider>,
  );
  return {
    ui,
    calls,
    dispose() {
      try {
        root.unmount();
      } finally {
        host.remove();
      }
    },
  };
}
