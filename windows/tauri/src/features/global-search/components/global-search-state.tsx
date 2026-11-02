import { MagnifyingGlassIcon as MagnifyingGlass } from "@/ui/icons";
import { Button } from "@/ui/button";
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import type { ContentSearchAvailability } from "../hooks/use-content-search";
import type { ContentSearchFailure } from "../types/global-search.types";

interface GlobalSearchStateProps {
  availability: ContentSearchAvailability;
  query: string;
  debouncedQuery: string;
  busyLabel: string | null;
  showBusy: boolean;
  error: ContentSearchFailure | null;
  hasFileFilters: boolean;
  onRetry: () => void;
}

export function GlobalSearchError({
  error,
  onRetry,
  compact = false,
}: {
  error: ContentSearchFailure;
  onRetry: () => void;
  compact?: boolean;
}) {
  const { t } = useTranslation();
  const message =
    typeof error === "string"
      ? error
      : t(error.kind === "indexing" ? `indexing.${error.code}` : "search.failed");
  if (compact) {
    return (
      <div role="alert" className="flex items-center gap-2 border-b border-border px-3 py-2">
        <p className="min-w-0 flex-1 ui-text-sm text-destructive">{message}</p>
        <Button type="button" variant="ghost" size="sm" onClick={onRetry}>
          {t("search.retry")}
        </Button>
      </div>
    );
  }
  return (
    <Empty className="min-h-60 px-6" role="alert">
      <EmptyHeader>
        <EmptyTitle>{t("search.failed")}</EmptyTitle>
        <EmptyDescription className="ui-text-base text-destructive">{message}</EmptyDescription>
      </EmptyHeader>
      <EmptyContent>
        <Button type="button" variant="default" onClick={onRetry}>
          {t("search.retry")}
        </Button>
      </EmptyContent>
    </Empty>
  );
}

function SearchIntroduction({ title, description }: { title: string; description: string }) {
  return (
    <Empty className="h-full min-h-80 px-6">
      <EmptyHeader>
        <EmptyMedia variant="icon" className="size-11 border border-border bg-surface">
          <MagnifyingGlass className="size-6" weight="duotone" />
        </EmptyMedia>
        <EmptyTitle>{title}</EmptyTitle>
        <EmptyDescription className="ui-text-base">{description}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}

export function GlobalSearchState({
  availability,
  query,
  debouncedQuery,
  busyLabel,
  showBusy,
  error,
  hasFileFilters,
  onRetry,
}: GlobalSearchStateProps) {
  const { t } = useTranslation();

  if (availability === "no-workspace") {
    return (
      <SearchIntroduction
        title={t("search.openProjectTitle")}
        description={t("search.openProjectDescription")}
      />
    );
  }

  if (availability === "unsupported") {
    return (
      <Empty className="min-h-60 px-6">
        <EmptyDescription className="ui-text-base">{t("search.unsupported")}</EmptyDescription>
      </Empty>
    );
  }

  if (!query.trim()) {
    return (
      <SearchIntroduction
        title={t("search.emptyTitle")}
        description={t("search.emptyDescription")}
      />
    );
  }

  if (showBusy && busyLabel) {
    return (
      <Empty className="min-h-60" role="status" aria-live="polite">
        <EmptyDescription className="ui-text-base">{busyLabel}</EmptyDescription>
      </Empty>
    );
  }

  if (error) {
    return <GlobalSearchError error={error} onRetry={onRetry} />;
  }

  if (debouncedQuery.trim()) {
    return (
      <Empty className="min-h-60" role="status">
        <EmptyHeader>
          <EmptyTitle>{t("search.noResults")}</EmptyTitle>
          <EmptyDescription className="ui-text-base">
            {t(hasFileFilters ? "search.noResultsForWithFilters" : "search.noResultsFor", {
              query: debouncedQuery,
            })}
          </EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }

  return null;
}
