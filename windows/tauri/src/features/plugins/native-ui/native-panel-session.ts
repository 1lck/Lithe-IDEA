import { NativePanelStateStore } from "./native-panel-state";
import type {
  NativeAction,
  NativeCallContext,
  NativeNode,
  NativePanelIdentity,
  NativePanelPort,
  NativeRow,
  NativeSavedState,
  NativeUI,
  NativeValue,
} from "./native-ui.types";

export interface NativePanelState extends NativeSavedState {
  phase: "loading" | "ready" | "failed" | "closed";
  nodes: NativeNode[];
  rows: NativeRow[];
  busy: boolean;
  validating: boolean;
  epoch: number;
  error?: string;
}
const defaults = (ui: NativeUI) =>
  Object.fromEntries((ui.controls ?? []).map((control) => [control.id, control.value]));
export function nativeRows(nodes: NativeNode[], expanded: readonly string[]): NativeRow[] {
  const open = new Set(expanded);
  const rows: NativeRow[] = [];
  const visit = (nodes: NativeNode[], depth: number, parentId?: string) =>
    nodes.forEach((node, index) => {
      rows.push({ node, depth, parentId, position: index + 1, siblings: nodes.length });
      if (open.has(node.id)) visit(node.children ?? [], depth + 1, node.id);
    });
  visit(nodes, 0);
  return rows;
}

