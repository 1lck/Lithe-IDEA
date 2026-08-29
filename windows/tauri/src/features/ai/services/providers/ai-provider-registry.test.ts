import { describe, expect, test } from "bun:test";
import { createCustomProvider } from "@/features/ai/services/providers/ai-provider-registry";

describe("custom provider request isolation", () => {
  test("keeps concurrent chat and autocomplete request URLs isolated", async () => {
    let releaseAutocompleteToken: (token: string) => void = () => undefined;
    const autocompleteToken = new Promise<string>((resolve) => {
      releaseAutocompleteToken = resolve;
    });
    const chatProvider = createCustomProvider("https://chat.example.test/v1");
    const autocompleteProvider = createCustomProvider("https://autocomplete.example.test/v1");

    const finishRequest = async (
      provider: ReturnType<typeof createCustomProvider>,
      token: Promise<string>,
    ) => ({ token: await token, url: provider.buildUrl() });

    const pendingAutocompleteRequest = finishRequest(autocompleteProvider, autocompleteToken);
    const chatRequest = await finishRequest(chatProvider, Promise.resolve("chat-token"));
    releaseAutocompleteToken("autocomplete-token");
    const autocompleteRequest = await pendingAutocompleteRequest;

    expect(chatRequest).toEqual({
      token: "chat-token",
      url: "https://chat.example.test/v1/chat/completions",
    });
    expect(autocompleteRequest).toEqual({
      token: "autocomplete-token",
      url: "https://autocomplete.example.test/v1/chat/completions",
    });
  });
});
