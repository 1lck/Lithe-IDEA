import { debugSourcePathKey } from "../utils/debug-source-path";
import { create } from "zustand";
import { createSelectors } from "@/utils/zustand-selectors";
import type {
  DebugBreakpoint,
  DebugLaunchConfig,
  DebugProcessOutput,
  DebugProtocolMessage,
  DebugRequestContext,
  DebugScope,
  DebugSession,
  DebugSessionEnded,
  DebugStackFrame,
  DebugStoppedState,
  DebugThread,
  DebugVariable,
  DebugWatchExpression,
  DebugWatchResult,
} from "@/features/debugger/types/debugger.types";

const BREAKPOINTS_STORAGE_KEY = "lithe-debugger-breakpoints";
const USER_CONFIGS_STORAGE_KEY = "lithe-debugger-user-configs";
const WATCH_EXPRESSIONS_STORAGE_KEY = "lithe-debugger-watch-expressions";

interface DebuggerState {
  breakpoints: DebugBreakpoint[];
  breakpointGeneration: number;
  breakpointUserRevisions: Record<string, number>;
  watchExpressions: DebugWatchExpression[];
  watchResults: Record<string, DebugWatchResult>;
  workspaceConfigs: DebugLaunchConfig[];
  userConfigs: DebugLaunchConfig[];
  activeConfigId: string | null;
  activeSession: DebugSession | null;
  adapterMessages: DebugProtocolMessage[];
  adapterOutput: DebugProcessOutput[];
  endedSessions: DebugSessionEnded[];
  threads: DebugThread[];
  stackFrames: DebugStackFrame[];
  selectedFrameId: number | null;
  scopes: DebugScope[];
  variablesByReference: Record<number, DebugVariable[]>;
  stoppedState: DebugStoppedState | null;
  pendingRequests: Record<string, DebugRequestContext>;
  actions: {
    hydrate: () => void;
    setWorkspaceConfigs: (configs: DebugLaunchConfig[]) => void;
    setActiveConfigId: (configId: string | null) => void;
    toggleBreakpoint: (filePath: string, line: number) => void;
    setBreakpointEnabled: (breakpointId: string, enabled: boolean) => void;
    removeBreakpoint: (breakpointId: string) => void;
    clearBreakpoints: () => void;
    applyRelocatedBreakpoints: (filePath: string, expected: DebugBreakpoint[], points: { line: number; enabled: boolean }[], originalIndices: number[]) => boolean;
    addWatchExpression: (expression: string) => DebugWatchExpression | null;
    updateWatchExpression: (expressionId: string, expression: string) => void;
    removeWatchExpression: (expressionId: string) => void;
    clearWatchExpressions: () => void;
    setWatchResult: (result: DebugWatchResult) => void;
    clearWatchResults: () => void;
    startSession: (session: DebugSession) => void;
    stopSession: () => void;
    setSessionStatus: (status: DebugSession["status"]) => void;
    recordAdapterMessage: (message: DebugProtocolMessage) => void;
    recordAdapterOutput: (output: DebugProcessOutput) => void;
    recordSessionEnded: (event: DebugSessionEnded) => void;
    registerAdapterRequest: (operationId: string, context: DebugRequestContext) => void;
    clearAdapterRequest: (operationId: string) => void;
    setThreads: (threads: DebugThread[]) => void;
    setStackFrames: (frames: DebugStackFrame[]) => void;
    selectStackFrame: (frameId: number | null) => void;
    setScopes: (scopes: DebugScope[]) => void;
    setVariables: (variablesReference: number, variables: DebugVariable[]) => void;
    setStoppedState: (stoppedState: DebugStoppedState | null) => void;
    clearAdapterTranscript: () => void;
    getBreakpointsForFile: (filePath: string) => DebugBreakpoint[];
  };
}

