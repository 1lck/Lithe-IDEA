import { afterEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import {
  addDeclarativeMarketplaceSource,
  listDeclarativeMarketplaceSources,
  removeDeclarativeMarketplaceSource,
  setDeclarativeMarketplaceSourceEnabled,
  type DeclarativeMarketplaceSource,
} from "./declarative-marketplace-sources";

const officialSource: DeclarativeMarketplaceSource = {
  id: "lithe-official",
  name: "Lithe",
  input: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
  indexURL: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
  repository: "https://github.com/Lithe-IDEA/Lithe-IDEA",
  isEnabled: true,
  kind: "official",
  isOfficial: true,
  deletable: false,
};

// The wrappers are thin: every call must hit exactly one registered host
// command with snake_case payload keys the Rust commands read, pass the
// resolved value through, and surface host rejections without wrapping.
let invokeSpy: ReturnType<typeof spyOn> | undefined;
afterEach(() => {
  invokeSpy?.mockRestore();
  invokeSpy = undefined;
});

test("list returns the host state including the corruption diagnosis", async () => {
  invokeSpy = spyOn(native, "invoke").mockResolvedValue({
    sources: [officialSource],
    problem: "plugin.marketplace.sources.corrupt: boom",
  });
  const state = await listDeclarativeMarketplaceSources();
  expect(invokeSpy).toHaveBeenCalledTimes(1);
  expect(invokeSpy.mock.calls[0][0]).toBe("declarative_marketplace_sources_state");
  expect(state.problem).toContain("plugin.marketplace.sources.corrupt");
  expect(state.sources[0].deletable).toBe(false);
});

test("add forwards the raw input and passes host rejections through", async () => {
  invokeSpy = spyOn(native, "invoke").mockRejectedValue(
    new Error("plugin.marketplace.sourceAlreadyAdded: example/lithe-plugins"),
  );
  await expect(addDeclarativeMarketplaceSource("https://github.com/example/lithe-plugins")).rejects.toThrow(
    "plugin.marketplace.sourceAlreadyAdded",
  );
  expect(invokeSpy.mock.calls[0][0]).toBe("declarative_marketplace_sources_add");
  expect(invokeSpy.mock.calls[0][1]).toEqual({ url: "https://github.com/example/lithe-plugins" });
});

test("enable toggle carries the source id and the requested state", async () => {
  invokeSpy = spyOn(native, "invoke").mockResolvedValue([]);
  await setDeclarativeMarketplaceSourceEnabled("source-abc", false);
  expect(invokeSpy.mock.calls[0][0]).toBe("declarative_marketplace_sources_set_enabled");
  expect(invokeSpy.mock.calls[0][1]).toEqual({ sourceId: "source-abc", enabled: false });
});

test("remove targets exactly one deletable source id", async () => {
  invokeSpy = spyOn(native, "invoke").mockResolvedValue([]);
  await removeDeclarativeMarketplaceSource("source-abc");
  expect(invokeSpy.mock.calls[0][0]).toBe("declarative_marketplace_sources_remove");
  expect(invokeSpy.mock.calls[0][1]).toEqual({ sourceId: "source-abc" });
});
