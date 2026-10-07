import type { ExtensionRunPlan, RunActionExtensionAPI } from "../../SDK/run-actions";

/** The Go CLI owns module/workspace discovery, compilation and test semantics. */
export function discoverRunActions(manifests: Record<string, string>): ExtensionRunPlan[] {
  if (!("go.mod" in manifests)) return [];
  // A workspace may contain several modules. Run requires a selected package;
  // expose the conventional module-root action only when go.mod owns this root.
  const actions: ExtensionRunPlan[] = [{
    id: "go:run", name: "Go Run", sourceLabel: "go.mod",
    executable: "go", arguments: ["run", "."],
  }];
  actions.push({ id: "go:test", name: "Go Test", sourceLabel: "Go",
    executable: "go", arguments: ["test", "./..."] });
  return actions;
}

let registration: { dispose(): void } | undefined;
export function activate(api: RunActionExtensionAPI) {
  registration = api.runActions.register(discoverRunActions);
}
export function deactivate() {
  registration?.dispose();
  registration = undefined;
}