const loadBreakpoints = (): DebugBreakpoint[] => {
  if (typeof window === "undefined") return [];

  try {
    const raw = window.localStorage.getItem(BREAKPOINTS_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];

    return parsed.filter(
      (item): item is DebugBreakpoint =>
        item &&
        typeof item.id === "string" &&
        typeof item.filePath === "string" &&
        typeof item.line === "number" &&
        typeof item.enabled === "boolean" &&
        typeof item.createdAt === "number",
    );
  } catch {
    return [];
  }
};

const loadUserConfigs = (): DebugLaunchConfig[] => {
  if (typeof window === "undefined") return [];

  try {
    const raw = window.localStorage.getItem(USER_CONFIGS_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed as DebugLaunchConfig[];
  } catch {
    return [];
  }
};

const loadWatchExpressions = (): DebugWatchExpression[] => {
  if (typeof window === "undefined") return [];

  try {
    const raw = window.localStorage.getItem(WATCH_EXPRESSIONS_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];

    return parsed.filter(
      (item): item is DebugWatchExpression =>
        item &&
        typeof item.id === "string" &&
        typeof item.expression === "string" &&
        typeof item.createdAt === "number",
    );
  } catch {
    return [];
  }
};

const saveBreakpoints = (breakpoints: DebugBreakpoint[]) => {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(BREAKPOINTS_STORAGE_KEY, JSON.stringify(breakpoints));
};

const saveWatchExpressions = (watchExpressions: DebugWatchExpression[]) => {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(WATCH_EXPRESSIONS_STORAGE_KEY, JSON.stringify(watchExpressions));
};

const createBreakpointId = () => `bp_${crypto.randomUUID()}`;

const sameBreakpoint = (left: DebugBreakpoint, right: DebugBreakpoint) =>
  left.id === right.id && left.filePath === right.filePath && left.line === right.line &&
  left.enabled === right.enabled && left.createdAt === right.createdAt;

const createWatchExpressionId = () => `watch_${Date.now()}_${Math.random().toString(36).slice(2)}`;

export const useDebuggerStore = createSelectors(
  create<DebuggerState>()((set, get) => ({
    breakpoints: loadBreakpoints(),
    breakpointGeneration: 0,
    breakpointUserRevisions: {},
    watchExpressions: loadWatchExpressions(),
    watchResults: {},
    workspaceConfigs: [],
    userConfigs: loadUserConfigs(),
    activeConfigId: null,
    activeSession: null,
    adapterMessages: [],
    adapterOutput: [],
    endedSessions: [],
    threads: [],
    stackFrames: [],
    selectedFrameId: null,
    scopes: [],
    variablesByReference: {},
    stoppedState: null,
    pendingRequests: {},
    actions: {
      hydrate: () => {
        set({
          breakpoints: loadBreakpoints(),
          userConfigs: loadUserConfigs(),
          watchExpressions: loadWatchExpressions(),
        });
      },

      setWorkspaceConfigs: (configs) => {
        set({ workspaceConfigs: configs });
      },

      setActiveConfigId: (configId) => {
        set({ activeConfigId: configId });
      },

      toggleBreakpoint: (filePath, line) => {
        set((state) => {
          const key = debugSourcePathKey(filePath);
          const matchesLocation = (breakpoint: DebugBreakpoint) =>
            debugSourcePathKey(breakpoint.filePath) === key && breakpoint.line === line;
          const existing = state.breakpoints.some(matchesLocation);

          // A click removes the visible location, including duplicate aliases
          // persisted before mutation and projection shared the same identity.
          const nextBreakpoints = existing
            ? state.breakpoints.filter((breakpoint) => !matchesLocation(breakpoint))
            : [
                ...state.breakpoints,
                {
                  id: createBreakpointId(),
                  filePath,
                  line,
                  enabled: true,
                  createdAt: Date.now(),
                },
              ];

          saveBreakpoints(nextBreakpoints);
          return { breakpoints: nextBreakpoints, breakpointUserRevisions: { ...state.breakpointUserRevisions, [key]: (state.breakpointUserRevisions[key] ?? 0) + 1 } };
        });
      },

      setBreakpointEnabled: (breakpointId, enabled) => {
        set((state) => {
          const key = debugSourcePathKey(state.breakpoints.find(point => point.id === breakpointId)?.filePath ?? "");
          const nextBreakpoints = state.breakpoints.map((breakpoint) =>
            breakpoint.id === breakpointId ? { ...breakpoint, enabled } : breakpoint,
          );
          saveBreakpoints(nextBreakpoints);
          return { breakpoints: nextBreakpoints, breakpointUserRevisions: { ...state.breakpointUserRevisions, [key]: (state.breakpointUserRevisions[key] ?? 0) + 1 } };
        });
      },

      removeBreakpoint: (breakpointId) => {
        set((state) => {
          const key = debugSourcePathKey(state.breakpoints.find(point => point.id === breakpointId)?.filePath ?? "");
          const nextBreakpoints = state.breakpoints.filter(
            (breakpoint) => breakpoint.id !== breakpointId,
          );
          saveBreakpoints(nextBreakpoints);
          return { breakpoints: nextBreakpoints, breakpointUserRevisions: { ...state.breakpointUserRevisions, [key]: (state.breakpointUserRevisions[key] ?? 0) + 1 } };
        });
      },

      applyRelocatedBreakpoints: (filePath, expected, points, originalIndices) => {
        const current = get().actions.getBreakpointsForFile(filePath);
        const expectedIds = new Set(expected.map(point => point.id));
        const byId = new Map(current.map(point => [point.id, point]));
        if (points.length !== originalIndices.length ||
            new Set(originalIndices).size !== originalIndices.length ||
            originalIndices.some(index => !Number.isInteger(index) || index < 0 || index >= expected.length) ||
            expected.some(point => !byId.has(point.id) || !sameBreakpoint(byId.get(point.id)!, point))) return false;
        const added = current.filter(point => !expectedIds.has(point.id));
        const occupied = new Set(added.map(point => point.line));
        const relocated = points.flatMap((point, index) => {
          const previous = expected[originalIndices[index]!]!;
          if (occupied.has(point.line - 1)) return [];
          return [{ ...previous, line: point.line - 1, enabled: point.enabled }];
        });
        const replacement = [...added, ...relocated];
        if (replacement.length === current.length && replacement.every(point =>
          current.some(existing => sameBreakpoint(existing, point)))) return true;
        const key = debugSourcePathKey(filePath);
        const nextBreakpoints = [
          ...get().breakpoints.filter(point => debugSourcePathKey(point.filePath) !== key),
          ...replacement,
        ];
        saveBreakpoints(nextBreakpoints);
        set({ breakpoints: nextBreakpoints });
        return true;
      },

      clearBreakpoints: () => {
        saveBreakpoints([]);
        set(state => ({ breakpoints: [], breakpointGeneration: state.breakpointGeneration + 1 }));
      },

      addWatchExpression: (expression) => {
        const trimmedExpression = expression.trim();
        if (!trimmedExpression) return null;

        const watchExpression = {
          id: createWatchExpressionId(),
          expression: trimmedExpression,
          createdAt: Date.now(),
        };

        set((state) => {
          const nextWatchExpressions = [...state.watchExpressions, watchExpression];
          saveWatchExpressions(nextWatchExpressions);
          return { watchExpressions: nextWatchExpressions };
        });

        return watchExpression;
      },

      updateWatchExpression: (expressionId, expression) => {
        const trimmedExpression = expression.trim();
        if (!trimmedExpression) return;

        set((state) => {
          const nextWatchExpressions = state.watchExpressions.map((watchExpression) =>
            watchExpression.id === expressionId
              ? { ...watchExpression, expression: trimmedExpression }
              : watchExpression,
          );
          saveWatchExpressions(nextWatchExpressions);
          return { watchExpressions: nextWatchExpressions };
        });
      },

      removeWatchExpression: (expressionId) => {
        set((state) => {
          const nextWatchExpressions = state.watchExpressions.filter(
            (watchExpression) => watchExpression.id !== expressionId,
          );
          const nextWatchResults = { ...state.watchResults };
          delete nextWatchResults[expressionId];
          saveWatchExpressions(nextWatchExpressions);
          return {
            watchExpressions: nextWatchExpressions,
            watchResults: nextWatchResults,
          };
        });
      },

      clearWatchExpressions: () => {
        saveWatchExpressions([]);
        set({ watchExpressions: [], watchResults: {} });
      },

      setWatchResult: (result) => {
        set((state) => ({
          watchResults: {
            ...state.watchResults,
            [result.expressionId]: result,
          },
        }));
      },

      clearWatchResults: () => {
        set({ watchResults: {} });
      },

      startSession: (session) => {
        set({
          activeSession: session,
          threads: [],
          stackFrames: [],
          selectedFrameId: null,
          scopes: [],
          variablesByReference: {},
          watchResults: {},
          stoppedState: null,
          pendingRequests: {},
        });
      },

      stopSession: () => {
        set((state) => ({
          activeSession: state.activeSession
            ? { ...state.activeSession, status: "idle" }
            : state.activeSession,
        }));
      },

      setSessionStatus: (status) => {
        set((state) => ({
          activeSession: state.activeSession ? { ...state.activeSession, status } : null,
        }));
      },

      recordAdapterMessage: (message) => {
        set((state) => ({
          adapterMessages: [...state.adapterMessages.slice(-499), message],
        }));
      },

      recordAdapterOutput: (output) => {
        set((state) => ({
          adapterOutput: [...state.adapterOutput.slice(-499), output],
        }));
      },

      recordSessionEnded: (event) => {
        set((state) => {
          const activeSession = state.activeSession;
          const isActiveSession = activeSession?.id === event.sessionId;
          return {
            endedSessions: [...state.endedSessions.slice(-99), event],
            activeSession:
              isActiveSession && activeSession
                ? { ...activeSession, status: "idle" }
                : activeSession,
            ...(isActiveSession
              ? { stoppedState: null, watchResults: {}, pendingRequests: {} }
              : {}),
          };
        });
      },

      registerAdapterRequest: (operationId, context) => {
        set((state) => ({
          pendingRequests: {
            ...state.pendingRequests,
            [operationId]: context,
          },
        }));
      },

      clearAdapterRequest: (operationId) => {
        set((state) => {
          const nextPendingRequests = { ...state.pendingRequests };
          delete nextPendingRequests[operationId];
          return { pendingRequests: nextPendingRequests };
        });
      },

      setThreads: (threads) => {
        set({ threads });
      },

      setStackFrames: (stackFrames) => {
        set({
          stackFrames,
          selectedFrameId: stackFrames[0]?.id ?? null,
        });
      },

      selectStackFrame: (frameId) => {
        set({ selectedFrameId: frameId });
      },

      setScopes: (scopes) => {
        set({ scopes });
      },

      setVariables: (variablesReference, variables) => {
        set((state) => ({
          variablesByReference: {
            ...state.variablesByReference,
            [variablesReference]: variables,
          },
        }));
      },

      setStoppedState: (stoppedState) => {
        set((state) => {
          const shouldClearInspection =
            stoppedState === null ||
            state.stoppedState === null ||
            stoppedState.threadId !== state.stoppedState.threadId;

          return shouldClearInspection
            ? {
                stoppedState,
                stackFrames: [],
                selectedFrameId: null,
                scopes: [],
                variablesByReference: {},
                watchResults: {},
                pendingRequests: {},
              }
            : { stoppedState };
        });
      },

      clearAdapterTranscript: () => {
        set({
          adapterMessages: [],
          adapterOutput: [],
          pendingRequests: {},
        });
      },

      getBreakpointsForFile: (filePath) => {
        const key = debugSourcePathKey(filePath);
        return get().breakpoints.filter(
          (breakpoint) => debugSourcePathKey(breakpoint.filePath) === key,
        );
      },
    },
  })),
);
