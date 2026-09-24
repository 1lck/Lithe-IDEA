import { invoke } from "@/platform/tauri-core";
import type { PlatformQuota, QuotaPlatformId } from "../types/quota.types";

export type QuotaInvoker = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

/**
 * Asks the host for one platform's quota.
 *
 * The probe runs in the host, not here: the usage endpoints only accept the
 * user's own CLI login, and that credential must not reach the web layer. The
 * host answers with quota windows or a single stable failure category, so this
 * layer never sees a token and never has to guess why a read failed.
 */
export async function fetchPlatformQuota(
  platform: QuotaPlatformId,
  invokeCommand: QuotaInvoker = invoke,
): Promise<PlatformQuota> {
  return invokeCommand<PlatformQuota>("usage_quota", { platform });
}
