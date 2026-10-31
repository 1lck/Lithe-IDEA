import type { GenerationForm } from "./generation-session";

export interface DeclarationField {
  id: string;
  type: "text" | "enum" | "boolean" | "multiSelect" | "runtime";
  title: string;
  description?: string;
  advanced?: boolean;
  placeholder?: string;
  presentation?: "menu" | "segmented";
  options?: { value: string; title: string; group?: string }[];
}
export interface Requirement {
  languageID?: string;
  buildSystemID?: string;
  providers: { pluginID: string; pluginName: string; enabled: boolean; canEnable: boolean }[];
}
export interface GeneratorEntry {
  pluginID: string;
  pluginName: string;
  pluginEnabled: boolean;
  packageIdentity: string;
  canEnable: boolean;
  generator: {
    id: string;
    displayName: string;
    description?: string;
    section: string;
    // Core omits empty declaration arrays from catalog responses.
    fields?: DeclarationField[];
  };
  requirements: Requirement[];
}
export interface EvaluatedForm {
  valid: boolean;
  packageIdentity: string;
  projectName: { problem?: string };
  fields: { id: string; visible: boolean; value: unknown; problem?: string }[];
  activeRequirements: number[];
}
export interface GeneratorFormPort {
  catalog(): Promise<GeneratorEntry[]>;
  evaluate(entry: GeneratorEntry, form: GenerationForm): Promise<EvaluatedForm>;
  enable(pluginID: string): Promise<void>;
}
export interface GeneratorFormState {
  entries: GeneratorEntry[];
  selected?: GeneratorEntry;
  form: GenerationForm;
  evaluation?: EvaluatedForm;
  loading: boolean;
  evaluating: boolean;
  enabling: boolean;
  error?: unknown;
}
export const emptyForm = (): GenerationForm => ({
  projectName: "",
  values: {},
  edited: [],
  runtimes: {},
});
export const emptyFormState = (): GeneratorFormState => ({
  entries: [],
  form: emptyForm(),
  loading: true,
  evaluating: false,
  enabling: false,
});
const key = (entry: GeneratorEntry) =>
  `${entry.pluginID}/${entry.generator.id}/${entry.packageIdentity}`;
const sameGenerator = (left: GeneratorEntry, right: GeneratorEntry) =>
  left.pluginID === right.pluginID && left.generator.id === right.generator.id;

/** Owns a mounted wizard's catalog, drafts and Core form requests. No Core
 * expressions or optimistic plugin enabled state are evaluated here. */
export class GeneratorFormSession {
  state = emptyFormState();
  private closed = false;
  private revision = 0;
  private catalogRevision = 0;
  private readonly drafts = new Map<string, GenerationForm>();
  constructor(
    private readonly port: GeneratorFormPort,
    private readonly publish: (state: GeneratorFormState) => void,
  ) {}

  private emit(patch: Partial<GeneratorFormState>) {
    if (this.closed) return;
    this.state = { ...this.state, ...patch };
    this.publish(this.state);
  }
  private current(revision: number) {
    return !this.closed && this.revision === revision;
  }

  async reload(): Promise<number | undefined> {
    const catalogRevision = ++this.catalogRevision;
    const revision = ++this.revision;
    const previous = this.state.selected;
    this.emit({ loading: true, evaluation: undefined, error: undefined });
    try {
      const entries = await this.port.catalog();
      if (this.closed || catalogRevision !== this.catalogRevision) return;
      const unchanged = this.current(revision);
      const selection = unchanged ? previous : this.state.selected;
      this.emit({ entries, loading: false });
      // A user may leave the market and choose another entry while discovery
      // runs. Reconcile that choice with fresh package bytes, never restore the
      // old selection or leave it holding an entry from the previous catalog.
      const selected = selection && entries.find((entry) => sameGenerator(entry, selection));
      this.select(selected);
      if (selected) await this.evaluate(this.revision);
      if (unchanged && this.current(revision + 1)) return this.revision;
    } catch (error) {
      if (!this.closed && catalogRevision === this.catalogRevision)
        this.emit({
          loading: false,
          enabling: false,
          ...(this.current(revision) ? { evaluating: false } : {}),
          error,
        });
    }
  }

