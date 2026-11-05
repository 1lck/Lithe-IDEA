import {
  planVariablePage,
  reduceVariablePage,
  type VariablePageCursor,
  type VariablePageRequest,
} from "../api/variable-paging-api";
import { useDebuggerStore } from "../stores/debugger.store";
import type { DebugVariable } from "../types/debugger.types";
import { createDebugOperationId, sendDebugAdapterRequest } from "./debug-adapter-service";

/** Children fetched per `variables` request; Core decides when a container is exhausted. */
export const VARIABLE_PAGE_SIZE = 100;

/** Child identity used to drop repeated children; mirrors the fields Core fingerprints. */
function variableKey(variable: DebugVariable): string {
  return [variable.name, variable.value, variable.type ?? "", variable.evaluateName ?? "", variable.variablesReference].join("\u0000");
}

async function sendPage(sessionId: string, variablesReference: number, requested: VariablePageRequest) {
  const operationId = createDebugOperationId();
  useDebuggerStore.getState().actions.registerAdapterRequest(operationId, {
    command: "variables",
    variablesReference,
    requested,
  });
  await sendDebugAdapterRequest(
    sessionId,
    "variables",
    {
      variablesReference,
      ...(requested.filter ? { filter: requested.filter } : {}),
      start: requested.start,
      count: requested.count,
    },
    operationId,
  );
}

/**
 * Starts a container from its first page, keeping the adapter-reported named
 * and indexed counts so a large container pages instead of loading at once.
 */
export async function requestFirstVariablePage(
  sessionId: string,
  container: { variablesReference: number; namedVariables?: number; indexedVariables?: number },
) {
  const cursor = await planVariablePage({
    variablesReference: container.variablesReference,
    namedVariables: container.namedVariables,
    indexedVariables: container.indexedVariables,
    pageSize: VARIABLE_PAGE_SIZE,
  });
  if (!cursor.next) return;
  useDebuggerStore.getState().actions.setVariablePageCursor(container.variablesReference, cursor);
  await sendPage(sessionId, container.variablesReference, cursor.next);
}

/** Requests the page after the last accepted one; a no-op once Core reports the container exhausted. */
export async function requestNextVariablePage(sessionId: string, variablesReference: number) {
  const cursor = useDebuggerStore.getState().variablePageCursors[variablesReference];
  if (!cursor?.next) return;
  await sendPage(sessionId, variablesReference, cursor.next);
}

/**
 * Merges one adapter reply into the tree. Core decides whether the page is
 * shown (an older cursor or an adapter ignoring `start` is dropped) and when
 * the container is exhausted.
 */
export async function acceptVariablePage(
  variablesReference: number,
  requested: VariablePageRequest | undefined,
  page: DebugVariable[],
) {
  const { actions, variablePageCursors, variablesByReference } = useDebuggerStore.getState();
  const state: VariablePageCursor | undefined = variablePageCursors[variablesReference];
  if (!requested || !state) {
    actions.setVariables(variablesReference, page);
    return;
  }
  const known = new Set((variablesByReference[variablesReference] ?? []).map(variableKey));
  const additions = page.filter((variable) => {
    const key = variableKey(variable);
    if (known.has(key)) return false;
    known.add(key);
    return true;
  });
  const reduction = await reduceVariablePage({
    state,
    requested,
    page: page.map(({ name, value, type, evaluateName, variablesReference: reference }) => ({
      name,
      value,
      type,
      evaluateName,
      variablesReference: reference,
    })),
    newItemCount: additions.length,
  });
  actions.setVariablePageCursor(variablesReference, reduction.state);
  if (reduction.accept) actions.appendVariables(variablesReference, additions);
}
