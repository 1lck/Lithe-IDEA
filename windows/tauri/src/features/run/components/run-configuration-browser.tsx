import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import {
  RUN_LANGUAGE_TITLES,
  runConfigurationLanguageGroups,
  runConfigurationLanguageKey,
  type RunLanguageKey,
} from "../utils/run-configuration-language";
import { RunConfigurationList, type RunConfigurationListProps } from "./run-configuration-list";
import { RunConfigurationListSplit } from "./run-configuration-list-split";
import { RunLanguageIcon } from "./run-language-icon";

interface RunConfigurationBrowserProps extends RunConfigurationListProps {
  content: ReactNode;
}

/** Language selection is local browsing state; all process sessions remain owned by RunStore. */
export function RunConfigurationBrowser({ content, ...props }: RunConfigurationBrowserProps) {
  const { t } = useTranslation();
  const groups = useMemo(
    () => runConfigurationLanguageGroups(props.configurations),
    [props.configurations],
  );
  const selected = props.configurations.find(
    (configuration) => configuration.id === props.selectedId,
  );
  const selectedLanguage = selected ? runConfigurationLanguageKey(selected) : undefined;
  const [language, setLanguage] = useState<RunLanguageKey | undefined>(selectedLanguage);
  const active =
    groups.find((group) => group.id === language) ??
    groups.find((group) => group.id === selectedLanguage) ??
    groups[0];

  useEffect(() => {
    if (selectedLanguage) setLanguage(selectedLanguage);
  }, [props.selectedId, selectedLanguage]);

  function languageTitle(id: RunLanguageKey) {
    if (id === "infrastructure") return t("run.languageInfrastructure");
    if (id === "tools") return t("run.languageTools");
    if (id === "other") return t("run.languageOther");
    return RUN_LANGUAGE_TITLES[id];
  }

  return (
    <RunConfigurationListSplit
      languages={() => (
        <nav aria-label={t("run.languages")} className="min-h-0 flex-1 overflow-y-auto">
          <ul className="m-0 list-none p-0">
            {groups.map((group) => (
              <li key={group.id}>
                <button
                  type="button"
                  aria-pressed={active?.id === group.id}
                  aria-label={languageTitle(group.id)}
                  title={languageTitle(group.id)}
                  className={cn(
                    "flex h-6 w-full items-center gap-2 px-2 ui-text-sm focus-visible:outline focus-visible:outline-ring group-data-[compact=true]/run-languages:justify-center",
                    active?.id === group.id ? "bg-selected text-foreground" : "hover:bg-accent",
                  )}
                  onClick={() => {
                    setLanguage(group.id);
                    props.onSelect(group.configurations[0].id);
                  }}
                >
                  <RunLanguageIcon language={group.id} />
                  <span className="min-w-0 flex-1 truncate text-left group-data-[compact=true]/run-languages:hidden">
                    {languageTitle(group.id)}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </nav>
      )}
      list={
        <RunConfigurationList
          {...props}
          configurations={active?.configurations ?? []}
          onRun={(configuration) => {
            props.onSelect(configuration.id);
            props.onRun(configuration);
          }}
        />
      }
      content={content}
    />
  );
}
