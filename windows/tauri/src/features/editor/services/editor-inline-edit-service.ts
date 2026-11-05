import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import { invoke } from "@/platform/tauri-core";
import {
  type CustomProviderScope,
  getCustomProviderApiToken,
  resolveCustomProviderBaseUrl,
} from "@/features/ai/lib/custom-provider-config";
import { getProviderApiToken } from "@/features/ai/services/ai-token-service";
import {
  createCustomProvider,
  getProvider,
  shouldUseTauriFetchForProvider,
} from "@/features/ai/services/providers/ai-provider-registry";
import { useAIChatStore } from "@/features/ai/stores/ai-chat.store";
import { getModelById, getProviderById } from "@/features/ai/types/providers.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";

/**
 * Rust Core plans and decodes inline edits (`ai.inlineEdit.plan` / `ai.inlineEdit.decode`):
 * model limits, surrounding context, prompt, request body and output cleanup. This
 * module only resolves catalog facts, reads the credential and performs HTTP.
 */
export interface InlineEditRequest {
  provider?: string;
  customProviderScope: CustomProviderScope;
  model: string;
  beforeSelection: string;
  selectedText: string;
  afterSelection?: string;
  instruction?: string;
  filePath?: string;
  languageId?: string;
}

/** Failure with a stable code; `status` is the provider HTTP status when one was returned. */
export class InlineEditError extends Error {
  code: string;
  status: number | null;

  constructor(code: string, status: number | null = null) {
    super(code);
    this.name = "InlineEditError";
    this.code = code;
    this.status = status;
  }
}

/** Translation key and parameters for an inline edit failure. */
export function inlineEditErrorMessage(
  error: unknown,
  t: (key: string, values?: Record<string, string | number>) => string,
): string {
  if (!(error instanceof InlineEditError)) return t("inlineEdit.failedTryAgain");
  if (error.code === "AI_INLINE_EDIT_HTTP") {
    return t("inlineEdit.AI_INLINE_EDIT_HTTP", { status: error.status ?? 0 });
  }
  const key = `inlineEdit.${error.code}`;
  const translated = t(key);
  return translated === key ? t("inlineEdit.failedTryAgain") : translated;
}

// Core keeps 12,000 Unicode scalars on each side (`ai.inlineEdit.plan`). A scalar is at
// most two UTF-16 units, so this read window always contains Core's full context.
const INLINE_EDIT_READ_WINDOW = 24_000;

const isLowSurrogate = (code: number) => code >= 0xdc00 && code <= 0xdfff;
const isHighSurrogate = (code: number) => code >= 0xd800 && code <= 0xdbff;

/** Context window that never splits a surrogate pair, which would not survive the JSON boundary. */
export function inlineEditContext(content: string, start: number, end: number) {
  let before = Math.max(0, start - INLINE_EDIT_READ_WINDOW);
  if (before > 0 && isLowSurrogate(content.charCodeAt(before))) before += 1;
  let after = Math.min(content.length, end + INLINE_EDIT_READ_WINDOW);
  if (after < content.length && isHighSurrogate(content.charCodeAt(after - 1))) after -= 1;
  return {
    beforeSelection: content.slice(before, start),
    afterSelection: content.slice(end, after),
  };
}

interface InlineEditPlan {
  url: string;
  body: unknown;
  headers: Record<string, string>;
  credential: { required: boolean; header: string; scheme: "bearer" | "raw" };
}

const RESPONSE_BYTES = 2 * 1024 * 1024;

function coreFailure(error: unknown): InlineEditError {
  const code = error instanceof Error ? error.message : String(error);
  return new InlineEditError(code.startsWith("AI_INLINE_EDIT_") ? code : "AI_INLINE_EDIT_FAILED");
}

function modelFacts(providerId: string, modelId: string) {
  const catalog = getModelById(providerId, modelId);
  if (catalog) return { id: modelId, listing: "catalog", maxTokens: catalog.maxTokens };
  const discovered = useAIChatStore
    .getState()
    .dynamicModels[providerId]?.find((model) => model.id === modelId);
  if (discovered) return { id: modelId, listing: "discovered", maxTokens: discovered.maxTokens };
  return { id: modelId, listing: "unlisted" };
}

export async function requestInlineEdit(
  request: InlineEditRequest,
): Promise<{ editedText: string }> {
  const providerId = request.provider?.trim() ?? "";
  const modelId = request.model.trim();
  const settings = useSettingsStore.getState().settings;
  const scope = request.customProviderScope;
  const catalogEntry = getProviderById(providerId);
  const provider =
    providerId === "custom"
      ? createCustomProvider(resolveCustomProviderBaseUrl(settings, scope))
      : getProvider(providerId);
  if (!catalogEntry || !provider) throw new InlineEditError("AI_INLINE_EDIT_PROVIDER_NOT_FOUND");
  const facts = provider.requestFacts(modelId);
  if (!facts) throw new InlineEditError("AI_INLINE_EDIT_UNSUPPORTED_PROVIDER");
  const { attributionHeaders, ...providerFacts } = facts;

  let plan: InlineEditPlan;
  try {
    plan = await invoke<InlineEditPlan>("ai.inlineEdit.plan", {
      provider: { ...providerFacts, requiresApiKey: catalogEntry.requiresApiKey },
      model: modelFacts(providerId, modelId),
      edit: {
        beforeSelection: request.beforeSelection,
        selectedText: request.selectedText,
        afterSelection: request.afterSelection ?? "",
        instruction: request.instruction ?? "",
        filePath: request.filePath ?? "",
        languageId: request.languageId ?? "",
      },
    });
  } catch (error) {
    throw coreFailure(error);
  }

  const storedKey =
    providerId === "custom"
      ? await getCustomProviderApiToken(scope)
      : await getProviderApiToken(providerId).catch(() => null);
  const apiKey = storedKey || provider.storedCredential();
  if (plan.credential.required && !apiKey) {
    throw new InlineEditError("AI_INLINE_EDIT_MISSING_KEY");
  }
  const headers: Record<string, string> = { ...attributionHeaders, ...plan.headers };
  if (apiKey) {
    headers[plan.credential.header] =
      plan.credential.scheme === "bearer" ? `Bearer ${apiKey}` : apiKey;
  }

  const fetchFn = shouldUseTauriFetchForProvider(providerId) ? tauriFetch : fetch;
  let response: Response;
  try {
    response = await fetchFn(plan.url, {
      method: "POST",
      headers,
      body: JSON.stringify(plan.body),
    });
  } catch {
    throw new InlineEditError("AI_INLINE_EDIT_NETWORK_ERROR");
  }
  if (!response.ok) {
    // Provider error bodies may echo request content; only the status is surfaced.
    throw new InlineEditError("AI_INLINE_EDIT_HTTP", response.status);
  }
  const text = await response.text();
  if (text.length > RESPONSE_BYTES) throw new InlineEditError("AI_INLINE_EDIT_INVALID_RESPONSE");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new InlineEditError("AI_INLINE_EDIT_INVALID_RESPONSE");
  }
  try {
    return await invoke<{ editedText: string }>("ai.inlineEdit.decode", {
      wireProtocol: facts.wireProtocol,
      response: body,
    });
  } catch (error) {
    throw coreFailure(error);
  }
}
