import { beforeEach, expect, mock, test } from "bun:test";

const calls: Array<{ command: string; args: unknown }> = [];
let result: unknown;
let rejection: Error | null = null;
mock.module("@/platform/tauri-core", () => ({
  invoke: async (command: string, args: unknown) => {
    calls.push({ command, args });
    if (rejection) throw rejection;
    return result;
  },
}));
const marketplace = await import("./declarative-marketplace");

beforeEach(() => { calls.length = 0; result = null; rejection = null; });

test("list preserves source identity and Core availability for same IDs in different sources", async () => {
  result = [
    { sourceId: "source-a", index: { plugins: [{ id: "io.example.fixture", availability: { status: "available" } }] },
      installations: { "io.example.fixture": { origin: "marketplace", sourceId: "source-a", canPrepare: true } } },
    { sourceId: "source-b", index: { plugins: [{ id: "io.example.fixture", availability: { status: "unsupported" } }] },
      installations: { "io.example.fixture": { origin: "marketplace", sourceId: "source-a", canPrepare: false } } },
  ];
  expect<unknown>(await marketplace.listDeclarativeMarketplace()).toBe(result);
  expect(calls).toEqual([{ command: "declarative_marketplace_list", args: undefined }]);
});

test("prepare passes only IDs while URL, installation path, platform and trust remain native", async () => {
  await marketplace.prepareDeclarativeMarketplace("review-a", "source-a", "io.example.fixture");
  expect(calls).toEqual([{ command: "declarative_marketplace_prepare", args: {
    operationId: "review-a", sourceId: "source-a", pluginId: "io.example.fixture",
  } }]);
});

test("confirmation carries explicit approval and the reviewed digest without rewriting them", async () => {
  await marketplace.confirmDeclarativeMarketplace("review-a", "reviewed-digest", false);
  expect(calls).toEqual([{ command: "declarative_marketplace_confirm", args: {
    operationId: "review-a", manifestDigest: "reviewed-digest", approved: false,
  } }]);
});

test("refresh and cancellation use the same owner supplied operation identity", async () => {
  await marketplace.refreshDeclarativeMarketplace("refresh-a", "source-a");
  await marketplace.cancelDeclarativeMarketplace("refresh-a");
  expect(calls).toEqual([
    { command: "declarative_marketplace_refresh", args: { operationId: "refresh-a", sourceId: "source-a" } },
    { command: "declarative_marketplace_cancel", args: { operationId: "refresh-a" } },
  ]);
});

test("native source and approval refusals reach callers without becoming success", async () => {
  rejection = new Error("marketplace updates must use the original installation source");
  await expect(marketplace.prepareDeclarativeMarketplace("wrong-source", "source-b", "io.example.fixture"))
    .rejects.toBe(rejection);
});
