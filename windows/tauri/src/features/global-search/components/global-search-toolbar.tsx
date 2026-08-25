import { memo, type KeyboardEventHandler, type RefObject } from "react";
import { MagnifyingGlassIcon as MagnifyingGlass, XIcon as X } from "@/ui/icons";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { CommandInput } from "@/ui/command";
import { useTranslation } from "@/i18n/locale-provider";
import { SEARCH_TOGGLE_ICONS, SearchReplaceRow, SearchReplaceToggle } from "@/ui/search";
import { ToggleGroup, type ToggleGroupOption } from "@/ui/toggle-group";
import type { ContentSearchOptions } from "../types/global-search.types";
import { cn } from "@/utils/cn";
import {
  fromSearchOptionValues,
  toSearchOptionValues,
  type SearchOptionValue,
} from "../utils/search-options";

interface GlobalSearchToolbarProps {
  compact?: boolean;
  inputRef: RefObject<HTMLInputElement | null>;
  replaceInputRef: RefObject<HTMLInputElement | null>;
  query: string;
  onQueryChange: (query: string) => void;
  onSearchKeyDown: KeyboardEventHandler<HTMLInputElement>;
  detailsVisible: boolean;
  onDetailsVisibleChange: (visible: boolean) => void;
  searchOptions: ContentSearchOptions;
  setSearchOption: <Key extends keyof ContentSearchOptions>(
    key: Key,
    value: ContentSearchOptions[Key],
  ) => void;
  resultLabel: string | null;
  searchWarning: string | null;
  replaceQuery: string;
  onReplaceQueryChange: (query: string) => void;
  onReplace: () => void;
  onReplaceAll: () => void;
  canReplace: boolean;
  canReplaceAll: boolean;
  replaceAllTooltip?: string;
  includeQuery: string;
  onIncludeQueryChange: (query: string) => void;
  excludeQuery: string;
  onExcludeQueryChange: (query: string) => void;
}

export const GlobalSearchToolbar = memo(function GlobalSearchToolbar({
  compact = false,
  inputRef,
  replaceInputRef,
  query,
  onQueryChange,
  onSearchKeyDown,
  detailsVisible,
  onDetailsVisibleChange,
  searchOptions,
  setSearchOption,
  resultLabel,
  searchWarning,
  replaceQuery,
  onReplaceQueryChange,
  onReplace,
  onReplaceAll,
  canReplace,
  canReplaceAll,
  replaceAllTooltip,
  includeQuery,
  onIncludeQueryChange,
  excludeQuery,
  onExcludeQueryChange,
}: GlobalSearchToolbarProps) {
  const { t } = useTranslation();
  const searchInFilesLabel = t("workbench.searchInFiles");
  const searchOptionButtons: ToggleGroupOption<SearchOptionValue>[] = [
    {
      value: "case-sensitive",
      label: t("search.matchCase"),
      icon: SEARCH_TOGGLE_ICONS.caseSensitive,
    },
    {
      value: "whole-word",
      label: t("search.matchWholeWord"),
      icon: SEARCH_TOGGLE_ICONS.wholeWord,
    },
    {
      value: "regex",
      label: t("search.useRegex"),
      icon: SEARCH_TOGGLE_ICONS.regex,
    },
  ];
  const activeSearchOptions = toSearchOptionValues(searchOptions);

  return (
    <div className={cn("border-border/70 border-b bg-surface/55 py-2", compact ? "px-2" : "px-3")}>
      <div className={cn("flex min-w-0 items-center gap-2", compact && "flex-wrap gap-1.5")}>
        <SearchReplaceToggle
          isExpanded={detailsVisible}
          onToggle={() => onDetailsVisibleChange(!detailsVisible)}
          expandedLabel={t("search.hideDetails")}
          collapsedLabel={t("search.showDetails")}
        />
        <div className="flex h-7 min-w-0 flex-1 items-center gap-2 rounded-lg border border-border/70 bg-background/65 px-2">
          <MagnifyingGlass className="size-4 shrink-0 text-subtle-foreground" weight="duotone" />
          <CommandInput
            ref={inputRef}
            value={query}
            onChange={onQueryChange}
            onKeyDown={onSearchKeyDown}
            placeholder={searchInFilesLabel}
            className="font-sans min-w-0"
            aria-label={searchInFilesLabel}
            autoComplete="off"
            spellCheck={false}
          />
          {query ? (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              onClick={() => {
                onQueryChange("");
                inputRef.current?.focus();
              }}
              aria-label={t("search.clear")}
              className="shrink-0 text-subtle-foreground"
            >
              <X />
            </Button>
          ) : null}
        </div>
        <ToggleGroup<SearchOptionValue>
          type="multiple"
          value={activeSearchOptions}
          options={searchOptionButtons}
          onValueChange={(nextValues) => {
            const next = fromSearchOptionValues(nextValues);
            setSearchOption("caseSensitive", next.caseSensitive);
            setSearchOption("wholeWord", next.wholeWord);
            setSearchOption("useRegex", next.useRegex);
          }}
          ariaLabel={t("search.options")}
          variant="segmented"
          size="xs"
          wrap={false}
          iconOnly
          className={cn("shrink-0", compact && "order-3 ml-7")}
        />
        {searchWarning ? (
          <Badge
            variant="warning"
            className={cn("max-w-64 shrink-0 truncate", compact && "order-4")}
            title={searchWarning}
            role="status"
            aria-live="polite"
          >
            {searchWarning}
          </Badge>
        ) : resultLabel ? (
          <Badge
            className={cn("max-w-56 shrink-0 truncate", compact && "order-4")}
            title={resultLabel}
            role="status"
          >
            {resultLabel}
          </Badge>
        ) : null}
      </div>
      {detailsVisible ? (
        <div className="mt-2 space-y-2">
          <SearchReplaceRow
            value={replaceQuery}
            onChange={onReplaceQueryChange}
            inputRef={replaceInputRef}
            onReplace={onReplace}
            onReplaceAll={onReplaceAll}
            canReplace={canReplace}
            canReplaceAll={canReplaceAll}
            replaceAllTooltip={replaceAllTooltip}
            onKeyDown={(event) => {
              if (event.key === "Enter" && canReplace) {
                event.preventDefault();
                onReplace();
              }
            }}
          />
          <div className={cn("grid gap-2", compact ? "grid-cols-1" : "grid-cols-2")}>
            <CommandInput
              value={includeQuery}
              onChange={onIncludeQueryChange}
              placeholder={t("search.filesToInclude")}
              className="font-sans h-7 rounded-md border border-border/70 bg-background/65 px-2"
              aria-label={t("search.filesToInclude")}
              autoComplete="off"
              spellCheck={false}
            />
            <CommandInput
              value={excludeQuery}
              onChange={onExcludeQueryChange}
              placeholder={t("search.filesToExclude")}
              className="font-sans h-7 rounded-md border border-border/70 bg-background/65 px-2"
              aria-label={t("search.filesToExclude")}
              autoComplete="off"
              spellCheck={false}
            />
          </div>
        </div>
      ) : null}
    </div>
  );
});
