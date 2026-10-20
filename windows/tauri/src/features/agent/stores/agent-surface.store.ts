import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";
import type { AgentFileReference } from "../types/agent.types";

export interface AgentComposerDraft {
  text: string;
  files: AgentFileReference[];
}

export const NEW_AGENT_DRAFT_KEY = "new";

const EMPTY_FILES: AgentFileReference[] = [];
export const EMPTY_AGENT_DRAFT: AgentComposerDraft = { text: "", files: EMPTY_FILES };

interface AgentSurfaceState {
  /** Sessions currently rendered by an editor tab, in tab order. */
  editorSessionIDs: string[];
  detailsOpen: boolean;
  /** Unsent text and attachments, keyed by the conversation they belong to. */
  drafts: Record<string, AgentComposerDraft>;
  actions: {
    registerEditorSession: (sessionID: string) => void;
    unregisterEditorSession: (sessionID: string) => void;
    setDetailsOpen: (open: boolean) => void;
    setDraft: (key: string, draft: AgentComposerDraft) => void;
    setDraftText: (key: string, text: string) => void;
    setDraftFiles: (key: string, files: AgentFileReference[]) => void;
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
    editorSessionIDs: [],
    detailsOpen: false,
    drafts: {},
    actions: {
      registerEditorSession: (sessionID) => {
        if (get().editorSessionIDs.includes(sessionID)) return;
        set((state) => ({ editorSessionIDs: [...state.editorSessionIDs, sessionID] }));
      },
      unregisterEditorSession: (sessionID) => {
        if (!get().editorSessionIDs.includes(sessionID)) return;
        set((state) => ({
          editorSessionIDs: state.editorSessionIDs.filter((entry) => entry !== sessionID),
        }));
      },
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
      clearDraft: (key) => {
        if (get().drafts[key] === undefined) return;
        set((state) => {
          const drafts = { ...state.drafts };
          delete drafts[key];
          return { drafts };
        });
      },
      reset: () => set({ editorSessionIDs: [], drafts: {}, detailsOpen: false }),
    },
  })),
);
