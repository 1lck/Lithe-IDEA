import { useTranslation } from "@/i18n/locale-provider";
import { Progress } from "@/ui/progress";
import { useGitConsoleStore } from "../stores/git-console.store";

/** Like IDEA's compact status indicator, each percentage belongs to one phase. */
export function GitFetchStatus() {
  const { t } = useTranslation();
  const fetches = useGitConsoleStore((state) => state.fetches);
  const fetch = fetches[fetches.length - 1];
  if (!fetch) return null;
  const percent = fetch.phase?.percent ?? null;
  const phase = fetch.phase ? t(`git.execution.phase.${fetch.phase.stage}`) : "";
  const label = `${t("git.fetching")}${fetches.length > 1 ? ` (${fetches.length})` : ""}`;
  const description = [label, fetch.root, phase, percent === null ? "" : `${percent}%`]
    .filter(Boolean)
    .join(" · ");
  return (
    <div className="flex min-w-0 shrink items-center gap-2 ui-text-chrome" title={description}>
      <span className="max-w-48 truncate text-subtle-foreground">
        {label}
        {phase ? `: ${phase}` : ""}
      </span>
      <Progress
        aria-label={description}
        getAriaValueText={() => description}
        value={percent}
        className="lithe-git-fetch-progress w-[104px] shrink-0 [&_[data-slot=progress-track]]:bg-border"
      />
    </div>
  );
}
