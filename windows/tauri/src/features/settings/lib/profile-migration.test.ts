import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";

// Execute the actual native document-start script before the frontend stores
// hydrate; do not reimplement the migration rule in a test helper.
const source = readFileSync(
  new URL("../../../../src-tauri/src/profile_migration.rs", import.meta.url),
  "utf8",
);
const script = source.match(/pub const IMPORT_BOOTSTRAP: &str = r#"([\s\S]*?)"#;/)?.[1] ?? "";
if (!script) throw new Error("Native profile import bootstrap was not found");

function fixture() {
  const values = new Map<string, string>([
    ["lithe-update-channel", "stable"],
    ["lithe-update-preferences", JSON.stringify({ skippedVersion: "9" })],
    ["lithe-tab-sessions", "workspace-snapshot"],
  ]);
  return {
    values,
    localStorage: {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      removeItem: (key: string) => values.delete(key),
    },
  };
}

describe("native profile import bootstrap", () => {
  for (const origin of ["http://tauri.localhost", "tauri://localhost", "http://127.0.0.1:1420"]) {
    test(`imports the workspace without Stable updater preferences at ${origin}`, () => {
      const { values, localStorage } = fixture();
      runInNewContext(script, { window: { location: { origin } }, localStorage });
      expect(values.get("lithe-tab-sessions")).toBe("workspace-snapshot");
      expect(values.has("lithe-update-channel")).toBe(false);
      expect(values.has("lithe-update-preferences")).toBe(false);
      expect(values.get("lithe-dev-stable-import-v1")).toBe("complete");
      // Once a user chooses Stable inside Dev, later windows/restarts preserve it.
      values.set("lithe-update-channel", "stable");
      values.set("lithe-update-preferences", "dev-skipped-version");
      runInNewContext(script, { window: { location: { origin } }, localStorage });
      expect(values.get("lithe-update-channel")).toBe("stable");
      expect(values.get("lithe-update-preferences")).toBe("dev-skipped-version");
    });
  }

  test("does not modify storage on an external page", () => {
    const { values, localStorage } = fixture();
    runInNewContext(script, { window: { location: { origin: "https://example.invalid" } }, localStorage });
    expect(values.get("lithe-update-channel")).toBe("stable");
    expect(values.has("lithe-dev-stable-import-v1")).toBe(false);
  });
});
