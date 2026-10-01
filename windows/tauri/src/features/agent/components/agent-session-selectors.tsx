import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import {
  CaretRightIcon,
  CaretUpIcon,
  ChatCircleIcon,
  CheckIcon,
  DotsThreeIcon,
  LightningIcon,
  ShieldCheckIcon,
  SlidersHorizontalIcon,
} from "@/ui/icons";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/popover";
import { cn } from "@/utils/cn";
import {
  choiceTitle,
  currentChoiceTitle,
  filteredChoices,
  localizedAgentLabel,
  modelSummary,
  optionTitle,
  partitionOptions,
  type AgentSelectorLabels,
} from "../services/agent-session-selectors";
import type { AgentSessionConfigOption } from "../types/agent.types";
import { AgentBrandIcon } from "./brand/agent-brand-icon";

function useSelectorLabels(): AgentSelectorLabels {
  const { t, language } = useTranslation();
  return useMemo(
    () => ({
      language,
      thinkingLevel: t("agent.selector.thinkingLevel"),
      speed: t("agent.selector.speed"),
      standard: t("agent.selector.standard"),
      fast: t("agent.selector.fast"),
    }),
    [language, t],
  );
}

function ModeIcon({ id }: { id: string }) {
  const Icon =
    id === "read-only"
      ? ChatCircleIcon
      : id === "agent"
        ? ShieldCheckIcon
        : id === "agent-full-access"
          ? LightningIcon
          : SlidersHorizontalIcon;
  return <Icon className="size-3.5 shrink-0" />;
}

function SelectorRow({
  isSelected,
  minHeight = 32,
  onClick,
  children,
}: {
  isSelected: boolean;
  minHeight?: number;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={isSelected}
      className={cn(
        "flex w-full items-center gap-2 px-3 py-2 text-left text-foreground ui-text-sm",
        isSelected ? "bg-selected" : "hover:bg-accent",
      )}
      style={{ minHeight }}
      onClick={onClick}
    >
      {children}
      <span className="min-w-2 flex-1" />
      <CheckIcon className={cn("size-3 shrink-0 text-success", !isSelected && "invisible")} />
    </button>
  );
}

function selectorTrigger(content: ReactNode) {
  return (
    <span className="flex h-7 max-w-44 items-center gap-[5px] rounded px-1 text-subtle-foreground ui-text-caption hover:bg-accent">
      {content}
      <CaretUpIcon className="size-2 shrink-0" />
    </span>
  );
}

