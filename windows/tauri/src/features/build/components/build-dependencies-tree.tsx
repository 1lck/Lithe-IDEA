import { useMemo, useRef, useState } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { CaretDownIcon, CaretRightIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import type { BuildDependencyNode, BuildDependencySnapshot } from "../services/build-provider-workspace";

/** The tree is a rendering projection of Core's bounded canonical result.
 * Coordinates are displayed as supplied, never converted to local JAR paths. */
export function BuildDependenciesTree({ result }: { result: BuildDependencySnapshot }) {
  const { t } = useTranslation(), scroll = useRef<HTMLDivElement>(null);
  const [expanded, setExpanded] = useState(new Set<string>());
  const rows = useMemo(() => {
    const rows: Array<{ id: string; depth: number; node: BuildDependencyNode }> = [];
    const visit = (nodes: BuildDependencyNode[], parent: string, depth: number) => {
      nodes.forEach((node, index) => {
        const id = `${parent}/${index}`; rows.push({ id, depth, node });
        if (expanded.has(id)) visit(node.children ?? [], id, depth + 1);
      });
    };
    visit(result.dependencies, "root", 0); return rows;
  }, [result, expanded]);
  const virtual = useVirtualizer({ count: rows.length, getScrollElement: () => scroll.current, estimateSize: () => 28,
    getItemKey: index => rows[index]!.id, overscan: 6 });
  const row = (index: number) => {
    const { id, depth, node } = rows[index]!;
    const children = !!node.children?.length;
    const content = <>
      {children ? expanded.has(id) ? <CaretDownIcon className="size-3 shrink-0" /> : <CaretRightIcon className="size-3 shrink-0" /> : <span className="w-3 shrink-0" />}
      <span className="truncate">{node.name}</span><span className="truncate text-subtle-foreground">{[node.group, node.version, node.scope].filter(Boolean).join(" · ")}</span>
    </>;
    if (!children) return <div key={id} className="flex h-[28px] items-center gap-1 pr-2 select-text ui-text-sm" style={{ paddingLeft: 8 + depth * 12 }}>{content}</div>;
    return <Button key={id} variant="ghost" className="h-[28px] w-full justify-start rounded-none pr-2" style={{ paddingLeft: 8 + depth * 12 }}
      aria-expanded={expanded.has(id)} onClick={() => setExpanded(previous => {
        const next = new Set(previous); if (next.has(id)) next.delete(id); else next.add(id); return next;
      })}>
      {content}
    </Button>;
  };
  return <section className="flex min-h-0 flex-1 flex-col" aria-label={t("build.window.dependencies")}>
    <div className="px-2 py-1 text-subtle-foreground ui-text-sm">{t("build.window.dependencies")}</div>
    {result.truncated ? <div role="alert" className="px-2 ui-text-sm">{t("build.window.dependenciesTruncated")}</div> : null}
    {!result.dependencies.length ? <div className="px-2 ui-text-sm">{t("build.window.noDependencies")}</div> : null}
    <ScrollArea className="min-h-0 flex-1" viewportProps={{ ref: scroll }}>
      {rows.length <= 200 ? rows.map((_, index) => row(index)) : <div className="relative" style={{ height: virtual.getTotalSize() }}>
        {virtual.getVirtualItems().map(item => <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}
      </div>}
    </ScrollArea>
  </section>;
}
