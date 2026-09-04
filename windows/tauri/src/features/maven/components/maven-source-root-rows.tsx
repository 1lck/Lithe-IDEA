import { FolderIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import type { MavenSourceRoot, MavenSourceRootKind } from "../types/maven.types";

const SOURCE_ROOT_KIND_LABEL_KEYS: Record<MavenSourceRootKind, string> = {
  mainJava: "maven.sourceRoot.mainJava",
  mainResources: "maven.sourceRoot.mainResources",
  testJava: "maven.sourceRoot.testJava",
  testResources: "maven.sourceRoot.testResources",
  generatedMain: "maven.sourceRoot.generatedMain",
  generatedTest: "maven.sourceRoot.generatedTest",
};

function sourceRootIconClass(kind: MavenSourceRootKind): string {
  if (kind.startsWith("generated")) return "text-warning";
  if (kind.startsWith("test")) return "text-success";
  return "text-primary";
}

export function MavenSourceRootRows({ sourceRoots }: { sourceRoots: MavenSourceRoot[] }) {
  const { t } = useTranslation();
  return sourceRoots.map((sourceRoot) => (
    <div
      key={`${sourceRoot.kind}:${sourceRoot.path}`}
      className="flex h-7 min-w-0 items-center gap-1.5 rounded-sm px-2 ui-text-sm"
      title={sourceRoot.path}
    >
      <FolderIcon className={cn("size-3.5 shrink-0", sourceRootIconClass(sourceRoot.kind))} />
      <span className="min-w-0 flex-1 truncate">{sourceRoot.path}</span>
      <span className="shrink-0 font-mono text-subtle-foreground ui-text-xs">
        {t(SOURCE_ROOT_KIND_LABEL_KEYS[sourceRoot.kind])}
      </span>
    </div>
  ));
}
