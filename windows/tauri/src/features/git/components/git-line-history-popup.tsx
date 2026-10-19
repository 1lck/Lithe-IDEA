import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cancelCoreOperation } from "@/core/lithe-core-client";
import { getGitLineHistory } from "../api/git-line-history-api";
import type { GitLineHistory, GitLineHistoryCommit } from "../types/git.types";
import { openCommitDiffBuffer } from "../utils/open-commit-diff-buffer";

const POPUP_WIDTH = 420;
const POPUP_MAX_HEIGHT = 360;

interface GitLineHistoryPopupProps {
  rootPath: string;
  filePath: string;
  /** Editor buffer content captured when the query started. */
  content: string;
  range: { startLine: number; endLine: number };
  anchor: { x: number; y: number };
  onClose: () => void;
}

type LineHistoryStatus = "loading" | "ready" | "failed";

/**
 * Line-history popover for one gutter query. A generation token plus the
 * core operation cancel keep late results from reopening this surface after
 * the user closed it or switched files.
 */
export default function GitLineHistoryPopup({
  rootPath,
  filePath,
  content,
  range,
  anchor,
  onClose,
}: GitLineHistoryPopupProps) {
  const { t } = useTranslation();
  const generationRef = useRef(0);
  const operationRef = useRef<string | null>(null);
  const [status, setStatus] = useState<LineHistoryStatus>("loading");
  const [history, setHistory] = useState<GitLineHistory | null>(null);
  // Nested repositories resolve to their own root; entries must open there,
  // not in the workspace root that merely contains them.
  const [resolvedRepoPath, setResolvedRepoPath] = useState<string>(rootPath);
  const [retryCount, setRetryCount] = useState(0);

  useEffect(() => {
    const generation = ++generationRef.current;
    const operationId = crypto.randomUUID();
    operationRef.current = operationId;
    setStatus("loading");
    setHistory(null);

    setResolvedRepoPath(rootPath);
    void getGitLineHistory({
      rootPath,
      filePath,
      content,
      startLine: range.startLine,
      endLine: range.endLine,
      operationId,
      isCancelled: () => generationRef.current !== generation,
    }).then((result) => {
      // Drop results that landed after closing or re-opening the popup.
      if (generationRef.current !== generation) return;
      if (result) {
        setHistory(result.history);
        setResolvedRepoPath(result.repoPath);
        setStatus("ready");
      } else {
        setStatus("failed");
      }
    });

    return () => {
      generationRef.current += 1;
      const pending = operationRef.current;
      operationRef.current = null;
      if (pending) void cancelCoreOperation(pending);
    };
    // The snapshot is pinned per query; content changes and retries re-run the
    // effect and invalidate the previous generation.
  }, [rootPath, filePath, content, range.startLine, range.endLine, retryCount]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  const openEntry = async (entry: GitLineHistoryCommit) => {
    const firstRange = entry.relevantRanges[0];
    await openCommitDiffBuffer({
      repoPath: resolvedRepoPath,
      commitHash: entry.hash,
      message: entry.subject,
      author: entry.authorName,
      date: new Date(entry.authorTime * 1000).toLocaleString(),
      // Rename-with-edit commits need both path sides or the pathspec clips
      // the pairing into a synthetic whole-file addition.
      pathspecs: entry.previousPath
        ? [entry.previousPath, entry.pathAtCommit]
        : [entry.pathAtCommit],
      compareReference:
        entry.kind === "merge-first-parent"
          ? `${entry.compareBase}..${entry.hash}`
          : undefined,
      initialRevealRange: firstRange
        ? { startLine: firstRange.newStart, endLine: firstRange.newEnd }
        : undefined,
    });
    onClose();
  };

  const title =
    range.startLine === range.endLine
      ? t("git.lineHistory.titleLine", { line: range.startLine })
      : t("git.lineHistory.titleRange", {
          start: range.startLine,
          end: range.endLine,
        });

  const left = Math.max(8, Math.min(anchor.x, window.innerWidth - POPUP_WIDTH - 8));
  const top = Math.min(anchor.y, Math.max(8, window.innerHeight - POPUP_MAX_HEIGHT - 8));

  return (
    <>
      <div className="fixed inset-0 z-[90]" onMouseDown={onClose} data-line-history-backdrop />
      <div
        className="fixed z-[91] flex w-(--popup-width) flex-col overflow-hidden rounded-lg bg-popover text-popover-foreground shadow-md ring-1 ring-foreground/10"
        style={{ "--popup-width": `${POPUP_WIDTH}px`, left, top } as React.CSSProperties}
        role="dialog"
        aria-label={title}
      >
        <div className="flex items-center gap-2 border-b px-3 py-2 text-xs font-medium opacity-80">
          <span className="truncate">{title}</span>
          <span className="ml-auto truncate opacity-60">{filePath}</span>
        </div>
        <div className="max-h-(--popup-max-height) overflow-y-auto" style={{ "--popup-max-height": `${POPUP_MAX_HEIGHT - 33}px` } as React.CSSProperties}>
          {status === "loading" ? (
            <div className="px-3 py-4 text-xs opacity-60">{t("git.lineHistory.loading")}</div>
          ) : status === "failed" ? (
            <div className="flex items-center gap-2 px-3 py-4 text-xs">
              <span className="opacity-70">{t("git.lineHistory.failed")}</span>
              <button
                type="button"
                className="rounded px-2 py-0.5 ring-1 ring-foreground/20 hover:bg-foreground/5"
                onClick={() => setRetryCount((count) => count + 1)}
              >
                {t("git.lineHistory.retry")}
              </button>
            </div>
          ) : (
            <div className="flex flex-col py-1 text-xs">
              {history?.unmappedLines.map((unmapped) => (
                <div
                  key={`unmapped-${unmapped.line}`}
                  className="px-3 py-1.5 opacity-70"
                  data-line-history-unmapped={unmapped.kind}
                >
                  {t(`git.lineHistory.unmapped.${unmapped.kind}`, { line: unmapped.line })}
                </div>
              ))}
              {history?.commits.length === 0 && history.unmappedLines.length === 0 ? (
                <div className="px-3 py-4 opacity-60">{t("git.lineHistory.empty")}</div>
              ) : null}
              {history?.commits.map((entry) => (
                <button
                  key={entry.hash}
                  type="button"
                  className="flex flex-col items-start gap-0.5 px-3 py-1.5 text-left hover:bg-foreground/5"
                  onClick={() => void openEntry(entry)}
                  data-line-history-entry={entry.hash}
                >
                  <span className="flex w-full items-center gap-2">
                    <span className="font-mono opacity-60">{entry.hash.substring(0, 7)}</span>
                    {entry.kind === "merge-first-parent" ? (
                      <span
                        className="rounded bg-foreground/10 px-1 py-px text-[10px]"
                        data-line-history-merge
                      >
                        {t("git.lineHistory.mergeBadge")}
                      </span>
                    ) : null}
                    <span className="ml-auto shrink-0 opacity-50">
                      {new Date(entry.authorTime * 1000).toLocaleDateString()}
                    </span>
                  </span>
                  <span className="line-clamp-2 w-full">{entry.subject}</span>
                  <span className="w-full truncate opacity-50">
                    {entry.previousPath
                      ? `${entry.previousPath} → ${entry.pathAtCommit}`
                      : `${entry.authorName}`}
                  </span>
                </button>
              ))}
              {history?.truncated ? (
                <div className="border-t px-3 py-1.5 opacity-60" data-line-history-truncated>
                  {t("git.lineHistory.truncated", { count: history.commits.length })}
                </div>
              ) : null}
              {history && history.commits.length > 0 ? (
                <button
                  type="button"
                  className="border-t px-3 py-1.5 text-left opacity-70 hover:bg-foreground/5"
                  data-line-history-whole-commit
                  onClick={() => {
                    const newest = history.commits[0];
                    void openCommitDiffBuffer({
                      repoPath: resolvedRepoPath,
                      commitHash: newest.hash,
                      message: newest.subject,
                      author: newest.authorName,
                      date: new Date(newest.authorTime * 1000).toLocaleString(),
                    });
                    onClose();
                  }}
                >
                  {t("git.lineHistory.viewCommit")}
                </button>
              ) : null}
            </div>
          )}
        </div>
      </div>
    </>
  );
}
