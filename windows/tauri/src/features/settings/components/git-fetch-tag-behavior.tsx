import { useTranslation } from "@/i18n/locale-provider";

/** Core supplies the effective result; this component only localizes it. */
export type GitResolvedTagBehavior = {
  value: "reachable" | "all" | "none" | "prune" | "custom" | "remoteDependent" | "unavailable";
  source: { scope: string; origin: string } | null;
  basis: "git" | "lithe" | "multiple";
  reasonCode: "noRemotes" | "invalidConfiguration" | null;
};

export function GitFetchTagBehavior({ behavior }: { behavior: GitResolvedTagBehavior }) {
  const { t } = useTranslation();
  const key = behavior.value === "unavailable" && behavior.reasonCode === "noRemotes"
    ? "noRemotes" : behavior.value;
  const labels: Record<typeof key, string> = {
    reachable: "git.fetch.behavior.reachable",
    all: "git.fetch.tags.all",
    none: "git.fetch.tags.none",
    prune: "git.fetch.tags.prune",
    custom: "git.fetch.behavior.custom",
    remoteDependent: "git.fetch.behavior.remoteDependent",
    unavailable: "git.fetch.behavior.unavailable",
    noRemotes: "git.fetch.behavior.noRemotes",
  };
  const scopes: Record<string, string> = {
    local: "git.fetch.behavior.source.local",
    global: "git.fetch.behavior.source.global",
    system: "git.fetch.behavior.source.system",
    worktree: "git.fetch.behavior.source.worktree",
    command: "git.fetch.behavior.source.command",
  };
  const source = behavior.source
    ? (scopes[behavior.source.scope] ?? "git.fetch.behavior.source.unknown")
    : behavior.value === "unavailable" ? "git.fetch.behavior.source.unknown"
      : behavior.basis === "multiple" ? "git.fetch.behavior.source.multiple"
      : behavior.basis === "lithe" ? "git.fetch.behavior.source.lithe" : "git.fetch.behavior.source.git";
  return <p>{t("git.fetch.tags")}: {t(labels[key])} · {t(source)}{behavior.source?.origin ? ` · ${behavior.source.origin}` : null}</p>;
}
