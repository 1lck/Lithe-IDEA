import { useEffect, useState } from "react";
import { useMavenStore } from "../stores/maven.store";
import type { MavenDependency, MavenModule } from "../types/maven.types";
import { mavenDependencySubtitle } from "../utils/maven-dependency-subtitle";
import { SidebarTreeRow } from "@/features/sidebar/components/sidebar-tree";
import { PackageIcon, FolderIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { mavenModulePomPath } from "../utils/maven-module-operations";

/** Project cached Maven results; resolving dependencies requires an explicit action. */
export function ProjectDependencies() {
  const { t } = useTranslation();
  const root = useMavenStore((state) => state.root);
  const project = useMavenStore((state) => state.project);
  const loads = useMavenStore((state) => state.dependencyLoads);
  const actions = useMavenStore((state) => state.actions);
  const [expanded, setExpanded] = useState(new Set<string>());
  useEffect(() => {
    setExpanded(new Set());
  }, [root]);
  const toggle = (id: string) =>
    setExpanded((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const renderDependency = (
    dependency: MavenDependency,
    id: string,
    depth: number,
  ): React.ReactNode => (
    <div key={id}>
      <SidebarTreeRow
        depth={depth}
        variant="idea"
        label={dependency.artifactId}
        description={mavenDependencySubtitle(dependency, t)}
        leading={<PackageIcon />}
        expanded={dependency.children.length ? expanded.has(id) : undefined}
        onToggle={() => toggle(id)}
        onClick={() => {
          if (dependency.children.length) toggle(id);
        }}
        onDoubleClick={() => {
          if (!root || !project) return;
          void useFileSystemStore
            .getState()
            .handleFileSelect(
              mavenModulePomPath(root, project.relativePath, dependency.modulePath),
              false,
            );
        }}
      />
      {expanded.has(id) &&
        dependency.children.map((child, index) =>
          renderDependency(child, `${id}:${index}`, depth + 1),
        )}
    </div>
  );
  const modules: MavenModule[] = [];
  const collect = (items: MavenModule[]) => {
    for (const item of items) {
      modules.push(item);
      collect(item.modules);
    }
  };
  if (project) collect(project.modules);
  const roots = project
    ? [
        { relativePath: ".", artifactId: project.artifactId },
        ...modules.filter((module) => module.relativePath !== project.relativePath),
      ]
    : [];
  return (
    <div
      className="min-h-0 flex-1 overflow-auto"
      role="tree"
      aria-label={t("project.dependencies")}
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
      onContextMenu={(event) => event.stopPropagation()}
    >
      {!roots.length && (
        <div className="p-3 ui-text-sm text-subtle-foreground">{t("maven.noDependencies")}</div>
      )}
      {roots.map((module) => {
        const load = loads[module.relativePath];
        const open = () => toggle(module.relativePath);
        return (
          <div key={module.relativePath}>
            <SidebarTreeRow
              depth={0}
              variant="idea"
              label={module.artifactId}
              leading={<FolderIcon />}
              expanded={expanded.has(module.relativePath)}
              onToggle={open}
              onClick={open}
            />
            {expanded.has(module.relativePath) &&
              (load?.status === "ready" ? (
                load.dependencies.map((dependency, index) =>
                  renderDependency(dependency, `${module.relativePath}:${index}`, 1),
                )
              ) : (
                <div className="px-6 py-2 ui-text-sm">
                  {load?.error ||
                    t(
                      load?.status === "loading"
                        ? "maven.dependencyLoading"
                        : "project.dependenciesHint",
                    )}
                  <button
                    type="button"
                    className="ml-2 text-primary"
                    onClick={() =>
                      void (load?.status === "loading"
                        ? actions.cancelDependencies(module.relativePath)
                        : actions.loadDependencies(module.relativePath))
                    }
                  >
                    {t(
                      load?.status === "loading"
                        ? "ui.cancel"
                        : load?.error
                          ? "ui.retry"
                          : "project.resolveDependencies",
                    )}
                  </button>
                </div>
              ))}
          </div>
        );
      })}
    </div>
  );
}
