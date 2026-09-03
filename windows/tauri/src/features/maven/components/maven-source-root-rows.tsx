import { FolderIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import type { MavenSourceRoot, MavenSourceRootKind } from "../types/maven.types";

const SOURCE_ROOT_KIND_LABELS: Record<MavenSourceRootKind, string> = {
  mainJava: "main Java",
  mainResources: "main resources",
  testJava: "test Java",
  testResources: "test resources",
  generatedMain: "generated main",
  generatedTest: "generated test",
};

function sourceRootIconClass(kind: MavenSourceRootKind): string {
  if (kind.startsWith("generated")) return "text-warning";
  if (kind.startsWith("test")) return "text-success";
  return "text-primary";
}

export function MavenSourceRootRows({ sourceRoots }: { sourceRoots: MavenSourceRoot[] }) {
  return sourceRoots.map((sourceRoot) => (
    <div
      key={`${sourceRoot.kind}:${sourceRoot.path}`}
      className="flex h-7 min-w-0 items-center gap-1.5 rounded-sm px-2 ui-text-sm"
      title={sourceRoot.path}
    >
      <FolderIcon className={cn("size-3.5 shrink-0", sourceRootIconClass(sourceRoot.kind))} />
      <span className="min-w-0 flex-1 truncate">{sourceRoot.path}</span>
      <span className="shrink-0 font-mono text-subtle-foreground ui-text-xs">
        {SOURCE_ROOT_KIND_LABELS[sourceRoot.kind]}
      </span>
    </div>
  ));
}
