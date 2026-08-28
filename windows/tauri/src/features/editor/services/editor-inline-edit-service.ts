import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
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
import type { ProviderModel } from "@/features/ai/services/providers/ai-provider-interface";
import { useAIChatStore } from "@/features/ai/stores/ai-chat.store";
import type { AIMessage } from "@/features/ai/types/messages.types";
import { getModelById, getProviderById } from "@/features/ai/types/providers.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { processStreamingResponse } from "@/utils/stream-utils";

const DEFAULT_INLINE_EDIT_PROVIDER_ID = "openrouter";
const DEFAULT_INLINE_EDIT_INSTRUCTION = "Improve this code while preserving behavior.";

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

export class InlineEditError extends Error {
  status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "InlineEditError";
    this.status = status;
  }
}

export async function requestInlineEdit(
  request: InlineEditRequest,
): Promise<{ editedText: string }> {
  const normalizedRequest = {
    ...request,
    provider: request.provider?.trim() || DEFAULT_INLINE_EDIT_PROVIDER_ID,
    model: request.model.trim(),
    beforeSelection: request.beforeSelection,
    selectedText: request.selectedText,
    afterSelection: request.afterSelection || "",
    instruction: request.instruction?.trim() || DEFAULT_INLINE_EDIT_INSTRUCTION,
  };

  if (!normalizedRequest.model) {
    throw new InlineEditError("No inline edit model selected.", 400);
  }

  return requestProviderInlineEdit(normalizedRequest);
}

function resolveInlineEditModel(providerId: string, modelId: string): ProviderModel | undefined {
  const staticModel = getModelById(providerId, modelId);
  if (staticModel) return staticModel;

  const dynamicModel = useAIChatStore.getState().dynamicModels[providerId]?.find((model) => {
    return model.id === modelId;
  });
  if (dynamicModel) {
    return {
      ...dynamicModel,
      maxTokens: dynamicModel.maxTokens || 4096,
    };
  }

  if (providerId === "openrouter" || providerId === "custom") {
    return {
      id: modelId,
      name: modelId,
      maxTokens: 4096,
    };
  }

  return undefined;
}

async function requestProviderInlineEdit(
  request: Required<
    Pick<InlineEditRequest, "provider" | "model" | "beforeSelection" | "selectedText">
  > &
    Omit<InlineEditRequest, "provider" | "model" | "beforeSelection" | "selectedText">,
): Promise<{ editedText: string }> {
  const providerConfig = getProviderById(request.provider);
  const model = resolveInlineEditModel(request.provider, request.model);

  if (!providerConfig) {
    throw new InlineEditError(`Provider not found: ${request.provider}`, 400);
  }

  if (!model) {
    throw new InlineEditError(`Model not found: ${request.provider}/${request.model}`, 400);
  }

  const settings = useSettingsStore.getState().settings;
  const customProviderScope = request.customProviderScope;
  const customProviderBaseUrl =
    request.provider === "custom"
      ? resolveCustomProviderBaseUrl(settings, customProviderScope)
      : "";
  if (request.provider === "custom" && !customProviderBaseUrl) {
    throw new InlineEditError(
      "Custom provider base URL is required. Add one in Settings > AI.",
      400,
    );
  }
  const provider =
    request.provider === "custom"
      ? createCustomProvider(customProviderBaseUrl)
      : getProvider(request.provider);
  if (!provider) {
    throw new InlineEditError(`Provider not found: ${request.provider}`, 400);
  }

  const apiKey =
    request.provider === "custom"
      ? await getCustomProviderApiToken(customProviderScope)
      : providerConfig.requiresApiKey
        ? await getProviderApiToken(request.provider)
        : await getProviderApiToken(request.provider).catch(() => null);
  if (providerConfig.requiresApiKey && !apiKey) {
    throw new InlineEditError(`${providerConfig.name} API key is required for inline edit.`, 402);
  }

  const messages = buildInlineEditMessages(request);
  const streamRequest = {
    modelId: request.model,
    messages,
    maxTokens: Math.min(model.maxTokens || 4096, 4096),
    temperature: 0.2,
    apiKey: apiKey || undefined,
  };

  const headers = provider.buildHeaders(apiKey || undefined);
  const payload = provider.buildPayload(streamRequest);
  const url = provider.buildUrl ? provider.buildUrl(streamRequest) : provider.apiUrl;
  const needsTauriFetch = shouldUseTauriFetchForProvider(request.provider);
  const fetchFn = needsTauriFetch ? tauriFetch : fetch;

  const response = await fetchFn(url, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new InlineEditError(
      errorText || `${providerConfig.name} inline edit request failed (${response.status})`,
      response.status,
    );
  }

  let editedText = "";
  let streamError: string | null = null;
  await processStreamingResponse(
    response,
    (chunk) => {
      editedText += chunk;
    },
    () => {},
    (error) => {
      streamError = error;
    },
  );

  if (streamError) {
    throw new InlineEditError(streamError, 500);
  }

  return { editedText: cleanInlineEditOutput(editedText) };
}

function buildInlineEditMessages(request: InlineEditRequest): AIMessage[] {
  const fileContext = [
    request.filePath ? `File: ${request.filePath}` : null,
    request.languageId ? `Language: ${request.languageId}` : null,
  ]
    .filter(Boolean)
    .join("\n");

  return [
    {
      role: "system",
      content:
        "You are Lithe inline edit. Return only the replacement text for the selected text. Do not include markdown fences, explanations, or surrounding unchanged context.",
    },
    {
      role: "user",
      content: [
        fileContext,
        `Instruction:\n${request.instruction || DEFAULT_INLINE_EDIT_INSTRUCTION}`,
        `Before selection:\n${request.beforeSelection}`,
        `Selected text:\n${request.selectedText}`,
        `After selection:\n${request.afterSelection || ""}`,
      ]
        .filter(Boolean)
        .join("\n\n"),
    },
  ];
}

function cleanInlineEditOutput(value: string): string {
  const trimmed = value.trim();
  const fenceMatch = trimmed.match(/^```[a-zA-Z0-9_-]*\n([\s\S]*?)\n```$/);
  return fenceMatch ? fenceMatch[1] : trimmed;
}
