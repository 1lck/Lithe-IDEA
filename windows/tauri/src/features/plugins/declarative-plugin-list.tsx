import { useRef, useState, type KeyboardEvent } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { SearchField } from "@/ui/search";
import type { DeclarativePluginSummary } from "./declarative-plugin-launch";
import type { PluginDetailsSelection } from "./details/plugin-details.types";
import {
  EMPTY_PLUGIN_LIST_FILTERS,
  groupPluginList,
  pluginListIdentity,
  type PluginListFilters,
} from "./declarative-plugin-list-model";

export function DeclarativePluginList({
  plugins,
  selection,
  onSelect,
}: {
  plugins: DeclarativePluginSummary[];
  selection: PluginDetailsSelection | null;
  onSelect: (selection: PluginDetailsSelection) => void;
}) {
  const { t } = useTranslation();
  const [filters, setFilters] = useState(EMPTY_PLUGIN_LIST_FILTERS);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const rows = useRef(new Map<string, HTMLButtonElement>());
  const groups = groupPluginList(plugins, filters);
  const visible = groups.flatMap((group) => group.plugins);
  const hiddenSelection = selection && plugins.some((plugin) =>
    pluginListIdentity(plugin) === pluginListIdentity(selection)) && !visible.some((plugin) =>
    pluginListIdentity(plugin) === pluginListIdentity(selection));
  const active = filters.query !== "" || filters.capability !== "all"
    || filters.state !== "all" || filters.source !== "all";
  const reset = () => setFilters(EMPTY_PLUGIN_LIST_FILTERS);
  const choose = <K extends keyof PluginListFilters>(key: K, value: PluginListFilters[K]) =>
    setFilters((current) => ({ ...current, [key]: value }));
  const navigate = (event: KeyboardEvent<HTMLButtonElement>, plugin: DeclarativePluginSummary) => {
    let index = visible.findIndex((item) => pluginListIdentity(item) === pluginListIdentity(plugin));
    if (event.key === "ArrowDown") index = Math.min(index + 1, visible.length - 1);
    else if (event.key === "ArrowUp") index = Math.max(index - 1, 0);
    else if (event.key === "Home") index = 0;
    else if (event.key === "End") index = visible.length - 1;
    else return;
    event.preventDefault();
    const next = visible[index];
    if (!next) return;
    rows.current.get(pluginListIdentity(next))?.focus();
    onSelect({ pluginId: next.pluginId, source: next.source });
  };

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <SearchField
          value={filters.query}
          onChange={(value) => {
            if (value === "/") {
              setFiltersOpen(true);
              choose("query", "");
            } else choose("query", value);
          }}
          aria-label={t("settings.declarativePluginList.search")}
          placeholder={t("settings.declarativePluginList.search")}
          containerClassName="min-w-0 flex-[1_1_14rem]"
          onKeyDown={(event) => {
            if (event.key === "Escape") choose("query", "");
          }}
        />
        <Button
          size="sm"
          variant="ghost"
          aria-pressed={filtersOpen}
          onClick={() => setFiltersOpen((value) => !value)}
        >
          {t("settings.declarativePluginList.filters")}
        </Button>
        {active && <Button size="sm" variant="ghost" onClick={reset}>{t("settings.declarativePluginList.reset")}</Button>}
      </div>
      {filtersOpen && (
        <div className="flex min-w-0 flex-col gap-2 rounded-md border border-border p-2">
          <FilterButtons<PluginListFilters["capability"]>
            label={t("settings.declarativePluginList.capability")}
            options={["all", "language"]}
            value={filters.capability}
            labelFor={(value) => t(`settings.declarativePluginList.capability.${value}`)}
            onChange={(value) => choose("capability", value)}
          />
          <FilterButtons<PluginListFilters["state"]>
            label={t("settings.declarativePluginList.state")}
            options={["all", "enabled", "disabled", "quarantined"]}
            value={filters.state}
            labelFor={(value) => t(`settings.declarativePluginList.state.${value}`)}
            onChange={(value) => choose("state", value)}
          />
          <FilterButtons<PluginListFilters["source"]>
            label={t("settings.declarativePluginList.source")}
            options={["all", "bundled", "installed"]}
            value={filters.source}
            labelFor={(value) => value === "all"
              ? t("settings.declarativePluginList.source.all")
              : t(`settings.declarativePlugins.source.${value}`)}
            onChange={(value) => choose("source", value)}
          />
          <p className="text-subtle-foreground ui-text-sm">{t("settings.declarativePluginList.unavailableFilters")}</p>
        </div>
      )}
      <p role="status" className="text-subtle-foreground ui-text-sm">
        {t("settings.declarativePluginList.count", { count: visible.length, total: plugins.length })}
      </p>
      {hiddenSelection && (
        <div className="flex flex-wrap items-center gap-2 text-subtle-foreground ui-text-sm">
          <span>{t("settings.declarativePluginList.selectionHidden")}</span>
          <Button size="sm" variant="ghost" onClick={reset}>{t("settings.declarativePluginList.showSelection")}</Button>
        </div>
      )}
      <ul className="flex min-w-0 flex-col gap-3" data-testid="declarative-plugin-list">
        {groups.map((group) => (
          <li key={group.state}>
            <h4 className="mb-1 ui-text-sm font-semibold">
              {t(`settings.declarativePluginList.state.${group.state}`)} ({group.plugins.length})
            </h4>
            <ul className="flex min-w-0 flex-col gap-1">
              {group.plugins.map((plugin) => {
                const identity = pluginListIdentity(plugin);
                const selected = selection !== null && pluginListIdentity(selection) === identity;
                return (
                  <li key={identity} data-plugin-id={plugin.pluginId} data-plugin-source={plugin.source}>
                    <Button
                      ref={(element: HTMLButtonElement | null) => {
                        if (element) rows.current.set(identity, element);
                        else rows.current.delete(identity);
                      }}
                      variant={selected ? "accent" : "ghost"}
                      className="h-auto w-full min-w-0 flex-col items-start whitespace-normal px-3 py-2 text-left"
                      aria-pressed={selected}
                      onClick={() => onSelect({ pluginId: plugin.pluginId, source: plugin.source })}
                      onKeyDown={(event) => navigate(event, plugin)}
                    >
                      <span className="w-full break-words font-medium">{plugin.displayName}</span>
                      <span className="w-full break-all text-subtle-foreground">
                        {plugin.pluginId} · {plugin.version} · {t(`settings.declarativePlugins.source.${plugin.source}`)}
                      </span>
                      {plugin.status === "rejected" && plugin.rejection && (
                        <span className="w-full break-words text-destructive">{plugin.rejection.code}: {plugin.rejection.message}</span>
                      )}
                    </Button>
                  </li>
                );
              })}
            </ul>
          </li>
        ))}
        {!visible.length && (
          <li className="text-subtle-foreground ui-text-sm">
            {t(plugins.length ? "settings.declarativePluginList.noMatches" : "settings.declarativePlugins.empty")}
          </li>
        )}
      </ul>
    </div>
  );
}

function FilterButtons<T extends string>({ label, options, value, labelFor, onChange }: {
  label: string;
  options: readonly T[];
  value: T;
  labelFor: (value: T) => string;
  onChange: (value: T) => void;
}) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap items-center gap-1">
      <span className="mr-1 ui-text-sm">{label}</span>
      {options.map((option) => (
        <Button key={option} size="sm" variant={value === option ? "accent" : "ghost"}
          aria-pressed={value === option} onClick={() => onChange(option)}>
          {labelFor(option)}
        </Button>
      ))}
    </div>
  );
}