/** One mounted panel owns its validation, requests and field callbacks. */
export class NativePanelSession {
  state: NativePanelState;
  private closed = false;
  private revision = 0;
  private readonly pending = new Set<AbortController>();
  private editOwner?: AbortController;
  constructor(
    readonly identity: NativePanelIdentity,
    readonly ui: NativeUI,
    private readonly port: NativePanelPort,
    private readonly store: NativePanelStateStore,
    private readonly publish: (state: NativePanelState) => void,
  ) {
    this.state = {
      phase: "loading",
      nodes: [],
      rows: [],
      expanded: [],
      values: defaults(ui),
      busy: false,
      validating: false,
      epoch: 0,
    };
  }
  private emit(patch: Partial<NativePanelState>): void {
    if (this.closed) return;
    this.state = { ...this.state, ...patch };
    this.publish(this.state);
  }
  private current(revision: number): boolean {
    return !this.closed && this.revision === revision;
  }
  private owns(epoch: number): boolean {
    return !this.closed && this.state.phase === "ready" && this.state.epoch === epoch;
  }
  private snapshot(): NativeSavedState {
    const { selection, expanded, values } = this.state;
    return { selection, expanded, values };
  }
  private save(): void {
    if (!this.store.write(this.identity, this.snapshot()))
      this.emit({ error: "pluginNative.stateLimit" });
  }
  private withValues(values: Record<string, NativeValue>): NativeUI {
    return {
      ...this.ui,
      controls: this.ui.controls?.map((control) => ({
        ...control,
        value: values[control.id] ?? control.value,
      })),
    };
  }
  private async request<T>(
    operation: (signal: AbortSignal) => Promise<T>,
    owner = new AbortController(),
  ): Promise<T> {
    this.pending.add(owner);
    let abort!: () => void;
    const cancelled = new Promise<never>((_, reject) => {
      abort = () => reject(owner.signal.reason ?? new Error("pluginNative.cancelled"));
      owner.signal.addEventListener("abort", abort, { once: true });
    });
    const timer = setTimeout(() => owner.abort(new Error("pluginNative.timeout")), 15000);
    try {
      owner.signal.throwIfAborted();
      return await Promise.race([operation(owner.signal), cancelled]);
    } finally {
      clearTimeout(timer);
      owner.signal.removeEventListener("abort", abort);
      this.pending.delete(owner);
    }
  }
  private invalidate(): number {
    ++this.revision;
    for (const pending of this.pending) pending.abort();
    return this.revision;
  }
  private replaceNodes(nodes: NativeNode[]): void {
    const ids = new Set<string>();
    const visit = (nodes: NativeNode[]) =>
      nodes.forEach((node) => {
        ids.add(node.id);
        visit(node.children ?? []);
      });
    visit(nodes);
    const expanded = this.state.expanded.filter((id) => ids.has(id));
    const rows = nativeRows(nodes, expanded);
    const selection = rows.some((row) => row.node.id === this.state.selection)
      ? this.state.selection
      : undefined;
    this.emit({ nodes, expanded, rows, selection });
  }
  async open(): Promise<void> {
    const revision = this.invalidate();
    const saved = this.store.read(this.identity);
    this.emit({ phase: "loading", epoch: this.state.epoch + 1, error: undefined });
    try {
      const initial = await this.request((signal) =>
        this.port.validate(this.ui, { nodes: this.ui.nodes }, signal),
      );
      if (!this.current(revision)) return;
      if (saved) {
        // Restore only current fields; Core checks their types, options and
        // budgets together with the declaration, including same-ID changes.
        const values = Object.fromEntries(
          (this.ui.controls ?? []).map((control) => [
            control.id,
            saved.values[control.id] ?? control.value,
          ]),
        );
        try {
          await this.request((signal) =>
            this.port.validate(this.withValues(values), { nodes: initial }, signal),
          );
          if (!this.current(revision)) return;
          this.emit({ values, expanded: saved.expanded, selection: saved.selection });
        } catch (error) {
          if (!this.current(revision)) return;
          this.store.remove(this.identity);
          this.emit({ values: defaults(this.ui), error: this.errorKey(error) });
        }
      }
      this.replaceNodes(initial);
      this.emit({ phase: "ready" });
      if (this.ui.source) await this.refresh();
    } catch (error) {
      if (this.current(revision)) this.emit({ phase: "failed", error: this.errorKey(error) });
    }
  }
  async edit(id: string, value: NativeValue, epoch: number, commit = false): Promise<boolean> {
    const control = this.ui.controls?.find((control) => control.id === id);
    if (!control || !this.owns(epoch) || this.state.busy || control.enabled === false) return false;
    const revision = this.revision;
    this.editOwner?.abort();
    const owner = new AbortController();
    this.editOwner = owner;
    const values = { ...this.state.values, [id]: value };
    if (!commit) {
      this.emit({ values, validating: false, error: undefined });
      this.save();
      return true;
    }
    this.emit({ values, validating: true, error: undefined });
    try {
      await this.request(
        (signal) =>
          this.port.validate(this.withValues(values), { nodes: this.state.nodes }, signal),
        owner,
      );
      if (!this.current(revision) || this.editOwner !== owner || owner.signal.aborted) return false;
      this.emit({ validating: false });
      this.save();
      return true;
    } catch (error) {
      if (this.current(revision) && this.editOwner === owner)
        this.emit({ validating: false, error: this.errorKey(error) });
      return false;
    }
  }
  select(id: string): void {
    if (!this.closed && this.state.rows.some((row) => row.node.id === id)) {
      this.emit({ selection: id });
      this.save();
    }
  }
  toggle(id: string): void {
    if (
      this.closed ||
      !this.state.rows.some((row) => row.node.id === id && row.node.children?.length)
    )
      return;
    const expanded = this.state.expanded.includes(id)
      ? this.state.expanded.filter((value) => value !== id)
      : [...this.state.expanded, id];
    const rows = nativeRows(this.state.nodes, expanded);
    const selection = rows.some((row) => row.node.id === this.state.selection)
      ? this.state.selection
      : id;
    this.emit({ expanded, rows, selection });
    this.save();
  }
  navigate(key: string): string | undefined {
    const rows = this.state.rows;
    if (!rows.length) return;
    const index = rows.findIndex((row) => row.node.id === this.state.selection);
    const row = rows[index];
    let target: NativeRow | undefined;
    if (key === "Home") target = rows[0];
    if (key === "End") target = rows[rows.length - 1];
    if (key === "ArrowDown") target = rows[Math.min(index + 1, rows.length - 1)];
    if (key === "ArrowUp") target = rows[Math.max(0, index - 1)];
    if (key === "ArrowRight" && row?.node.children?.length) {
      if (!this.state.expanded.includes(row.node.id)) this.toggle(row.node.id);
      else target = rows[index + 1];
    }
    if (key === "ArrowLeft" && row) {
      if (this.state.expanded.includes(row.node.id)) this.toggle(row.node.id);
      else target = rows.find((candidate) => candidate.node.id === row.parentId);
    }
    if ((key === "Enter" || key === " ") && row) this.toggle(row.node.id);
    if (target) this.select(target.node.id);
    return this.state.selection;
  }
  canPerform(action: NativeAction): boolean {
    return (
      !this.closed &&
      this.state.phase === "ready" &&
      !this.state.busy &&
      !this.state.validating &&
      (!this.state.error || action.kind === "refresh") &&
      this.ui.actions.includes(action) &&
      (!action.requiresSelection || !!this.state.selection) &&
      ((action.kind === "refresh" && !this.ui.source) ||
        (!!this.ui.source && !!this.port.functions))
    );
  }
  private context(): NativeCallContext {
    return {
      identity: this.identity,
      source: this.ui.source!,
      selectedID: this.state.selection,
      ...(this.ui.kind === "form" ? { values: { ...this.state.values } } : {}),
    };
  }
  async perform(actionId: string, epoch: number): Promise<void> {
    const action = this.ui.actions.find((action) => action.id === actionId);
    if (!this.owns(epoch) || !action || !this.canPerform(action)) return;
    if (action.kind === "refresh") return this.refresh();
    const revision = this.revision;
    this.emit({ busy: true, error: undefined });
    try {
      // Local text drafts are intentionally unvalidated while typing. Before
      // any form values cross the function boundary, let Core check the whole
      // current form, including fields without an onCommit action.
      if (this.ui.kind === "form") {
        await this.request((signal) =>
          this.port.validate(
            this.withValues(this.state.values),
            { nodes: this.state.nodes },
            signal,
          ),
        );
        if (!this.current(revision)) return;
      }
      await this.request((signal) => this.port.functions!.invoke(action, this.context(), signal));
      if (this.current(revision)) {
        this.emit({ busy: false });
        await this.refresh();
      }
    } catch (error) {
      if (this.current(revision)) this.emit({ busy: false, error: this.errorKey(error) });
    }
  }
  async refresh(): Promise<void> {
    if (this.closed || this.state.busy || this.state.validating || this.state.phase !== "ready")
      return;
    if (this.ui.source && !this.port.functions) {
      this.emit({ error: "pluginNative.unavailable" });
      return;
    }
    const revision = this.invalidate();
    this.emit({ busy: true, epoch: this.state.epoch + 1, error: undefined });
    try {
      if (this.ui.kind === "form" && this.ui.source) {
        await this.request((signal) =>
          this.port.validate(
            this.withValues(this.state.values),
            { nodes: this.state.nodes },
            signal,
          ),
        );
        if (!this.current(revision)) return;
      }
      const data = this.ui.source
        ? await this.request((signal) => this.port.functions!.load(this.context(), signal))
        : { nodes: this.ui.nodes };
      const nodes = await this.request((signal) =>
        this.port.validate(this.withValues(this.state.values), data, signal),
      );
      if (!this.current(revision)) return;
      this.replaceNodes(nodes);
      this.emit({ busy: false });
      this.save();
    } catch (error) {
      if (this.current(revision)) this.emit({ busy: false, error: this.errorKey(error) });
    }
  }
  async reset(): Promise<void> {
    if (this.closed) return;
    this.invalidate();
    this.store.remove(this.identity);
    this.emit({
      values: defaults(this.ui),
      expanded: [],
      selection: undefined,
      validating: false,
      busy: false,
      error: undefined,
    });
    await this.open();
  }
  close(): void {
    if (this.closed) return;
    this.invalidate();
    this.closed = true;
    this.state = {
      ...this.state,
      phase: "closed",
      busy: false,
      validating: false,
      epoch: this.state.epoch + 1,
    };
  }
  private errorKey(error: unknown): string {
    return error instanceof Error && error.message.startsWith("pluginNative.")
      ? error.message
      : "pluginNative.failed";
  }
}
