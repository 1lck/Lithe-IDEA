import {
  AIProvider,
  type ProviderHeaders,
  type ProviderModel,
  type StreamRequest,
} from "./ai-provider-interface";
import { providerFetch } from "./provider-fetch";

const REQUESTY_API_BASE_URL = "https://router.requesty.ai/v1";

type RequestyModel = {
  id: string;
  api?: string;
  max_output_tokens?: number;
};

export class RequestyProvider extends AIProvider {
  async getModels(apiKey?: string): Promise<ProviderModel[]> {
    try {
      // Managed policies are the curated list, the full catalog is the fallback.
      let models = await this.fetchModelList("/models/managed", apiKey);
      if (models.length === 0) {
        models = await this.fetchModelList("/models", apiKey);
      }

      return models
        .filter((model) => !model.api || model.api === "chat")
        .map((model) => ({
          id: model.id,
          name: model.id,
          maxTokens: model.max_output_tokens,
        }));
    } catch (error) {
      console.error(`${this.id} model fetch error:`, error);
      return [];
    }
  }

  private async fetchModelList(path: string, apiKey?: string): Promise<RequestyModel[]> {
    const response = await providerFetch(`${REQUESTY_API_BASE_URL}${path}`, {
      method: "GET",
      headers: this.buildHeaders(apiKey),
    });

    if (!response.ok) {
      return [];
    }

    const data = (await response.json()) as { data?: RequestyModel[] };
    return data.data || [];
  }

  buildHeaders(apiKey?: string): ProviderHeaders {
    const headers: ProviderHeaders = {
      "Content-Type": "application/json",
      Accept: "text/event-stream, application/json",
      "HTTP-Referer": "https://localhost",
      "X-Title": "Lithe",
    };

    if (apiKey) {
      headers.Authorization = `Bearer ${apiKey}`;
    }

    return headers;
  }

  buildPayload(request: StreamRequest): any {
    return {
      model: request.modelId,
      messages: request.messages,
      max_completion_tokens: request.maxTokens,
      temperature: request.temperature,
      stream: true,
    };
  }

  async validateApiKey(apiKey: string): Promise<boolean> {
    try {
      const response = await providerFetch(`${REQUESTY_API_BASE_URL}/models`, {
        method: "GET",
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
      });

      return response.ok;
    } catch (error) {
      console.error(`${this.id} API key validation error:`, error);
      return false;
    }
  }
}
