import { LspClient } from "@/features/editor/lsp/lsp-client";
import type { WorkspaceLaunchScope } from "@/features/workspace/types/workspace-launch-scope";
import {
  invokeLsp,
  type JavaTestItem,
  type JavaTestItems,
} from "@/platform/lsp-core-adapter";
import type { JavaTestMethod } from "../types/maven.types";

interface JavaTestDiscoveryClient {
  ensureDocumentSynchronized(
    target: { filePath: string },
    scope: WorkspaceLaunchScope,
    content: string,
    feature?: string,
  ): Promise<unknown>;
}

type JavaTestItemsInvoker = (
  command: string,
  args: Record<string, unknown>,
) => Promise<JavaTestItems>;

function methodName(item: JavaTestItem): string | null {
  const semanticName = item.fullName.includes("#")
    ? item.fullName.slice(item.fullName.lastIndexOf("#") + 1)
    : item.label;
  const name = semanticName.replace(/\(.*$/, "").trim();
  return name || null;
}

/** Maps only JDT-confirmed method items into Maven's source action model. */
export function javaTestMethodsFromItems(items: readonly JavaTestItem[]): JavaTestMethod[] {
  const methods: JavaTestMethod[] = [];
  const visit = (item: JavaTestItem) => {
    if (item.testLevel === 6 && item.range) {
      const name = methodName(item);
      if (name) {
        methods.push({
          name,
          line: item.range.startLine,
          endLine: item.range.endLine,
        });
      }
    }
    item.children.forEach(visit);
  };
  items.forEach(visit);
  return methods
    .sort((left, right) => left.line - right.line || left.name.localeCompare(right.name))
    .filter(
      (method, index, sorted) =>
        index === 0 ||
        method.name !== sorted[index - 1].name ||
        method.line !== sorted[index - 1].line,
    );
}

/**
 * Synchronizes the editor document, then asks Java Test/JDT which methods are
 * tests. Source text is never parsed locally for Java semantic membership.
 */
export async function discoverJavaTestMethods(
  scope: WorkspaceLaunchScope,
  filePath: string,
  content: string,
  client: JavaTestDiscoveryClient = LspClient.getInstance(),
  invokeCommand: JavaTestItemsInvoker = (command, args) =>
    invokeLsp<JavaTestItems>(command, args),
): Promise<JavaTestMethod[]> {
  await client.ensureDocumentSynchronized({ filePath }, scope, content, "executeCommand");
  const discovered = await invokeCommand("java_test_items", {
    workspacePath: scope.root,
    filePath,
  });
  return javaTestMethodsFromItems(discovered.items);
}
