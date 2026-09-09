import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { Button } from "@/ui/button";
import { showConfirmDialog } from "@/ui/dialog";
import {
  getGitRepositorySetup,
  initializeGitRepository,
  type GitRepositorySetup,
} from "../api/git-setup-api";
import { useRepositoryStore } from "../stores/git-repository.store";

export function GitRepositoryEmptyState({
  root,
  historyError,
  onRefresh,
}: {
  root: string;
  historyError?: string | null;
  onRefresh: () => Promise<unknown>;
}) {
  const { t } = useTranslation();
  const [state, setState] = useState<GitRepositorySetup | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(true);
  const [reload, setReload] = useState(0);
  const generation = useRef(0);
  const currentRoot = useRef(root);
  currentRoot.current = root;
  const openSettings = useUIState((state) => state.openSettingsDialog);
  function openChanges() {
    const ui = useUIState.getState();
    ui.setIsSidebarVisible(true);
    ui.setActiveView("git");
    window.dispatchEvent(new CustomEvent("lithe:git-palette-action", {
      detail: { type: "show-tab", tab: "changes" },
    }));
  }

  useEffect(() => {
    const request = ++generation.current;
    setState(null);
    setError(null);
    setBusy(true);
    void getGitRepositorySetup(root)
      .then((result) => {
        if (request === generation.current && currentRoot.current === root) setState(result);
      })
      .catch((failure: unknown) => {
        if (request === generation.current && currentRoot.current === root)
          setError(String(failure));
      })
      .finally(() => {
        if (request === generation.current && currentRoot.current === root) setBusy(false);
      });
    return () => {
      generation.current++;
    };
  }, [root, reload]);

  async function initialize() {
    if (busy || state?.isRepository !== false) return;
    const request = ++generation.current;
    setBusy(true);
    try {
      const confirmed = await showConfirmDialog(
        `${root}\n\n${t("git.setup.initializeDescription")}`,
        {
          title: t("git.setup.initializeTitle"),
          confirmLabel: t("git.setup.initialize"),
          cancelLabel: t("ui.cancel"),
        },
      );
      if (!confirmed || request !== generation.current || currentRoot.current !== root) return;
      const result = await initializeGitRepository(root);
      if (request !== generation.current || currentRoot.current !== root) return;
      setState(result);
      setError(null);
      await useRepositoryStore.getState().actions.refreshWorkspaceRepositories();
      if (request === generation.current && currentRoot.current === root) await onRefresh();
    } catch (failure) {
      if (request === generation.current && currentRoot.current === root) setError(String(failure));
    } finally {
      if (request === generation.current && currentRoot.current === root) setBusy(false);
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-3 p-6 text-center ui-text-sm text-subtle-foreground">
      {busy ? (
        <p role="status">{t("git.setup.loading")}</p>
      ) : (
        state && (
          <>
            <p className="font-medium text-foreground">
              {t(
                !state.isRepository
                  ? "git.setup.notRepository"
                  : !state.hasCommits
                    ? "git.setup.noCommits"
                    : "git.log.noMatch",
              )}
            </p>
            {!state.isRepository && (
              <>
                <p>{t("git.setup.initializeHint")}</p>
                <Button size="xs" onClick={() => void initialize()}>
                  {t("git.setup.initialize")}
                </Button>
              </>
            )}
            {state.isRepository && !state.hasCommits && (
              <>
                {state.branch && <p>{state.branch}</p>}
                <p>{t("git.setup.firstCommit")}</p>
                {(!state.effectiveName?.trim() || !state.effectiveEmail?.trim()) && (
                  <p>{t("git.setup.missingIdentity")}</p>
                )}
                <Button size="xs" onClick={() => openChanges()}>
                  {t("git.setup.openChanges")}
                </Button>
              </>
            )}
            {(!state.isRepository || !state.hasCommits) && (
              <Button size="xs" variant="ghost" onClick={() => openSettings("git")}>
                {t("git.setup.openSettings")}
              </Button>
            )}
          </>
        )
      )}
      {(error || (state?.hasCommits && historyError)) && (
        <p role="alert" className="text-destructive">
          {error ?? historyError}
        </p>
      )}
      {!busy && (
        <Button
          size="xs"
          variant="ghost"
          onClick={() => {
            setReload((value) => value + 1);
            void onRefresh();
          }}
        >
          {t("git.log.retry")}
        </Button>
      )}
    </div>
  );
}
