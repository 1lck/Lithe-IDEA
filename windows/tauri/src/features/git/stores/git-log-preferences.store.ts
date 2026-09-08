import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createSelectors } from "@/utils/zustand-selectors";
import { createSafeJSONStorage } from "@/utils/zustand-storage";
import { normalizeRepositoryPath } from "../api/git-repo-api";
import type { GitReferenceKind } from "../types/git.types";

export type GitLogFilterScope = "text" | "author" | "branch";

export interface GitLogPanelLayout {
  [panelId: string]: number;
}

interface GitLogPreferencesStore {
  filterQuery: string;
  filterScope: GitLogFilterScope;
  showDecorations: boolean;
  showMyBranchesOnly: boolean;
  mainPanelLayout: GitLogPanelLayout;
  inspectorPanelLayout: GitLogPanelLayout;
  collapsedReferenceSections: GitReferenceKind[];
  collapsedReferenceGroups: string[];
  markedReferenceFullNamesByRepository: Record<string, string[]>;
  actions: {
    setFilterQuery: (query: string) => void;
    setFilterScope: (scope: GitLogFilterScope) => void;
    setShowDecorations: (show: boolean) => void;
    setShowMyBranchesOnly: (show: boolean) => void;
    setMainPanelLayout: (layout: GitLogPanelLayout) => void;
    setInspectorPanelLayout: (layout: GitLogPanelLayout) => void;
    toggleReferenceSection: (kind: GitReferenceKind) => void;
    toggleReferenceGroup: (id: string) => void;
    setReferenceExpansion: (sections: GitReferenceKind[], groups: string[]) => void;
    toggleMarkedReference: (repoPath: string, fullName: string) => void;
  };
}

const DEFAULT_MAIN_LAYOUT: GitLogPanelLayout = {
  references: 19,
  commits: 57,
  inspector: 24,
};

const DEFAULT_INSPECTOR_LAYOUT: GitLogPanelLayout = {
  files: 62,
  details: 38,
};

function toggleListItem<T extends string>(items: T[], item: T): T[] {
  return items.includes(item) ? items.filter((value) => value !== item) : [...items, item];
}

const useGitLogPreferencesStoreBase = create<GitLogPreferencesStore>()(
  persist(
    (set) => ({
      filterQuery: "",
      filterScope: "text",
      showDecorations: true,
      showMyBranchesOnly: false,
      mainPanelLayout: DEFAULT_MAIN_LAYOUT,
      inspectorPanelLayout: DEFAULT_INSPECTOR_LAYOUT,
      collapsedReferenceSections: [],
      collapsedReferenceGroups: [],
      markedReferenceFullNamesByRepository: {},
      actions: {
        setFilterQuery: (filterQuery) => set({ filterQuery }),
        setFilterScope: (filterScope) => set({ filterScope }),
        setShowDecorations: (showDecorations) => set({ showDecorations }),
        setShowMyBranchesOnly: (showMyBranchesOnly) => set({ showMyBranchesOnly }),
        setMainPanelLayout: (mainPanelLayout) => set({ mainPanelLayout }),
        setInspectorPanelLayout: (inspectorPanelLayout) => set({ inspectorPanelLayout }),
        toggleReferenceSection: (kind) =>
          set((state) => ({
            collapsedReferenceSections: toggleListItem(state.collapsedReferenceSections, kind),
          })),
        toggleReferenceGroup: (id) =>
          set((state) => ({
            collapsedReferenceGroups: toggleListItem(state.collapsedReferenceGroups, id),
          })),
        setReferenceExpansion: (collapsedReferenceSections, collapsedReferenceGroups) =>
          set({ collapsedReferenceSections, collapsedReferenceGroups }),
        toggleMarkedReference: (repoPath, fullName) =>
          set((state) => {
            const repositoryKey = normalizeRepositoryPath(repoPath);
            const nextReferences = toggleListItem(
              state.markedReferenceFullNamesByRepository[repositoryKey] ?? [],
              fullName,
            );
            const markedReferenceFullNamesByRepository = {
              ...state.markedReferenceFullNamesByRepository,
            };
            if (nextReferences.length > 0) {
              markedReferenceFullNamesByRepository[repositoryKey] = nextReferences;
            } else {
              delete markedReferenceFullNamesByRepository[repositoryKey];
            }
            return { markedReferenceFullNamesByRepository };
          }),
      },
    }),
    {
      name: "git-log-preferences",
      storage: createSafeJSONStorage<Omit<GitLogPreferencesStore, "actions">>(),
      partialize: ({ actions: _, ...preferences }) => preferences,
      merge: (persistedState, currentState) => {
        const {
          markedReferenceFullNames: _legacyMarkedReferences,
          ...persistedPreferences
        } = (persistedState ?? {}) as Partial<GitLogPreferencesStore> & {
          markedReferenceFullNames?: string[];
        };
        return {
          ...currentState,
          ...persistedPreferences,
          markedReferenceFullNamesByRepository:
            persistedPreferences.markedReferenceFullNamesByRepository ?? {},
          actions: currentState.actions,
        };
      },
    },
  ),
);

export const useGitLogPreferencesStore = createSelectors(useGitLogPreferencesStoreBase);
