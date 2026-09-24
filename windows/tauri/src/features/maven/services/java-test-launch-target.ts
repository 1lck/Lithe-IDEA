import { invokeLsp, type JavaTestItem, type JavaTestItems } from "@/platform/lsp-core-adapter";

type JavaTestItemsInvoker = (command: string, args: Record<string, unknown>) => Promise<JavaTestItems>;

/** Confirms a launch class belongs to this file using JDT, including sibling top-level classes. */
export async function resolveJavaTestClass(
  workspacePath: string,
  filePath: string,
  className: string,
  invokeCommand: JavaTestItemsInvoker = (command, args) => invokeLsp<JavaTestItems>(command, args),
): Promise<string | null> {
  const discovered = await invokeCommand("java_test_items", { workspacePath, filePath });
  const find = (items: readonly JavaTestItem[]): string | null => {
    for (const item of items) {
      if (item.testLevel === 5 && item.fullName === className) return item.fullName;
      const nested = find(item.children);
      if (nested) return nested;
    }
    return null;
  };
  return find(discovered.items);
}