function ModelPopover({
  option,
  settings,
  agentName,
  onSelect,
}: {
  option: AgentSessionConfigOption;
  settings: AgentSessionConfigOption[];
  agentName: string | null;
  onSelect: (id: string, value: string) => void;
}) {
  const { t } = useTranslation();
  const labels = useSelectorLabels();
  const [query, setQuery] = useState("");
  const [openSettingID, setOpenSettingID] = useState<string | null>(null);
  const choices = filteredChoices(option, query);
  const openSetting = settings.find((setting) => setting.id === openSettingID) ?? null;

  return (
    <div className="flex items-end">
      <div className="w-[330px] pb-1">
        <div className="p-2">
          <input
            autoFocus
            value={query}
            placeholder={t("agent.selector.searchModels")}
            aria-label={t("agent.selector.searchModels")}
            className="h-7 w-full rounded border border-border bg-background px-2 text-foreground outline-none ui-text-sm focus:border-primary"
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && choices[0] !== undefined)
                onSelect(option.id, choices[0].id);
            }}
          />
        </div>
        {choices.length === 0 ? (
          <div className="flex min-h-9 items-center justify-center text-subtle-foreground ui-text-sm">
            {t("agent.selector.noModels")}
          </div>
        ) : (
          <div role="listbox" className="max-h-60 overflow-y-auto">
            {choices.map((choice, index) => (
              <div key={choice.id}>
                {choice.group !== null &&
                (index === 0 || choices[index - 1].group !== choice.group) ? (
                  <div className="px-3 py-1 text-[10px] text-subtle-foreground">{choice.group}</div>
                ) : null}
                <SelectorRow
                  isSelected={choice.id === option.currentValue}
                  onClick={() => onSelect(option.id, choice.id)}
                >
                  <AgentBrandIcon name={agentName} size={16} className="shrink-0" />
                  <span className="truncate">{choice.name}</span>
                </SelectorRow>
              </div>
            ))}
          </div>
        )}
        {settings.length === 0 ? null : (
          <>
            <div className="my-1 h-px bg-border" />
            {settings.map((setting) => (
              <button
                key={setting.id}
                type="button"
                aria-expanded={openSettingID === setting.id}
                className={cn(
                  "flex h-7 w-full items-center gap-2 px-3 text-foreground ui-text-sm hover:bg-accent",
                  openSettingID === setting.id && "bg-muted",
                )}
                onClick={() =>
                  setOpenSettingID((current) => (current === setting.id ? null : setting.id))
                }
              >
                <span className="flex-1 text-left">{optionTitle(setting, labels)}</span>
                <span className="text-subtle-foreground">
                  {currentChoiceTitle(setting, labels)}
                </span>
                <CaretRightIcon className="size-2.5" />
              </button>
            ))}
          </>
        )}
      </div>
      {openSetting === null ? null : (
        <div className="w-[180px] border-border border-l pb-1">
          <div className="px-3 py-2 text-subtle-foreground ui-text-caption">
            {optionTitle(openSetting, labels)}
          </div>
          <div role="listbox" className="max-h-60 overflow-y-auto">
            {openSetting.choices.map((choice) => (
              <SelectorRow
                key={choice.id}
                isSelected={choice.id === openSetting.currentValue}
                onClick={() => onSelect(openSetting.id, choice.id)}
              >
                <span>{choiceTitle(choice, openSetting, labels)}</span>
              </SelectorRow>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

interface AgentSessionSelectorsProps {
  options: AgentSessionConfigOption[];
  agentName: string | null;
  isDisabled: boolean;
  onSelect: (id: string, value: string) => void;
}

/**
 * Approval mode and a searchable model panel in the composer toolbar, as
 * `AgentSessionSelectors` on macOS. Popovers close as soon as the selectors
 * become disabled, so a stale choice cannot be sent mid-turn.
 */
export function AgentSessionSelectors({
  options,
  agentName,
  isDisabled,
  onSelect,
}: AgentSessionSelectorsProps) {
  const { t } = useTranslation();
  const labels = useSelectorLabels();
  const [showsModels, setShowsModels] = useState(false);
  const [showsModes, setShowsModes] = useState(false);
  const [showsMore, setShowsMore] = useState(false);
  const { model, mode, settings } = partitionOptions(options);

  useEffect(() => {
    if (!isDisabled) return;
    setShowsModels(false);
    setShowsModes(false);
    setShowsMore(false);
  }, [isDisabled]);

  const select = (id: string, value: string) => {
    if (isDisabled) return;
    setShowsModels(false);
    setShowsModes(false);
    setShowsMore(false);
    onSelect(id, value);
  };

  return (
    <div
      className={cn(
        "flex min-w-0 items-center gap-1",
        isDisabled && "pointer-events-none opacity-50",
      )}
    >
      {mode === null ? null : (
        <Popover open={showsModes} onOpenChange={setShowsModes}>
          <PopoverTrigger
            disabled={isDisabled}
            aria-label={`${t("agent.selector.mode")}: ${currentChoiceTitle(mode, labels)}`}
            title={localizedAgentLabel(mode.name, labels)}
            render={<button type="button" />}
          >
            {selectorTrigger(
              <>
                <ModeIcon id={mode.currentValue} />
                <span className="truncate">{currentChoiceTitle(mode, labels)}</span>
              </>,
            )}
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-[350px] gap-0 p-0 py-1">
            <div role="listbox" className="max-h-[330px] overflow-y-auto">
              {mode.choices.map((choice) => (
                <SelectorRow
                  key={choice.id}
                  minHeight={64}
                  isSelected={choice.id === mode.currentValue}
                  onClick={() => select(mode.id, choice.id)}
                >
                  <ModeIcon id={choice.id} />
                  <span className="min-w-0 space-y-0.5">
                    <span className="block truncate">{choiceTitle(choice, mode, labels)}</span>
                    {choice.description === null || choice.description.length === 0 ? null : (
                      <span className="line-clamp-2 block text-subtle-foreground ui-text-caption">
                        {localizedAgentLabel(choice.description, labels)}
                      </span>
                    )}
                  </span>
                </SelectorRow>
              ))}
            </div>
          </PopoverContent>
        </Popover>
      )}
      {model !== null ? (
        <Popover open={showsModels} onOpenChange={setShowsModels}>
          <PopoverTrigger
            disabled={isDisabled}
            aria-label={`${t("agent.selector.model")}: ${currentChoiceTitle(model, labels)}`}
            title={currentChoiceTitle(model, labels)}
            render={<button type="button" />}
          >
            {selectorTrigger(
              <>
                <AgentBrandIcon name={agentName} size={12} className="shrink-0" />
                <span className="truncate">{modelSummary(model, options, labels)}</span>
              </>,
            )}
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-auto gap-0 p-0">
            <ModelPopover
              option={model}
              settings={settings}
              agentName={agentName}
              onSelect={select}
            />
          </PopoverContent>
        </Popover>
      ) : settings.length > 0 ? (
        <Popover open={showsMore} onOpenChange={setShowsMore}>
          <PopoverTrigger
            disabled={isDisabled}
            aria-label={t("agent.selector.more")}
            title={t("agent.selector.more")}
            render={<button type="button" />}
          >
            <span className="flex size-7 items-center justify-center rounded text-subtle-foreground hover:bg-accent">
              <DotsThreeIcon className="size-3.5" />
            </span>
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-60 gap-1 p-1">
            {settings.map((setting) => (
              <div key={setting.id}>
                <div className="px-3 py-1 text-subtle-foreground ui-text-caption">
                  {optionTitle(setting, labels)}
                </div>
                {setting.choices.map((choice) => (
                  <SelectorRow
                    key={choice.id}
                    isSelected={choice.id === setting.currentValue}
                    onClick={() => select(setting.id, choice.id)}
                  >
                    <span>
                      {choice.group === null || choice.id === setting.currentValue
                        ? choiceTitle(choice, setting, labels)
                        : `${choice.group}: ${choiceTitle(choice, setting, labels)}`}
                    </span>
                  </SelectorRow>
                ))}
              </div>
            ))}
          </PopoverContent>
        </Popover>
      ) : null}
    </div>
  );
}
