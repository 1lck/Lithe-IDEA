import { create } from "zustand";
import { toast } from "sonner";
import { createSelectors } from "@/utils/zustand-selectors";

export type LspStatus = "disconnected" | "connecting" | "connected" | "error";
export type LanguageLifecyclePhase =
  | "starting"
  | "serverConnected"
  | "projectImporting"
  | "serviceReady"
  | "profileApplying"
  | "fullyReady"
  | "stopped"
  | "failed";

export interface MavenProfileProjectResult {
  sessionId?: string;
  projectUri: string;
  status: string;
  errorDetails?: string;
}

interface LspStatusInfo {
  status: LspStatus;
  activeWorkspaces: string[];
  lastError?: string;
  supportedLanguages?: string[];
  documentRevision: number;
  lifecycleBySession: Record<string, LanguageLifecyclePhase>;
  mavenProfileProjects: Record<string, MavenProfileProjectResult>;
}

interface LspState {
  lspStatus: LspStatusInfo;
  actions: {
    updateLspStatus: (
      status: LspStatus,
      workspaces?: string[],
      error?: string,
      languages?: string[],
    ) => void;
    setLspError: (error: string) => void;
    clearLspError: () => void;
    markDocumentStateChanged: () => void;
    updateLanguageLifecycle: (sessionId: string, phase: LanguageLifecyclePhase) => void;
    recordMavenProfileProject: (result: MavenProfileProjectResult) => void;
    clearMavenProfileProjects: (sessionId: string) => void;
  };
}

const LSP_ERROR_TOAST_KEY = "lsp-runtime-error";

export const useLspStore = createSelectors(
  create<LspState>()((set) => ({
    lspStatus: {
      status: "disconnected",
      activeWorkspaces: [],
      lastError: undefined,
      supportedLanguages: undefined,
      documentRevision: 0,
      lifecycleBySession: {},
      mavenProfileProjects: {},
    },
    actions: {
      updateLspStatus: (status, workspaces, error, languages) => {
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            status,
            activeWorkspaces: workspaces || state.lspStatus.activeWorkspaces,
            lastError: error || (status === "error" ? state.lspStatus.lastError : undefined),
            supportedLanguages: languages || state.lspStatus.supportedLanguages,
          },
        }));
      },
      setLspError: (error) => {
        toast.error(error, {
          id: LSP_ERROR_TOAST_KEY,
          duration: 8000,
        });
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            status: "error",
            lastError: error,
          },
        }));
      },
      clearLspError: () => {
        toast.dismiss(LSP_ERROR_TOAST_KEY);
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            lastError: undefined,
            status: state.lspStatus.activeWorkspaces.length > 0 ? "connected" : "disconnected",
          },
        }));
      },
      markDocumentStateChanged: () => {
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            documentRevision: state.lspStatus.documentRevision + 1,
          },
        }));
      },
      updateLanguageLifecycle: (sessionId, phase) => {
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            lifecycleBySession: { ...state.lspStatus.lifecycleBySession, [sessionId]: phase },
          },
        }));
      },
      recordMavenProfileProject: (result) => {
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            mavenProfileProjects: {
              ...state.lspStatus.mavenProfileProjects,
              [`${result.sessionId}:${result.projectUri}`]: result,
            },
          },
        }));
      },
      clearMavenProfileProjects: (sessionId) => {
        set((state) => ({
          lspStatus: {
            ...state.lspStatus,
            mavenProfileProjects: Object.fromEntries(
              Object.entries(state.lspStatus.mavenProfileProjects).filter(([, result]) => result.sessionId !== sessionId),
            ),
          },
        }));
      },
    },
  })),
);
