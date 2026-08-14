import { invoke } from "@tauri-apps/api/core";

export interface CoreRequest<TPayload = unknown> {
  id: string;
  operationId?: string;
  timeoutMilliseconds?: number;
  command: string;
  payload: TPayload;
}

export type CoreResponse<TData> =
  | { id: string | null; ok: true; data: TData }
  | {
      id: string | null;
      ok: false;
      error: { code: string; message: string; details?: string };
    };

export async function executeCore<TData, TPayload = unknown>(
  request: CoreRequest<TPayload>,
): Promise<CoreResponse<TData>> {
  const response = await invoke<string>("core_execute", {
    request: JSON.stringify(request),
  });
  return JSON.parse(response) as CoreResponse<TData>;
}

export function cancelCoreOperation(operationId: string): Promise<boolean> {
  return invoke<boolean>("core_cancel", { operationId });
}
