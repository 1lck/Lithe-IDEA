import { useEffect, useId, useMemo, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { CaretRightIcon, GearIcon, PlayIcon, StopIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import type { RunConfiguration, RunSession } from "../types/run.types";
import {
  configurationsForExecution,
  infrastructureConfigurations,
} from "../utils/run-configuration";
import { runConfigurationPresentation } from "../utils/run-configuration-presentation";
import { RunConfigurationIcon } from "./run-icon";

interface RunConfigurationListProps {
  configurations: RunConfiguration[];
  selectedId: string | null;
  sessions: RunSession[];
  onSelect: (id: string) => void;
  onRun: (configuration: RunConfiguration) => void;
  onStop: (sessionId: string) => void;
  onEdit: (id: string) => void;
}

/** Presentation groups use Core's type/category; discovery and batch selection stay in their owners. */
export function RunConfigurationList({
  configurations,
  selectedId,
  sessions,
  onSelect,
  onRun,
  onStop,
  onEdit,
}: RunConfigurationListProps) {
  const { t } = useTranslation();
  const listId = useId();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const groups = useMemo(() => {
    const entries = [
      ...configurationsForExecution(configurations, "service"),
      ...configurationsForExecution(configurations, "application"),
      ...configurationsForExecution(configurations, "task"),
      ...infrastructureConfigurations(configurations),
    ];
    const byType = new Map<string, RunConfiguration[]>();
    for (const entry of entries) {
      const iconKey = entry.iconKey ?? runConfigurationPresentation(entry).iconKey;
      // Display titles can collide with custom providers; known frameworks may span providers.
      const typeIdentity = iconKey === "terminal" ? entry.provider.split(".")[0] : iconKey;
      const key = JSON.stringify([entry.category, iconKey, typeIdentity, entry.kindTitle]);
      const group = byType.get(key) ?? [];
      group.push(entry);
      byType.set(key, group);
    }
    return Array.from(byType, ([key, entries]) => ({ key, entries }));
  }, [configurations]);
  const selectedGroupKey = groups.find(({ entries }) =>
    entries.some((entry) => entry.id === selectedId),
  )?.key;

  useEffect(() => {
    if (selectedGroupKey) {
      setCollapsed((previous) => ({ ...previous, [selectedGroupKey]: false }));
    }
  }, [selectedId, selectedGroupKey]);

  return (
    <nav aria-label={t("run.configurations")} className="min-h-0 flex-1 overflow-y-auto py-1">
      <ul className="m-0 list-none p-0">
        {groups.map(({ key, entries }, index) => {
          const representative = entries[0];
          const isCollapsed = collapsed[key] ?? representative.category === "infrastructure";
          const groupId = `${listId}-${index}`;
          return (
            <li key={key}>
              <button
                type="button"
                aria-expanded={!isCollapsed}
                aria-controls={groupId}
                className="flex h-7 w-full items-center gap-1 px-2 text-left ui-text-sm hover:bg-accent focus-visible:outline focus-visible:outline-ring"
                onClick={() => setCollapsed((previous) => ({ ...previous, [key]: !isCollapsed }))}
                onKeyDown={(event) => {
                  if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
                  event.preventDefault();
                  setCollapsed((previous) => ({ ...previous, [key]: event.key === "ArrowLeft" }));
                }}
              >
                <CaretRightIcon className={cn("size-3 shrink-0", !isCollapsed && "rotate-90")} />
                <RunConfigurationIcon
                  provider={representative.provider}
                  iconKey={representative.iconKey}
                  className="size-4 shrink-0"
                />
                <span className="min-w-0 truncate" title={representative.kindTitle}>
                  {representative.kindTitle}
                </span>
              </button>
              <ul id={groupId} hidden={isCollapsed} className="m-0 list-none p-0">
                {entries.map((configuration) => {
                  const runningSession = sessions.find(
                    (session) => session.configurationId === configuration.id && session.isRunning,
                  );
                  const selected = selectedId === configuration.id;
                  return (
                    <li
                      key={configuration.id}
                      className={cn(
                        "group relative mx-1 flex h-7 items-center rounded-sm pr-1 pl-10 ui-text-sm",
                        selected ? "bg-selected text-foreground" : "hover:bg-accent",
                      )}
                    >
                      <button
                        type="button"
                        aria-pressed={selected}
                        title={configuration.name}
                        className="flex h-full min-w-0 flex-1 items-center gap-1 pr-1 text-left focus-visible:outline focus-visible:outline-ring"
                        onClick={() => onSelect(configuration.id)}
                      >
                        <RunConfigurationIcon
                          provider={configuration.provider}
                          iconKey={configuration.iconKey}
                          className="size-4 shrink-0"
                        />
                        <span className="min-w-0 truncate">{configuration.name}</span>
                      </button>
                      <div
                        className={cn(
                          "flex shrink-0 items-center opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                          (selected || runningSession) && "opacity-100",
                        )}
                      >
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          className="size-5 rounded-sm"
                          onClick={() => onEdit(configuration.id)}
                          aria-label={t("run.editService")}
                          title={t("run.editService")}
                        >
                          <GearIcon />
                        </Button>
                        <Button
                          variant="ghost"
                          size="icon-xs"
                          className="size-5 rounded-sm"
                          onClick={() =>
                            runningSession ? onStop(runningSession.id) : onRun(configuration)
                          }
                          aria-label={t(runningSession ? "run.stop" : "run.title")}
                          title={t(runningSession ? "run.stop" : "run.title")}
                        >
                          {runningSession ? (
                            <StopIcon className="text-warning" />
                          ) : (
                            <PlayIcon className="text-success" />
                          )}
                        </Button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
