import { expect, spyOn, test } from "bun:test";
import { indexedDBParserCache } from "@/features/editor/lib/wasm-parser/cache-indexeddb";
import { extensionInstaller } from "./extension-installer";

test("cancelling a parser install aborts fetch without publishing cached state", async () => {
  let aborted = false;
  const writes = spyOn(indexedDBParserCache, "set").mockResolvedValue(undefined);
  const fetcher = spyOn(globalThis, "fetch").mockImplementation(
    ((_url, options) =>
      new Promise<Response>((_resolve, reject) => {
        options?.signal?.addEventListener(
          "abort",
          () => {
            aborted = true;
            reject(new DOMException("Cancelled", "AbortError"));
          },
          { once: true },
        );
      })) as typeof fetch,
  );
  const outcome = extensionInstaller
    .installLanguage(
      "php",
      "https://fixture.invalid/parser.wasm",
      "https://fixture.invalid/highlights.scm",
    )
    .then(
      () => "installed",
      () => "cancelled",
    );
  try {
    extensionInstaller.cancelInstallation("php");
    expect(await outcome).toBe("cancelled");
    expect(aborted).toBe(true);
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(writes).not.toHaveBeenCalled();
  } finally {
    extensionInstaller.cancelInstallation("php");
    await outcome;
    fetcher.mockRestore();
    writes.mockRestore();
  }
});
