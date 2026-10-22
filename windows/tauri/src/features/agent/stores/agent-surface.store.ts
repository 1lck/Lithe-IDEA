import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";
import { addFileReferences, type AgentFileReference } from "../types/agent.types";

export interface AgentComposerDraft {
  text: string;
  files: AgentFileReference[];
}

export const NEW_AGENT_DRAFT_KEY = "new";

export function agentDraftKey(agentID: string, sessionID: string | null): string {
  return JSON.stringify([agentID, sessionID]);
}

const EMPTY_FILES: AgentFileReference[] = [];
export const EMPTY_AGENT_DRAFT: AgentComposerDraft = { text: "", files: EMPTY_FILES };

interface AgentSurfaceState {
  detailsOpen: boolean;
  navigationRequest: { serial: number; agentID: string; sessionID: string | null; placement: "editor" | "toolWindow"; page: "conversation" | "settings" } | null;
  /** Unsent text and attachments, keyed by the conversation they belong to. */
  drafts: Record<string, AgentComposerDraft>;
  /** Manually expanded reasoning rows, keyed by session and message. */
  reasoningExpanded: Record<string, boolean>;
  actions: {
    setDetailsOpen: (open: boolean) => void;
    navigate: (agentID: string, sessionID: string | null, placement: "editor" | "toolWindow", page?: "conversation" | "settings") => void;
    setDraft: (key: string, draft: AgentComposerDraft) => void;
    setDraftText: (key: string, text: string) => void;
    setDraftFiles: (key: string, files: AgentFileReference[]) => void;
    appendDraftFiles: (key: string, uris: string[]) => void;
    appendDraftReferences: (key: string, references: AgentFileReference[]) => void;
    moveDraft: (from: string, to: string) => void;
    setReasoningExpanded: (key: string, expanded: boolean) => void;
    clearDraft: (key: string) => void;
    reset: () => void;
  };
}

/**
 * Cross-surface state for the Agent conversation.
 *
 * The tool window and an editor tab render the same conversation from the
 * window-wide connection. Their unsent drafts and attachment lists therefore
 * cannot live in either component: moving a conversation between surfaces
 * would otherwise discard text the user has not sent yet.
 */
export const useAgentSurfaceStore = createSelectors(
  create<AgentSurfaceState>()((set, get) => ({
    detailsOpen: false,
    navigationRequest: null,
    drafts: {},
    reasoningExpanded: {},
    actions: {
      navigate: (agentID, sessionID, placement, page = "conversation") => set((state) => ({
        navigationRequest: { serial: (state.navigationRequest?.serial ?? 0) + 1, agentID, sessionID, placement, page },
      })),
      setDetailsOpen: (open) => {
        if (get().detailsOpen !== open) set({ detailsOpen: open });
      },
      setDraft: (key, draft) => {
        const current = get().drafts[key];
        if (
          current !== undefined &&
          current.text === draft.text &&
          current.files === draft.files
        ) {
          return;
        }
        set((state) => ({ drafts: { ...state.drafts, [key]: draft } }));
      },
      /**
       * Text and attachments change independently. Merging each field against
       * the store's latest value keeps one callback from restoring a stale
       * value captured by the other.
       */
      setDraftText: (key, text) => {
        const current = get().drafts[key];
        if (current !== undefined && current.text === text) return;
        const draft = current ?? EMPTY_AGENT_DRAFT;
        set((state) => ({ drafts: { ...state.drafts, [key]: { ...draft, text } } }));
      },
      setDraftFiles: (key, files) => {
        const current = get().drafts[key];
        if (current !== undefined && current.files === files) return;
        const draft = current ?? EMPTY_AGENT_DRAFT;
        set((state) => ({ drafts: { ...state.drafts, [key]: { ...draft, files } } }));
      },
      setReasoningExpanded: (key, expanded) => {
        if (get().reasoningExpanded[key] === expanded) return;
        set((state) => ({
          reasoningExpanded: { ...state.reasoningExpanded, [key]: expanded },
        }));
      },
      appendDraftFiles: (key, uris) => {
        const draft = get().drafts[key] ?? EMPTY_AGENT_DRAFT;
        const files = addFileReferences(draft.files, uris);
        set((state) => ({ drafts: { ...state.drafts, [key]: { ...draft, files } } }));
      },
      appendDraftReferences: (key, references) => {
        const draft = get().drafts[key] ?? EMPTY_AGENT_DRAFT;
        const files = addFileReferences(draft.files, references.map((file) => file.uri)).map((file) =>
          references.find((entry) => entry.uri === file.uri) ?? file,
        );
        set((state) => ({ drafts: { ...state.drafts, [key]: { ...draft, files } } }));
      },
      moveDraft: (from, to) => {
        if (from === to) return;
        const source = get().drafts[from];
        if (source === undefined) return;
        const target = get().drafts[to];
        // A second surface can already own a destination draft.
        if (target !== undefined && (target.text.length > 0 || target.files.length > 0)) return;
        set((state) => {
          const drafts = { ...state.drafts, [to]: source };
          delete drafts[from];
          return { drafts };
        });
      },
      clearDraft: (key) => {
        if (get().drafts[key] === undefined) return;
        set((state) => {
          const drafts = { ...state.drafts };
          delete drafts[key];
          return { drafts };
        });
      },
      reset: () => set({ drafts: {}, reasoningExpanded: {}, detailsOpen: false, navigationRequest: null }),
    },
  })),
);
