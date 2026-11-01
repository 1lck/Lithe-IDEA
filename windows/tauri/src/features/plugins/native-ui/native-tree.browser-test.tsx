import { useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { Dialog, DialogContent, DialogTitle } from "@/ui/dialog";
import Input from "@/ui/input";
import { NativePanel } from "./native-panel";
import { NativePanelStateStore } from "./native-panel-state";
import type {
  NativeCallContext,
  NativeFunctionPort,
  NativeNode,
  NativeUI,
} from "./native-ui.types";
import fixture from "../../../../../../shared/contracts/plugins/v1/fixtures/native-panel.plugin.json";

/** Browser-only controlled port. Real package requirements remain untouched;
 * this fixture establishes neither Core validation nor package admission. */
export function mountNativeTreeBrowserTest(host: HTMLDivElement) {
  const ui = structuredClone(fixture.ui.toolWindows[0].native) as unknown as NativeUI;
  const nodes: NativeNode[] = [
    { id: "branch", label: "Branch", children: [{ id: "child", label: "Child row" }] },
    ...Array.from({ length: 600 }, (_, index) => ({ id: `row-${index}`, label: `Row ${index}` })),
  ];
  const calls: { action: string; context: NativeCallContext }[] = [];
  let release: (() => void) | undefined;
  let openDialog: (() => void) | undefined;
  let closeDialog: (() => void) | undefined;
  let dialogOnInvoke = false;
  let holdInvoke = false;
  const pending = new Set<AbortSignal>();
  const functions: NativeFunctionPort = {
    load: async () => ({ nodes }),
    invoke: async (action, context, signal) => {
      calls.push({ action: action.id, context: structuredClone(context) });
      if (dialogOnInvoke) openDialog?.();
      if (holdInvoke) {
        pending.add(signal);
        let abort!: () => void;
        try {
          await new Promise<void>((resolve, reject) => {
            release = resolve;
            abort = () => reject(signal.reason ?? new Error("fixture cancelled"));
            signal.addEventListener("abort", abort, { once: true });
            if (signal.aborted) abort();
          });
        } finally {
          signal.removeEventListener("abort", abort);
          pending.delete(signal);
          release = undefined;
        }
      }
      return {};
    },
  };
  const root = createRoot(host);
  function Fixture() {
    const [dialog, setDialog] = useState(false);
    const input = useRef<HTMLInputElement>(null);
    openDialog = () => setDialog(true);
    closeDialog = () => setDialog(false);
    return (
      <LocaleProvider language="en-US">
        <div style={{ height: 360, width: 520, display: "flex" }}>
          <NativePanel
            identity={{
              pluginId: fixture.id,
              packageIdentity: "browser-tree-fixture",
              hostWindowId: "browser-test",
              workspaceId: "controlled-workspace",
              windowId: fixture.ui.toolWindows[0].id,
              panelId: ui.id,
            }}
            title={fixture.ui.toolWindows[0].title}
            ui={ui}
            port={{
              functions,
              validate: async (_ui, data) => (data as { nodes: NativeNode[] }).nodes,
            }}
            store={store}
            onClose={() => {}}
          />
        </div>
        <Input aria-label="Other setting" style={{ width: 240, marginTop: 24 }} />
        <Dialog open={dialog} onOpenChange={setDialog}>
          <DialogContent initialFocus={input}>
            <DialogTitle>Controlled action dialog</DialogTitle>
            <Input ref={input} aria-label="Action input" />
          </DialogContent>
        </Dialog>
      </LocaleProvider>
    );
  }
  const store = new NativePanelStateStore();
  root.render(<Fixture />);
  return {
    calls,
    pending: () => pending.size,
    configure: (options: { hold?: boolean; dialog?: boolean }) => {
      holdInvoke = options.hold ?? false;
      dialogOnInvoke = options.dialog ?? false;
    },
    release: () => release?.(),
    closeDialog: () => closeDialog?.(),
    dispose: () => {
      release?.();
      root.unmount();
      host.remove();
    },
  };
}
