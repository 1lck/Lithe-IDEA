import { invoke } from "@/platform/tauri-core";

/** Which kind of children one `variables` request asks for. */
export type VariablePageFilter = "named" | "indexed";

/** The exact `variables` arguments Core wants sent next. */
export interface VariablePageRequest {
  filter?: VariablePageFilter;
  start: number;
  count: number;
  remainingCount?: number;
}

/**
 * Core-owned paging cursor of one variable container. The host stores it and
 * echoes it back; only `next` is meant to be read.
 */
export interface VariablePageCursor {
  variablesReference: number;
  pageSize: number;
  segments: unknown[];
  loadedPages: string[];
  next?: VariablePageRequest;
}

/** Identity fields Core fingerprints to detect a repeated page. */
export interface VariablePageItem {
  name: string;
  value: string;
  type?: string;
  evaluateName?: string;
  variablesReference: number;
}

/** Plans the first bounded page of a container from its reported child counts (`debug.planVariablePage`). */
export function planVariablePage(request: {
  variablesReference: number;
  namedVariables?: number;
  indexedVariables?: number;
  pageSize: number;
}): Promise<VariablePageCursor> {
  return invoke<VariablePageCursor>("debug.planVariablePage", request);
}

/** Merges one returned page into its cursor (`debug.reduceVariablePage`). */
export function reduceVariablePage(request: {
  state: VariablePageCursor;
  requested: VariablePageRequest;
  page: VariablePageItem[];
  newItemCount: number;
}): Promise<{ accept: boolean; state: VariablePageCursor }> {
  return invoke<{ accept: boolean; state: VariablePageCursor }>("debug.reduceVariablePage", request);
}
