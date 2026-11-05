import type { AIMessage } from "@/features/ai/types/messages.types";

export interface ProviderConfig {
  id: string;
  name: string;
  apiUrl: string;
  requiresApiKey: boolean;
  maxTokens: number;
}

export interface ProviderHeaders {
  [key: string]: string;
}

export interface StreamRequest {
  modelId: string;
  messages: AIMessage[];
  maxTokens: number;
  temperature: number;
  apiKey?: string;
  responseFormat?: "text" | "json_object";
}

/**
 * Credential-free facts Rust Core needs to plan a one-shot request
 * (`ai.inlineEdit.plan`). Core owns the body, URL path, limits and decoding.
 */
export interface ProviderRequestFacts {
  wireProtocol: "chatCompletions" | "anthropicMessages" | "geminiGenerateContent";
  /** Base URL or complete protocol endpoint; blank when the user has not configured one. */
  endpoint: string;
  /** Explicit trust for a local or user-entered plain HTTP endpoint. */
  allowsInsecureHttp: boolean;
  /** Whether model ids missing from every listing are still sent. */
  acceptsUnlistedModels: boolean;
  chatTokenLimitField: "max_tokens" | "max_completion_tokens";
  supportsTemperature: boolean;
  /** Non-secret attribution headers the provider asks clients to send. */
  attributionHeaders?: ProviderHeaders;
}

export function chatCompletionsFacts(
  endpoint: string,
  overrides: Partial<ProviderRequestFacts> = {},
): ProviderRequestFacts {
  return {
    wireProtocol: "chatCompletions",
    endpoint,
    allowsInsecureHttp: false,
    acceptsUnlistedModels: false,
    chatTokenLimitField: "max_tokens",
    supportsTemperature: true,
    ...overrides,
  };
}

export interface ProviderModel {
  id: string;
  name: string;
  maxTokens?: number;
}

export abstract class AIProvider {
  constructor(protected config: ProviderConfig) {}

  abstract buildHeaders(apiKey?: string): ProviderHeaders;
  abstract buildPayload(request: StreamRequest): any;
  abstract validateApiKey(apiKey: string): Promise<boolean>;

  // Optional: Allows providers to customize the URL (e.g., add API key as query param)
  buildUrl?(request: StreamRequest): string;

  /** One-shot request facts; `null` when Core cannot plan requests for this provider. */
  requestFacts(modelId: string): ProviderRequestFacts | null {
    void modelId;
    return null;
  }

  /** Credential the provider already holds when secure storage has none (for example Ollama Cloud). */
  storedCredential(): string | null {
    return null;
  }

  // Optional: Allows providers to fetch available models dynamically
  async getModels?(apiKey?: string): Promise<ProviderModel[]> {
    void apiKey;
    return [];
  }

  get id(): string {
    return this.config.id;
  }

  get name(): string {
    return this.config.name;
  }

  get apiUrl(): string {
    return this.config.apiUrl;
  }

  get requiresApiKey(): boolean {
    return this.config.requiresApiKey;
  }
}
