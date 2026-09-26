import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/dialog";
import Badge from "@/ui/badge";
import { RadioGroup, RadioGroupItem } from "@/ui/radio-group";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import { CaretDownIcon, CaretRightIcon, WarningCircleIcon as WarningCircle } from "@/ui/icons";
import { cn } from "@/utils/cn";
import { getGitReferencesAtRoot } from "../api/git-commits-api";
import { getGitPullWorkflow, getPullPreflight } from "../api/git-remotes-api";
import {
  attachGitPullDialogHost,
  type GitPullDialogRequest,
  type GitPullDialogResult,
} from "../services/git-pull-dialog-service";
import type { GitPullPreflight, GitPullResult, GitReference, PullStrategy } from "../types/git.types";
import { getGitPullResultPresentation } from "../utils/git-pull-result-presentation";
import {
  canUseFastForward,
  defaultPullReference,
  defaultPullStrategy,
  isUpstreamPullTarget,
} from "../utils/git-pull-selection";

type LoadState = "loading" | "ready" | "failed";

const toDialogStatus = (result: GitPullResult): GitPullDialogResult["status"] => {
  switch (result.status) {
    case "pulled":
      return "pulled";
    case "blocked":
      return "blocked";
    case "conflict":
      return "conflict";
    case "failed":
      return "failed";
    default:
      return "cancelled";
  }
};

const Str = (value: unknown): string => (typeof value === "string" ? value : String(value));

