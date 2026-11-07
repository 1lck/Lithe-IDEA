import { createRoot } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { MainLayout } from "@/features/layout/components/main-layout";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { refreshDeclarativeUI, removeDeclarativeUI } from "../declarative-plugin-ui";
import * as boundary from "./native-main-layout.test-boundaries";
import type { NativeContribution } from "./native-ui.types";

function contribution(name: string, placement: string): NativeContribution {
  return {
    pluginId: `fixture.${name}`,
    packageIdentity: `bytes-${name}`,
    windowId: `fixture.${name}.window`,
    title: `Panel ${name}`,
    placement,
    order: 0,
    native: {
      schemaVersion: 1,
      id: `fixture.${name}.panel`,
      kind: "form",
      nodes: [],
      controls: [{ id: "name", kind: "input", label: `Name ${name}`, value: "initial" }],
      source: { buildSystemID: `fixture.${name}.build`, function: "fixture.load" },
      actions: [
        {
          id: "save",
          title: `Save ${name}`,
          kind: "invoke",
          function: "fixture.save",
          requiresSelection: false,
        },
      ],
      buttons: [{ id: "save-button", label: `Save ${name}`, action: "save" }],
      toolbar: [],
      contextMenu: [],
    },
  };
}

/** Real MainLayout, project tabs and public controls. This shell exposes only
 * external package/window lifecycle boundaries, never panel or docking actions.
 * Terminal content, Core validation, process I/O and approval are controlled;
 * this fixture cannot establish product package admission or ConPTY behavior. */
export async function mountNativeWorkbenchBrowserTest(host: HTMLElement) {
  const entries = [
    contribution("left", "left"),
    contribution("tree", "bottom"),
    contribution("right", "right"),
    contribution("other", "right"),
  ];
  entries[1].native = {
    ...entries[1].native,
    kind: "tree",
    controls: undefined,
    buttons: undefined,
    nodes: [{ id: "root", label: "Root", children: [{ id: "child", label: "Child" }] }],
    actions: [
      {
        id: "save",
        title: "Run tree",
        kind: "invoke",
        function: "fixture.save",
        requiresSelection: true,
      },
    ],
    toolbar: ["save"],
  };
  boundary.resetWorkbenchBoundaries(entries);
  boundary.workspaceTabs.setState({
    projectTabs: (["a", "b"] as const).map((id) => ({
      id: `r24-${id}`,
      name: `Workspace ${id.toUpperCase()}`,
      path: `/fixture/${id}`,
      isActive: id === "a",
      lastOpened: 0,
    })),
  });
  const activate = (id: "a" | "b") => {
    const workspaceId = `r24-${id}`;
    useUIState.getStore(workspaceId);
    workspaceRuntimeRegistry.getStore("native-plugin-docking", workspaceId);
    boundary.fileSystem.getStore(workspaceId).setState({ rootFolderPath: `/fixture/${id}` });
    workspaceRuntimeRegistry.activateWorkspace(
      { id: workspaceId, name: id, path: `/fixture/${id}` },
      "ready",
    );
    workspaceRuntimeRegistry.updateWorkspaceStatus(workspaceId, "ready");
    boundary.workspaceTabs.setState((state) => ({
      projectTabs: state.projectTabs.map((tab) => ({ ...tab, isActive: tab.id === workspaceId })),
    }));
  };
  boundary.setWorkspaceSwitcher((id) => {
    if (id !== "r24-a" && id !== "r24-b") throw new Error(`Unknown fixture workspace: ${id}`);
    activate(id === "r24-a" ? "a" : "b");
  });
  activate("a");
  useUIState.setState(useUIState.getInitialState());
  await refreshDeclarativeUI();
  host.style.height = "900px";
  let root = createRoot(host);
  let disposed = false;
  const errors: string[] = [];
  const controls = document.createElement("nav");
  controls.setAttribute("aria-label", "Controlled external lifecycle");
  host.before(controls);
  const render = () =>
    root.render(
      <LocaleProvider language="en-US">
        <MainLayout />
      </LocaleProvider>,
    );
  const button = (label: string, action: () => void | Promise<void>) => {
    const trigger = document.createElement("button");
    trigger.textContent = label;
    trigger.onclick = () => {
      Promise.resolve()
        .then(action)
        .catch((error) => errors.push(String(error)));
    };
    controls.append(trigger);
  };
  button("External replace right package", async () => {
    entries[2] = { ...entries[2], packageIdentity: `${entries[2].packageIdentity}-replacement` };
    boundary.setEntries([...entries]);
    await refreshDeclarativeUI();
  });
  for (const label of ["secondary", "main"])
    button(`External host ${label}`, () => {
      root.unmount();
      boundary.setHostLabel(label);
      root = createRoot(host);
      render();
    });
  render();
  return {
    observe: () => ({
      opened: boundary.opened,
      closed: [...boundary.closed],
      prepared: boundary.prepared,
      owners: [...boundary.owners.values()],
      cancelled: [...boundary.cancelled],
      confirmed: [...boundary.confirmed],
      reads: [...boundary.reads],
      terminalMounts: boundary.terminalMounts,
      terminalUnmounts: boundary.terminalUnmounts,
      errors: [...errors],
    }),
    hold(kind: "open" | "close" | "prepare", bindingId: string) {
      const gates =
        kind === "open"
          ? boundary.openGates
          : kind === "close"
            ? boundary.closeGates
            : boundary.prepareGates;
      if (gates.has(bindingId)) throw new Error(`Gate already owned: ${kind}/${bindingId}`);
      gates.set(bindingId, boundary.gate());
    },
    release(kind: "open" | "close" | "prepare", bindingId: string) {
      const gates =
        kind === "open"
          ? boundary.openGates
          : kind === "close"
            ? boundary.closeGates
            : boundary.prepareGates;
      gates.get(bindingId)?.release();
      gates.delete(bindingId);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const gates of [boundary.openGates, boundary.closeGates, boundary.prepareGates]) {
        for (const gate of gates.values()) gate.release();
        gates.clear();
      }
      root.unmount();
      controls.remove();
      host.remove();
      boundary.setWorkspaceSwitcher(undefined);
      for (const entry of entries) removeDeclarativeUI(entry.pluginId);
      workspaceRuntimeRegistry.activateWorkspace(
        { id: "workspace:welcome", name: "Files" },
        "empty",
      );
      for (const id of ["r24-a", "r24-b"]) workspaceRuntimeRegistry.removeWorkspace(id);
    },
  };
}
