/** Presentation shapes from native schema 1. Core owns validation. */
export interface NativeNode {
  id: string;
  label: string;
  children?: NativeNode[];
}
export type NativeValue = string | boolean | number;
export interface NativeControl {
  id: string;
  kind: "input" | "search" | "editor" | "select" | "segmented" | "checkbox" | "stepper";
  label: string;
  value: NativeValue;
  placeholder?: string;
  enabled?: boolean;
  onCommit?: string;
  options?: { id: string; label: string }[];
  span?: number;
  info?: string;
  rows?: number;
  minimum?: number;
  maximum?: number;
  step?: number;
}
export interface NativeAction {
  id: string;
  title: string;
  kind: "refresh" | "invoke";
  function?: string;
  requiresSelection: boolean;
  icon?: { host: string };
}
export interface NativeUI {
  schemaVersion: 1;
  id: string;
  kind: "tree" | "list" | "form";
  nodes: NativeNode[];
  controls?: NativeControl[];
  buttons?: {
    id: string;
    label: string;
    action: string;
    primary?: boolean;
    enabled?: boolean;
    info?: string;
    width?: "content" | "fill";
    span?: number;
  }[];
  layout?: { columns: number };
  source?: { buildSystemID: string; function: string };
  actions: NativeAction[];
  toolbar: string[];
  contextMenu: string[];
}
export interface NativePanelIdentity {
  pluginId: string;
  packageIdentity: string;
  hostWindowId: string;
  workspaceId: string;
  windowId: string;
  panelId: string;
}
export interface NativeContribution {
  pluginId: string;
  packageIdentity: string;
  windowId: string;
  title: string;
  placement: string;
  order: number | null;
  native: NativeUI;
}
export interface NativeCallContext {
  identity: NativePanelIdentity;
  source: NonNullable<NativeUI["source"]>;
  values?: Record<string, NativeValue>;
  selectedID?: string;
}
/** Binding must cancel its native request when signal aborts. No implicit
 * build-instance selection, consent, or execution is supplied by the renderer. */
export interface NativeFunctionPort {
  load(context: NativeCallContext, signal: AbortSignal): Promise<unknown>;
  invoke(action: NativeAction, context: NativeCallContext, signal: AbortSignal): Promise<void>;
}
export interface NativePanelPort {
  validate(ui: NativeUI, data: unknown, signal: AbortSignal): Promise<NativeNode[]>;
  functions?: NativeFunctionPort;
}
export interface NativeRow {
  node: NativeNode;
  depth: number;
  parentId?: string;
  position: number;
  siblings: number;
}
export interface NativeSavedState {
  selection?: string;
  expanded: string[];
  values: Record<string, NativeValue>;
}
