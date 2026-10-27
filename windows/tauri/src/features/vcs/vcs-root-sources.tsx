import { useEffect, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getRelativePath, pathStartsWithRoot } from "@/utils/path-helpers";
import Select from "@/ui/select";
import type { VcsRootController } from "./vcs-root-controller";
import { VcsStatusPanel } from "./vcs-status-panel";

/** A passive source selector in the ordinary Version Control pane.
 * Selecting a plugin root only inspects it; no Git path/action is replaced. */
export function VcsRootSources({ controller }: { controller: VcsRootController }) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(controller.subscribe, controller.getSnapshot);
  const status = useSyncExternalStore(controller.status.subscribe, controller.status.getSnapshot);
  const activeFile = useBufferStore((state) => {
    const buffer = state.buffers.find((buffer) => buffer.id === state.activeBufferId);
    return buffer?.type === "editor" ? buffer.path : null;
  });
  const [selected, setSelected] = useState("");
  const [ownership, setOwnership] = useState<{
    path: string;
    generation: number;
    root: string | null;
    failed: boolean;
  } | null>(null);
  const detection = state.snapshot?.detection;
  const providers =
    detection?.providers.filter((provider) => provider.origin.kind === "plugin") ?? [];
  const hasPlugins = providers.length > 0;
  const relativeFile =
    activeFile && pathStartsWithRoot(activeFile, controller.scope.workspaceRoot)
      ? getRelativePath(activeFile, controller.scope.workspaceRoot)
      : null;
  useEffect(() => {
    setOwnership(null);
    if (!hasPlugins || !state.snapshot || relativeFile === null) return;
    const generation = state.snapshot.generation;
    const controllerAbort = new AbortController();
    void controller.owners([relativeFile], controllerAbort.signal).then(
      (value) => {
        if (!controllerAbort.signal.aborted)
          setOwnership({
            path: relativeFile,
            generation,
            root: value.owners[0]?.root ?? null,
            failed: false,
          });
      },
      () => {
        if (!controllerAbort.signal.aborted)
          setOwnership({ path: relativeFile, generation, root: null, failed: true });
      },
    );
    return () => controllerAbort.abort();
  }, [controller, state.snapshot, relativeFile, hasPlugins]);
  if (!hasPlugins) return null;
  const pluginRoots = detection!.roots.filter((root) =>
    providers.some((provider) => provider.vcs === root.vcs),
  );
  const selectedRoot = pluginRoots.find((root) => `root:${root.id}` === selected) ?? pluginRoots[0];
  const owned =
    ownership?.path === relativeFile && ownership.generation === state.snapshot?.generation
      ? ownership
      : null;
  const ownerRoot =
    owned?.root === null ? null : detection!.roots.find((root) => root.id === owned?.root);
  return (
    <div
      className="shrink-0 space-y-1 border-b border-border p-2 ui-text-sm"
      data-testid="vcs-root-sources"
    >
      <Select
        size="xs"
        value={selectedRoot ? `root:${selectedRoot.id}` : ""}
        disabled={
          status.phase === "loading" ||
          status.phase === "stopping" ||
          status.phase === "cancelFailed"
        }
        onChange={(value) => {
          controller.status.invalidate();
          setSelected(value);
        }}
        aria-label={t("vcs.roots.sources")}
        placeholder={t("vcs.roots.sources")}
        options={pluginRoots.map((root) => ({
          value: `root:${root.id}`,
          label: `${providers.find((provider) => provider.vcs === root.vcs)!.displayName} · ${root.id || root.path}`,
        }))}
      />
      {selectedRoot && <p className="text-subtle-foreground">{t("vcs.roots.passive")}</p>}
      {selectedRoot && <VcsStatusPanel controller={controller} root={selectedRoot} />}
      {detection!.ambiguous.map((directory) => (
        <p key={directory.id} role="status">
          {t("vcs.roots.ambiguous", { path: directory.id || controller.scope.workspaceRoot })}
        </p>
      ))}
      {detection!.truncated && <p role="status">{t("vcs.roots.incomplete")}</p>}
      {relativeFile !== null && (
        <p role="status">
          {owned
            ? owned.failed
              ? t("vcs.roots.ownerUnavailable")
              : ownerRoot
                ? t("vcs.roots.fileOwner", {
                    vcs:
                      detection!.providers.find((provider) => provider.vcs === ownerRoot.vcs)
                        ?.displayName ?? ownerRoot.vcs,
                    path: ownerRoot.id || ownerRoot.path,
                  })
                : t("vcs.roots.noOwner")
            : t("vcs.roots.checkingOwner")}
        </p>
      )}
    </div>
  );
}
