import { validBuildProviderReview, type BuildModelReview } from "./build-systems-types";

export interface BuildProviderLanguageInitialization {
  ready: Promise<void>;
  cleanup(): Promise<void>;
}

/** Each caller retains its own cleanup failure until a later Stop retries
 * the adapter's original owner; awaiting a rejected start again is no proof
 * that the language process was reclaimed. */
export function beginBuildProviderLanguage(
  review: BuildModelReview,
  signal?: AbortSignal,
): BuildProviderLanguageInitialization {
  const ready = ensureBuildProviderLanguage(review, signal);
  let failure: (Error & { retryCleanup?: () => Promise<void> }) | null = null;
  let cleaned = false;
  return {
    ready,
    async cleanup() {
      if (cleaned) return;
      if (failure?.retryCleanup) {
        await failure.retryCleanup();
        failure = null;
        cleaned = true;
        return;
      }
      await ready.catch((error: unknown) => {
        if (error instanceof Error && error.message === "plugin.build.cleanupFailed") {
          failure = error;
          throw error;
        }
      });
      cleaned = true;
    },
  };
}

/** Called after explicit approval. The editor's existing per-language owner
 * deduplicates starts and restarts dead sessions; native Provider confirm then
 * binds that exact same-plugin session. This module owns no LSP transport. */
export async function ensureBuildProviderLanguage(
  review: BuildModelReview,
  signal?: AbortSignal,
  start: (args: Record<string, unknown>, signal?: AbortSignal) => Promise<unknown> = async (
    args,
    signal,
  ) => {
    await (
      await import("@/platform/tauri-core")
    ).invoke("declarative_plugins_build_authorize_provider_language", {
      operationId: review.operationId,
    });
    if (signal?.aborted) throw new Error("plugin.build.cancelled");
    return (await import("@/platform/lsp-core-adapter")).ensureBuildProviderLanguageSession(
      args,
      signal,
    );
  },
): Promise<void> {
  if (!validBuildProviderReview(review)) throw new Error("plugin.build.staleContext");
  const provider = review.provider;
  const language = (provider?.launchPlan.buildProvider as { languageServer?: string } | undefined)
    ?.languageServer;
  if (!provider || !language) return;
  if (signal?.aborted) throw new Error("plugin.build.cancelled");
  await start(
    {
      workspacePath: review.workspaceRoot,
      providerId: review.pluginId,
      pluginId: review.pluginId,
      languageId: language,
      serverPath: provider.program.serverPath,
      serverArgs: provider.program.serverArgs,
      initializationOptions: provider.program.initializationOptions ?? null,
      workspaceConfiguration: provider.program.workspaceConfiguration ?? null,
      environment: provider.program.environment,
    },
    signal,
  );
  if (signal?.aborted) throw new Error("plugin.build.cancelled");
}
