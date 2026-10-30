import type { VcsRootController } from "./vcs-root-controller";
import type { VcsSnapshot } from "./vcs-root-types";

interface Draft {
  value: string;
  source: VcsSnapshot;
}
interface MappingState {
  drafts: Map<string, Draft>;
  saving: string | null;
  error: unknown;
}
export class VcsMappingController {
  #state: MappingState = { drafts: new Map(), saving: null, error: null };
  #closed = false;
  #listeners = new Set<() => void>();
  constructor(private roots: VcsRootController) {}
  getSnapshot = () => this.#state;
  subscribe = (listener: () => void) => {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  };
  #publish(patch: Partial<MappingState>) {
    this.#state = { ...this.#state, ...patch };
    for (const listener of this.#listeners) listener();
  }
  edit(id: string, value: string) {
    const source = this.roots.getSnapshot().snapshot;
    if (
      this.#closed ||
      this.#state.saving !== null ||
      !source?.mappings ||
      source.detection.truncated
    )
      return;
    const choice = (source.mappingChoices ?? source.detection.ambiguous).find(
      (row) => row.id === id,
    );
    const saved = source.mappings.entries.find((row) => row.id === id);
    if (
      (!choice && !saved) ||
      (value !== "" && !choice?.vcs.includes(value) && value !== saved?.vcs) ||
      (!this.#state.drafts.has(id) && this.#state.drafts.size >= 64)
    )
      return;
    const previous = this.#state.drafts.get(id);
    const drafts = new Map(this.#state.drafts);
    drafts.set(id, { value, source: previous?.source ?? source });
    this.#publish({ drafts, error: null });
  }
  cancel(id: string) {
    if (this.#state.saving !== null) return;
    const drafts = new Map(this.#state.drafts);
    drafts.delete(id);
    this.#publish({ drafts, error: null });
  }
  async save(id: string) {
    const draft = this.#state.drafts.get(id);
    if (this.#closed || !draft || this.#state.saving !== null) return;
    this.#publish({ saving: id, error: null });
    try {
      if (this.roots.getSnapshot().snapshot !== draft.source)
        throw new Error("vcs.mapping.conflict");
      await this.roots.saveMapping(id, draft.value || null);
      if (!this.#closed) {
        const drafts = new Map(this.#state.drafts);
        drafts.delete(id);
        this.#publish({ drafts });
      }
    } catch (error) {
      if (!this.#closed) this.#publish({ error });
    } finally {
      if (!this.#closed) this.#publish({ saving: null });
    }
  }
  close() {
    this.#closed = true;
    this.#state = { drafts: new Map(), saving: null, error: null };
    this.#listeners.clear();
  }
}
