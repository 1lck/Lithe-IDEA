import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import * as tokens from "@/features/ai/services/ai-token-service";
import fixture from "../../../../../../shared/fixtures/ai/inline-edit-v1.json";
import {
  InlineEditError,
  inlineEditContext,
  inlineEditErrorMessage,
  requestInlineEdit,
} from "./editor-inline-edit-service";

let invoke: ReturnType<typeof spyOn<typeof native, "invoke">>;
let token: ReturnType<typeof spyOn<typeof tokens, "getProviderApiToken">>;
const originalFetch = globalThis.fetch;
beforeEach(() => {
  invoke = spyOn(native, "invoke");
  token = spyOn(tokens, "getProviderApiToken");
});
afterEach(() => {
  invoke.mockRestore();
  token.mockRestore();
  globalThis.fetch = originalFetch;
});

const plan = {
  url: "https://api.mistral.ai/v1/chat/completions",
  body: { model: "mistral-medium-2604" },
  headers: { "Content-Type": "application/json" },
  credential: { required: true, header: "Authorization", scheme: "bearer" },
};

test("sends provider facts to Core and attaches the credential only to the HTTP request", async () => {
  token.mockResolvedValue("fixture-secret");
  const response = fixture.decodes[0] as { editedText: string; response: unknown };
  invoke.mockImplementation((async (command: string) =>
    command === "ai.inlineEdit.plan" ? plan : { editedText: response.editedText }) as never);
  const fetchMock = mock(async () => new Response(JSON.stringify(response.response)));
  globalThis.fetch = fetchMock as unknown as typeof fetch;

  const result = await requestInlineEdit({
    provider: "mistral",
    customProviderScope: "chat",
    model: "mistral-medium-2604",
    ...fixture.edit,
  });

  expect(result.editedText).toBe(response.editedText);
  const [planCommand, planArgs] = invoke.mock.calls[0] as [string, Record<string, any>];
  expect(planCommand).toBe("ai.inlineEdit.plan");
  expect(planArgs.provider).toMatchObject({ wireProtocol: "chatCompletions", requiresApiKey: true });
  expect(planArgs.model).toMatchObject({ id: "mistral-medium-2604", listing: "catalog", maxTokens: 262144 });
  expect(planArgs.edit).toEqual(fixture.edit);
  expect(JSON.stringify(invoke.mock.calls)).not.toContain("fixture-secret");
  const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
  expect(url).toBe(plan.url);
  expect((init.headers as Record<string, string>).Authorization).toBe("Bearer fixture-secret");
  expect(invoke.mock.calls[1]).toEqual([
    "ai.inlineEdit.decode",
    { wireProtocol: "chatCompletions", response: response.response },
  ]);
});

test("a missing credential stops before the network and is localized", async () => {
  token.mockResolvedValue(null);
  invoke.mockResolvedValue(plan as never);
  const fetchMock = mock(async () => new Response("{}"));
  globalThis.fetch = fetchMock as unknown as typeof fetch;
  const failure = await requestInlineEdit({
    provider: "mistral",
    customProviderScope: "chat",
    model: "mistral-medium-2604",
    beforeSelection: "",
    selectedText: "x",
  }).catch((error) => error);
  expect(failure).toBeInstanceOf(InlineEditError);
  expect(failure.code).toBe("AI_INLINE_EDIT_MISSING_KEY");
  expect(fetchMock).not.toHaveBeenCalled();
  const t = (key: string) => (key === "inlineEdit.AI_INLINE_EDIT_MISSING_KEY" ? "missing" : key);
  expect(inlineEditErrorMessage(failure, t)).toBe("missing");
});

test("an HTTP failure reports only the status, never the provider body", async () => {
  token.mockResolvedValue("fixture-secret");
  invoke.mockResolvedValue(plan as never);
  globalThis.fetch = mock(async () => new Response("echoed selection", { status: 429 })) as unknown as typeof fetch;
  const failure = await requestInlineEdit({
    provider: "mistral",
    customProviderScope: "chat",
    model: "mistral-medium-2604",
    beforeSelection: "",
    selectedText: "x",
  }).catch((error) => error);
  expect(failure.code).toBe("AI_INLINE_EDIT_HTTP");
  expect(failure.status).toBe(429);
  expect(failure.message).not.toContain("echoed selection");
});

test("the context window never splits a surrogate pair", () => {
  const content = `${"😀".repeat(13_000)}|${"😀".repeat(13_000)}`;
  const start = content.indexOf("|");
  const { beforeSelection, afterSelection } = inlineEditContext(content, start, start + 1);
  for (const text of [beforeSelection, afterSelection]) {
    expect(text.length % 2).toBe(0);
    expect(text).toBe("😀".repeat(text.length / 2));
    expect(text.length).toBeGreaterThanOrEqual(23_998);
  }
});