  select(selected?: GeneratorEntry): void {
    if (this.closed) return;
    ++this.revision;
    this.emit({
      selected,
      form: selected ? (this.drafts.get(key(selected)) ?? emptyForm()) : emptyForm(),
      evaluation: undefined,
      evaluating: !!selected,
      enabling: false,
      error: undefined,
    });
  }

  async choose(selected?: GeneratorEntry): Promise<void> {
    this.select(selected);
    if (selected) await this.evaluate(this.revision);
  }

  async update(form: GenerationForm): Promise<void> {
    const selected = this.state.selected;
    if (this.closed || !selected || this.state.enabling) return;
    const revision = ++this.revision;
    this.drafts.set(key(selected), form);
    this.emit({ form, evaluating: true, error: undefined });
    await this.evaluate(revision);
  }

  private async evaluate(revision: number): Promise<void> {
    const { selected, form } = this.state;
    if (!selected || !this.current(revision)) return;
    try {
      const evaluation = await this.port.evaluate(selected, form);
      if (!this.current(revision)) return;
      if (evaluation.packageIdentity !== selected.packageIdentity) {
        this.emit({
          evaluation: undefined,
          evaluating: false,
          error: new Error("generator.stale"),
        });
        return;
      }
      this.emit({ evaluation, evaluating: false });
    } catch (error) {
      if (this.current(revision)) this.emit({ evaluation: undefined, evaluating: false, error });
    }
  }

  async enable(pluginID: string): Promise<void> {
    const { selected } = this.state;
    if (!selected || this.closed || this.state.enabling) return;
    const action = pluginActions(this.state).find(
      (action) => action.kind === "enable" && action.pluginID === pluginID,
    );
    if (!action) return;
    const revision = ++this.revision;
    this.emit({ enabling: true, error: undefined });
    let failure: unknown;
    try {
      await this.port.enable(pluginID);
    } catch (error) {
      failure = Object.assign(new Error("generator.pluginEnableFailed"), { cause: error });
    }
    if (!this.current(revision)) return;
    // Failed native mutations may have changed their installation record before
    // rejecting. Re-read actual status on both success and failure.
    const refreshed = await this.reload();
    if (failure && refreshed !== undefined && this.current(refreshed))
      this.emit({ error: failure });
  }

  dispose(): void {
    this.closed = true;
    ++this.revision;
    ++this.catalogRevision;
    this.drafts.clear();
  }
}

export type PluginAction =
  | { kind: "enable"; pluginID: string; name: string }
  | { kind: "marketplace"; query: string };
export function pluginActions(state: GeneratorFormState): PluginAction[] {
  const { selected, evaluation } = state;
  if (!selected) return [];
  const actions = new Map<string, PluginAction>();
  if (!selected.pluginEnabled && selected.canEnable)
    actions.set(selected.pluginID, {
      kind: "enable",
      pluginID: selected.pluginID,
      name: selected.pluginName,
    });
  for (const index of state.evaluating || state.loading
    ? []
    : (evaluation?.activeRequirements ?? [])) {
    const requirement = selected.requirements[index];
    if (!requirement || requirement.providers.some((provider) => provider.enabled)) continue;
    for (const provider of requirement.providers) {
      if (provider.pluginID === selected.pluginID || !provider.canEnable) continue;
      actions.set(provider.pluginID, {
        kind: "enable",
        pluginID: provider.pluginID,
        name: provider.pluginName,
      });
    }
    if (requirement.providers.length === 0) {
      const query = requirement.languageID ?? requirement.buildSystemID;
      if (query) actions.set(`market:${query}`, { kind: "marketplace", query });
    }
  }
  return [...actions.values()];
}
export function canReview(state: GeneratorFormState): boolean {
  const advisoryFailure =
    state.error instanceof Error && state.error.message === "generator.pluginEnableFailed";
  return (
    !!state.selected?.pluginEnabled &&
    !!state.evaluation?.valid &&
    !state.loading &&
    !state.evaluating &&
    !state.enabling &&
    (state.error == null || advisoryFailure)
  );
}

export function enumPresentation(field: DeclarationField): "menu" | "segmented" {
  return field.type === "enum" && field.presentation === "segmented" ? "segmented" : "menu";
}
