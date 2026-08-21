import { expect, test } from "bun:test";

test("Java icon cache keeps external-change invalidation for every icon surface", async () => {
  const source = await Bun.file(new URL("./use-java-file-icon-kind.ts", import.meta.url)).text();
  const tabBarSource = await Bun.file(
    new URL("../../../features/tabs/components/tab-bar.tsx", import.meta.url),
  ).text();
  const rowSubscription = source.slice(
    source.indexOf("function subscribeToPath"),
    source.indexOf("export function useJavaFileIconCacheLifecycle"),
  );
  const treeLifecycle = source.slice(
    source.indexOf("export function useJavaFileIconCacheLifecycle"),
  );

  expect(rowSubscription).not.toContain('addEventListener("file-external-change"');
  expect(treeLifecycle).toContain('addEventListener("file-external-change"');
  expect(treeLifecycle).toContain('removeEventListener("file-external-change"');
  expect(treeLifecycle).toContain("workspaceRuntimeRegistry.subscribe(handleWorkspaceChange)");
  expect(tabBarSource).toContain("useJavaFileIconCacheLifecycle();");
});
