import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useRef, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { getNativeWorkspaceRootPaths } from "@/features/file-search/utils/file-search-paths";
import { closestWorkspaceRoot } from "@/features/workspace/types/workspace-root";
import { useWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { markWorkspaceDirectory } from "@/features/file-explorer/stores/directory-marks";
import {
  queryIgnoredDirectorySuggestions,
  readIndexingSettings,
  writeIndexingSettings,
  useIndexingVersion,
  type IgnoredDirectorySuggestions,
} from "@/features/file-explorer/stores/workspace-indexing";
import { useTranslation } from "@/i18n/locale-provider";
import { Alert, AlertDescription } from "@/ui/alert";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Checkbox } from "@/ui/checkbox";

function DirectoryChoices({
  paths,
  selected,
  onChange,
}: {
  paths: string[];
  selected: Set<string>;
  onChange: (paths: Set<string>) => void;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: paths.length,
    getScrollElement: () => viewport.current,
    estimateSize: () => 28,
    overscan: 5,
    getItemKey: (index) => paths[index],
  });
  return (
    <div ref={viewport} className="h-70 overflow-auto">
      <div style={{ height: virtualizer.getTotalSize(), position: "relative" }}>
        {virtualizer.getVirtualItems().map((row) => (
          <div
            key={row.key}
            className="absolute left-0 flex w-full items-center gap-2 text-xs"
            style={{ height: row.size, transform: `translateY(${row.start}px)` }}
          >
            <Checkbox
              aria-label={paths[row.index]}
              checked={selected.has(paths[row.index])}
              onCheckedChange={(checked) => {
                const next = new Set(selected);
                if (checked) next.add(paths[row.index]);
                else next.delete(paths[row.index]);
                onChange(next);
              }}
            />
            <span className="truncate" title={paths[row.index]}>
              {paths[row.index]}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

/** The editor inspects on open; only the explicit Exclude action writes project preferences. */
export function IgnoredDirectoryNotice({ filePath }: { filePath?: string | null }) {
  const { t } = useTranslation();
  const workspaceId = useWorkspaceId();
  const primaryRoot = useFileSystemStore((state) => state.rootFolderPath);
  const folders = useFileSystemStore((state) => state.workspaceFolders);
  const roots = getNativeWorkspaceRootPaths(primaryRoot, folders);
  const rootsKey = JSON.stringify(roots);
  const root = filePath ? closestWorkspaceRoot(filePath, roots) : undefined;
  const isIgnoreFile = filePath?.replace(/\\/g, "/").split("/").pop() === ".gitignore";
  const version = useIndexingVersion(root ? [root] : []);
  const [retry, setRetry] = useState(0);
  const [result, setResult] = useState<IgnoredDirectorySuggestions | null>(null);
  const [failed, setFailed] = useState(false);
  const [open, setOpen] = useState(false);
  const [applying, setApplying] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const identity = `${workspaceId}\0${root}\0${filePath}\0${rootsKey}`;
  const currentIdentity = useRef(identity);
  currentIdentity.current = identity;

  useEffect(() => {
    let current = true;
    setResult(null);
    setFailed(false);
    setOpen(false);
    setApplying(false);
    if (!root || !isIgnoreFile) return;
    void (async () => {
      try {
        if (readIndexingSettings(root).ignoredDirectoryNoticeDismissed) return;
        const suggestions = await queryIgnoredDirectorySuggestions(
          root,
          workspaceId,
          JSON.parse(rootsKey),
        );
        if (current) setResult(suggestions);
      } catch {
        if (current) setFailed(true);
      }
    })();
    return () => {
      current = false;
    };
  }, [root, rootsKey, workspaceId, filePath, isIgnoreFile, version, retry]);

  if (
    !root ||
    !isIgnoreFile ||
    (!failed && !result?.directories.length && !result?.incomplete && !result?.gitIgnoreFailed)
  )
    return null;
  const partial = result?.incomplete || result?.gitIgnoreFailed;
  const exclude = async () => {
    const captured = identity;
    setApplying(true);
    try {
      const fresh = await queryIgnoredDirectorySuggestions(root, workspaceId, roots);
      if (
        currentIdentity.current !== captured ||
        !workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)
      )
        return;
      for (const path of fresh.directories) {
        if (selected.has(path))
          markWorkspaceDirectory([root], `${root}/${path}`, { kind: "exclude" });
      }
      setOpen(false);
      setRetry((value) => value + 1);
    } catch {
      if (currentIdentity.current === captured) setFailed(true);
    } finally {
      if (currentIdentity.current === captured) setApplying(false);
    }
  };

  return (
    <>
      <Alert
        tone={failed || partial ? "warning" : "info"}
        className="rounded-none border-x-0 border-t-0 py-2"
        data-testid="ignored-directory-notice"
      >
        <AlertDescription className="flex items-center gap-3">
          <span className="flex-1">
            {t(
              failed
                ? "indexing.noticeFailed"
                : result?.directories.length
                  ? "indexing.notice"
                  : "indexing.noticeIncomplete",
            )}
          </span>
          {failed ? (
            <Button size="xs" onClick={() => setRetry((value) => value + 1)}>
              {t("ui.retry")}
            </Button>
          ) : (
            <>
              {!!result?.directories.length && (
                <Button
                  size="xs"
                  onClick={() => {
                    setSelected(new Set(result.directories));
                    setOpen(true);
                  }}
                >
                  {t("indexing.viewDirectories")}
                </Button>
              )}
              <Button
                size="xs"
                onClick={() => {
                  try {
                    writeIndexingSettings(root, {
                      ...readIndexingSettings(root),
                      ignoredDirectoryNoticeDismissed: true,
                    });
                  } catch {
                    setFailed(true);
                  }
                }}
              >
                {t("indexing.dismissNotice")}
              </Button>
              <span
                title={t("indexing.noticeHelp")}
                tabIndex={0}
                aria-label={t("indexing.noticeHelp")}
              >
                ⓘ
              </span>
            </>
          )}
        </AlertDescription>
      </Alert>
      {open && result && (
        <Dialog
          title={t("indexing.ignoredDirectories")}
          onClose={() => {
            if (!applying) setOpen(false);
          }}
          footer={
            <>
              <Button disabled={applying} onClick={() => setOpen(false)}>
                {t("ui.cancel")}
              </Button>
              <Button
                variant="accent"
                disabled={applying || selected.size === 0}
                onClick={() => void exclude()}
              >
                {t("indexing.excludeSelected")}
              </Button>
            </>
          }
        >
          {partial && (
            <Alert tone="warning">
              <AlertDescription>{t("indexing.noticeIncomplete")}</AlertDescription>
            </Alert>
          )}
          {failed && (
            <Alert tone="error">
              <AlertDescription>{t("indexing.writeFailed")}</AlertDescription>
            </Alert>
          )}
          <fieldset disabled={applying}>
            <DirectoryChoices
              paths={result.directories}
              selected={selected}
              onChange={setSelected}
            />
          </fieldset>
        </Dialog>
      )}
    </>
  );
}