function GitPullDialog({
  request,
  onComplete,
}: {
  request: GitPullDialogRequest;
  onComplete: (result: GitPullDialogResult) => void;
}) {
  const { t } = useTranslation();
  const [loadState, setLoadState] = useState<LoadState>("loading");
  const [loadError, setLoadError] = useState<string | null>(null);
  const [preflight, setPreflight] = useState<GitPullPreflight | null>(null);
  const [references, setReferences] = useState<GitReference[]>([]);
  const [selectedFullName, setSelectedFullName] = useState<string | null>(null);
  const [strategy, setStrategy] = useState<PullStrategy>("merge");
  const [isStrategyExpanded, setIsStrategyExpanded] = useState(false);
  const [isPulling, setIsPulling] = useState(false);

  const load = useCallback(async () => {
    setLoadState("loading");
    setLoadError(null);
    try {
      const [nextPreflight, snapshot] = await Promise.all([
        getPullPreflight(request.repoPath),
        getGitReferencesAtRoot(request.repoPath, `pull-dialog-${request.id}`).catch(() => null),
      ]);
      const branches = [
        ...new Map(
          (snapshot?.references ?? [])
            .filter((reference) => reference.kind === "remote")
            .map((reference) => [reference.fullName, reference] as const),
        ).values(),
      ].sort((left, right) => left.shortName.localeCompare(right.shortName));

      setPreflight(nextPreflight);
      setReferences(branches);
      const initial = defaultPullReference(branches, nextPreflight);
      setSelectedFullName(initial?.fullName ?? null);
      setStrategy(defaultPullStrategy());
      setLoadState("ready");
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : String(error));
      setLoadState("failed");
    }
  }, [request]);

  useEffect(() => {
    void load();
  }, [load]);

  const selectedReference = useMemo(
    () => references.find((reference) => reference.fullName === selectedFullName) ?? null,
    [references, selectedFullName],
  );
  const isUpstream = !!preflight && isUpstreamPullTarget(selectedReference, preflight);
  const fastForwardValid = !!preflight && canUseFastForward(preflight, selectedReference);

  const branchOptions = useMemo(
    () =>
      references.map((reference) => ({
        value: reference.fullName,
        label: reference.shortName,
        accessory:
          !!preflight && isUpstreamPullTarget(reference, preflight) ? (
            <Badge variant="accent" size="compact" className="shrink-0">
              {t("git.pullDialog.upstreamBadge")}
            </Badge>
          ) : undefined,
      })),
    [references, preflight, t],
  );

  const ahead = isUpstream ? (preflight?.ahead ?? 0) : (selectedReference?.ahead ?? null);
  const behind = isUpstream ? (preflight?.behind ?? 0) : (selectedReference?.behind ?? null);
  const hasAheadBehind = ahead !== null && behind !== null;

  const strategyOptions = useMemo<
    Array<{ value: PullStrategy; label: string; description: string; disabled: boolean }>
  >(
    () => [
      {
        value: "ffOnly",
        label: t("git.pullDialog.strategy.ffOnly"),
        description: t("git.pullDialog.strategy.ffOnlyHint"),
        disabled: !fastForwardValid,
      },
      {
        value: "merge",
        label: t("git.merge"),
        description: t("git.pullDialog.strategy.mergeHint"),
        disabled: false,
      },
      {
        value: "rebase",
        label: t("git.rebase"),
        description: t("git.pullDialog.strategy.rebaseHint"),
        disabled: false,
      },
    ],
    [fastForwardValid, t],
  );

  const selectedStrategyLabel =
    strategyOptions.find((option) => option.value === strategy)?.label ?? "";

  const chooseReference = (fullName: string) => {
    setSelectedFullName(fullName);
    const nextReference = references.find((reference) => reference.fullName === fullName) ?? null;
    if (preflight && strategy === "ffOnly" && !canUseFastForward(preflight, nextReference)) {
      setStrategy("merge");
    }
  };

  const submit = async () => {
    if (isPulling || !selectedReference || !preflight) return;
    setIsPulling(true);
    try {
      const workflow = getGitPullWorkflow(request.repoPath);
      const result = await workflow.run(request.repoPath, {
        refresh: request.refresh ?? (async () => {}),
        strategy,
        ...(isUpstream ? {} : { reference: selectedReference }),
      });
      const presentation = getGitPullResultPresentation(result, t);
      if (presentation) toast[presentation.tone](presentation.message);
      onComplete({ status: toDialogStatus(result) });
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t("git.operationFailed"));
      onComplete({ status: "failed" });
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !isPulling) onComplete({ status: "cancelled" });
      }}
    >
      <DialogContent
        size="sm"
        showCloseButton={false}
        className="max-w-md p-0"
        data-testid="git-pull-dialog"
      >
        <DialogHeader className="px-4 pt-4">
          <DialogTitle>{t("git.pullDialog.title")}</DialogTitle>
          <DialogDescription className="text-subtle-foreground ui-text-sm">
            {t("git.pullDialog.description")}
          </DialogDescription>
        </DialogHeader>

        {loadState === "loading" ? (
          <div className="flex items-center justify-center gap-2 px-4 py-8 text-subtle-foreground ui-text-sm">
            <Spinner compact />
            {t("git.pullDialog.loading")}
          </div>
        ) : loadState === "failed" ? (
          <div className="flex items-start gap-2 px-4 py-6 text-destructive ui-text-sm">
            <WarningCircle className="mt-0.5 size-4 shrink-0" />
            <span>{loadError || t("git.pullDialog.loadFailed")}</span>
          </div>
        ) : (
          <div className="space-y-4 px-4 py-3">
            <div className="space-y-1.5">
              <label className="block font-medium ui-text-sm" htmlFor="git-pull-from">
                {t("git.pullDialog.from")}
              </label>
              {branchOptions.length > 0 ? (
                <Select
                  id="git-pull-from"
                  value={selectedFullName ?? ""}
                  options={branchOptions}
                  onChange={chooseReference}
                  placeholder={t("git.pullDialog.fromPlaceholder")}
                  disabled={isPulling}
                  searchable
                  size="sm"
                  className="w-full"
                  openDirection="down"
                  aria-label={t("git.pullDialog.from")}
                />
              ) : (
                <p className="text-subtle-foreground ui-text-sm">{t("git.pullDialog.noBranches")}</p>
              )}
              {hasAheadBehind ? (
                <div className="grid grid-cols-2 gap-2 pt-1">
                  <div className="rounded-md border border-border bg-raised px-3 py-2">
                    <div className="ui-text-xs text-subtle-foreground">{t("git.localAhead")}</div>
                    <div className="font-semibold">{ahead}</div>
                  </div>
                  <div className="rounded-md border border-border bg-raised px-3 py-2">
                    <div className="ui-text-xs text-subtle-foreground">{t("git.remoteAhead")}</div>
                    <div className="font-semibold">{behind}</div>
                  </div>
                </div>
              ) : null}
            </div>

            <div className="space-y-1.5">
              <button
                type="button"
                onClick={() => setIsStrategyExpanded((expanded) => !expanded)}
                aria-expanded={isStrategyExpanded}
                className="flex h-8 w-full items-center gap-1.5 rounded-md border border-border px-3 text-left font-medium ui-text-sm hover:bg-accent/60"
              >
                {isStrategyExpanded ? (
                  <CaretDownIcon className="size-3.5 shrink-0 text-subtle-foreground" />
                ) : (
                  <CaretRightIcon className="size-3.5 shrink-0 text-subtle-foreground" />
                )}
                {t("git.pullDialog.strategySummary", { strategy: selectedStrategyLabel })}
              </button>
              {isStrategyExpanded ? (
                <RadioGroup
                  value={strategy}
                  onValueChange={(value) => setStrategy(Str(value) as PullStrategy)}
                  className="gap-1.5"
                >
                  {strategyOptions.map((option) => (
                    <label
                      key={option.value}
                      className={cn(
                        "flex cursor-pointer items-start gap-2 rounded-md border border-border px-3 py-2",
                        option.disabled ? "cursor-not-allowed opacity-50" : "hover:bg-accent/60",
                        strategy === option.value && "border-primary/40 bg-selected/60",
                      )}
                    >
                      <RadioGroupItem
                        value={option.value}
                        disabled={option.disabled || isPulling}
                        className="mt-0.5"
                      />
                      <span className="min-w-0">
                        <span className="block ui-text-sm">{option.label}</span>
                        <span className="block ui-text-xs text-subtle-foreground">
                          {option.description}
                        </span>
                      </span>
                    </label>
                  ))}
                </RadioGroup>
              ) : null}
            </div>

            {preflight?.hasLocalChanges ? (
              <p className="flex items-start gap-2 text-warning ui-text-xs">
                <WarningCircle className="mt-0.5 size-3.5 shrink-0" />
                {t("git.pullDialog.localChanges")}
              </p>
            ) : null}
          </div>
        )}

        <DialogFooter>
          <Button variant="ghost" size="xs" disabled={isPulling} onClick={() => onComplete({ status: "cancelled" })}>
            {t("ui.cancel")}
          </Button>
          <Button
            variant="accent"
            size="xs"
            disabled={
              isPulling ||
              loadState !== "ready" ||
              !selectedReference ||
              !preflight ||
              references.length === 0
            }
            onClick={() => void submit()}
          >
            {t("git.pullDialog.pull")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** Owns the single Pull dialog for every Git surface that triggers a pull. */
export function GitPullDialogHost() {
  const [queue, setQueue] = useState<GitPullDialogRequest[]>([]);

  useEffect(
    () => attachGitPullDialogHost((request) => setQueue((current) => [...current, request])),
    [],
  );

  const activeRequest = queue[0] ?? null;
  if (!activeRequest) return null;

  return (
    <GitPullDialog
      key={activeRequest.id}
      request={activeRequest}
      onComplete={(result) => {
        activeRequest.resolve(result);
        setQueue((current) => current.slice(1));
      }}
    />
  );
}
