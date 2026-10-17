import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { openExternalBrowserUrl } from "@/features/window/utils/external-navigation";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  ArrowsClockwiseIcon,
  CaretDownIcon,
  CaretRightIcon,
  CheckIcon,
  CopyIcon,
  FileTextIcon,
  HandIcon,
  ListChecksIcon,
  PencilSimpleIcon,
  WarningIcon,
} from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { cn } from "@/utils/cn";
import { tryWriteClipboardText } from "@/utils/clipboard";
import {
  activitySummary,
  groupTranscript,
  inlineSpans,
  itemMatches,
  messageSegments,
  toolMatches,
} from "../services/agent-transcript-items";
import {
  currentPermission,
  type AgentConversation,
  type AgentConversationMessage,
  type AgentPermissionPrompt,
  type AgentToolDetails,
  type AgentToolLocation,
  type AgentToolStatus,
} from "../types/agent.types";
import {
  formatTurnDuration,
  turnElapsed,
  type AgentTurnStatistics,
  type AgentTurnUsage,
} from "../types/agent-turn-statistics";
import { AgentBrandIcon } from "./brand/agent-brand-icon";

type Translate = ReturnType<typeof useTranslation>["t"];

function durationLabel(seconds: number, t: Translate): string {
  return formatTurnDuration(seconds, {
    hours: (hours, minutes, s) => t("agent.turn.hours", { hours, minutes, seconds: s }),
    minutes: (minutes, s) => t("agent.turn.minutes", { minutes, seconds: s }),
    seconds: (s) => t("agent.turn.seconds", { seconds: s }),
  });
}

function usageDetails(usage: AgentTurnUsage, t: Translate): string {
  const lines = [
    t("agent.turn.usageHint"),
    t("agent.turn.input", { count: usage.inputTokens.toLocaleString() }),
    t("agent.turn.output", { count: usage.outputTokens.toLocaleString() }),
    t("agent.turn.total", { count: usage.totalTokens.toLocaleString() }),
  ];
  const optional: [string, number | null][] = [
    ["agent.turn.reasoning", usage.thoughtTokens],
    ["agent.turn.cacheRead", usage.cachedReadTokens],
    ["agent.turn.cacheWrite", usage.cachedWriteTokens],
  ];
  for (const [key, count] of optional) {
    if (count !== null) lines.push(t(key, { count: count.toLocaleString() }));
  }
  return lines.join("\n");
}

/** Centered agent mark with its version; clicking it switches agents. */
export function AgentHero({
  agentName,
  agentVersion,
  onSwitchAgent,
}: {
  agentName: string | null;
  agentVersion: string | null;
  onSwitchAgent: () => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-4">
      <button
        type="button"
        aria-label={t("agent.actions.switchAgent")}
        title={t("agent.actions.switchAgent")}
        className="relative text-subtle-foreground/70 hover:text-subtle-foreground"
        onClick={onSwitchAgent}
      >
        <AgentBrandIcon name={agentName} size={60} />
        {agentVersion === null || agentVersion.length === 0 ? null : (
          <span className="absolute -top-0.5 left-[70px] whitespace-nowrap rounded border border-violet-500/40 bg-violet-500/10 px-2 py-px font-medium text-[10px] text-violet-700 dark:text-violet-200">
            v{agentVersion}
          </span>
        )}
      </button>
      <span className="text-subtle-foreground/80 ui-text-base">
        {agentName === null ? t("agent.hero.choose") : t("agent.hero.sendTo", { name: agentName })}
      </span>
    </div>
  );
}

/** Tasks, running and edits below the transcript; visible even when empty. */
export function AgentActivitySummaryBar({ messages }: { messages: AgentConversationMessage[] }) {
  const { t } = useTranslation();
  const counts = activitySummary(messages);
  const segments: { icon: typeof ListChecksIcon; label: string; value: number; tint?: string }[] = [
    {
      icon: ListChecksIcon,
      label: t("agent.activity.tasks"),
      value: counts.tasks,
      tint: counts.failed > 0 ? "text-destructive" : undefined,
    },
    {
      icon: ArrowsClockwiseIcon,
      label: t("agent.activity.running"),
      value: counts.running,
      tint: counts.running > 0 ? "text-primary" : undefined,
    },
    { icon: PencilSimpleIcon, label: t("agent.activity.edits"), value: counts.edits },
  ];
  return (
    <div className="mx-[18px] mb-1 flex h-8 shrink-0 items-center rounded-[5px] border border-border bg-surface text-subtle-foreground ui-text-caption">
      {segments.map(({ icon: Icon, label, value, tint }, index) => (
        <div key={label} className="flex flex-1 items-center justify-center gap-1.5">
          {index === 0 ? null : <span aria-hidden className="-ml-px h-3.5 w-px bg-border" />}
          <Icon className="size-2.5" />
          <span>{label}</span>
          {value > 0 ? (
            <span className={cn("font-mono font-semibold text-[10px] text-foreground", tint)}>
              {value}
            </span>
          ) : null}
        </div>
      ))}
    </div>
  );
}

function ToolEvidence({
  details,
  onOpenLocation,
}: {
  details: AgentToolDetails;
  onOpenLocation: (location: AgentToolLocation) => void;
}) {
  const { t } = useTranslation();
  const section = (title: string, text: string, key: string) => (
    <div key={key} className="space-y-1">
      <div className="font-medium text-subtle-foreground ui-text-caption">{title}</div>
      <pre className="max-h-40 select-text overflow-auto whitespace-pre font-mono text-[11px] text-foreground">
        {text}
      </pre>
    </div>
  );
  return (
    <div className="space-y-2">
      {details.locations.map((location) => (
        <button
          key={`${location.path}:${location.line ?? 0}`}
          type="button"
          title={location.path}
          className="flex max-w-full items-center gap-1 text-left font-mono text-[11px] text-foreground hover:underline"
          onClick={() => onOpenLocation(location)}
        >
          <FileTextIcon className="size-3 shrink-0" />
          <span className="line-clamp-2 break-all">
            {location.path}
            {location.line === null ? "" : `:${location.line}`}
          </span>
        </button>
      ))}
      {details.input === null ? null : section(t("agent.evidence.input"), details.input, "input")}
      {details.content.map((entry, index) => section(entry.title, entry.text, `content-${index}`))}
      {details.output === null
        ? null
        : section(t("agent.evidence.result"), details.output, "output")}
    </div>
  );
}

function hasEvidence(details: AgentToolDetails): boolean {
  return (
    details.locations.length > 0 ||
    details.input !== null ||
    details.output !== null ||
    details.content.length > 0
  );
}

const STATUS_COLOR: Record<AgentToolStatus, string> = {
  completed: "bg-success",
  failed: "bg-destructive",
  interrupted: "bg-warning",
  in_progress: "bg-warning",
  pending: "bg-subtle-foreground/60",
};

/** Collapsible timeline for adjacent tool calls, as `AgentToolGroupView`. */
function ToolGroup({
  tools,
  searchText,
  onOpenLocation,
}: {
  tools: AgentConversationMessage[];
  searchText: string;
  onOpenLocation: (location: AgentToolLocation) => void;
}) {
  const { t } = useTranslation();
  const [isExpanded, setIsExpanded] = useState(searchText.length > 0);
  const [expandedToolID, setExpandedToolID] = useState<string | null>(null);
  useEffect(() => {
    if (searchText.length > 0) setIsExpanded(true);
  }, [searchText]);

  const failed = tools.filter((tool) => tool.toolStatus === "failed").length;
  const interrupted = tools.filter((tool) => tool.toolStatus === "interrupted").length;
  const completed = tools.filter((tool) => tool.toolStatus === "completed").length;
  const shown =
    searchText.length === 0 ? tools : tools.filter((tool) => toolMatches(tool, searchText));
  const detailsOpen = shown.some(
    (tool) => tool.id === expandedToolID && hasEvidence(tool.toolDetails),
  );

  let summary;
  if (failed > 0) {
    summary = (
      <span className="flex items-center gap-1 text-destructive">
        <WarningIcon className="size-3" />
        {t("agent.toolGroup.failed", { count: failed })}
      </span>
    );
  } else if (interrupted > 0) {
    summary = (
      <span className="text-warning">
        {t("agent.toolGroup.interrupted", { count: interrupted })}
      </span>
    );
  } else if (completed === tools.length) {
    summary = (
      <span className="flex items-center gap-1 text-success">
        <CheckIcon className="size-3" />
        {t("agent.toolGroup.allCompleted")}
      </span>
    );
  } else {
    summary = (
      <span className="text-subtle-foreground">
        {t("agent.toolGroup.completed", { done: completed, total: tools.length })}
      </span>
    );
  }

  return (
    <div
      className={cn(
        "w-full rounded-md border bg-surface",
        failed > 0 ? "border-destructive/70" : "border-border",
      )}
    >
      <button
        type="button"
        aria-expanded={isExpanded}
        title={isExpanded ? t("agent.toolGroup.hide") : t("agent.toolGroup.show")}
        className="flex h-[34px] w-full items-center gap-2 px-2.5 ui-text-caption"
        onClick={() => setIsExpanded((value) => !value)}
      >
        <span className="min-w-0 flex-1 truncate text-left font-semibold text-foreground ui-text-sm">
          {t("agent.toolGroup.title", { count: tools.length })}
        </span>
        {summary}
        {isExpanded ? (
          <CaretDownIcon className="size-2.5 text-subtle-foreground" />
        ) : (
          <CaretRightIcon className="size-2.5 text-subtle-foreground" />
        )}
      </button>
      {isExpanded ? (
        <div
          className="overflow-y-auto border-border border-t px-2.5 py-1"
          style={{ maxHeight: Math.min(shown.length, 4) * 32 + (detailsOpen ? 168 : 8) }}
        >
          {shown.map((tool) => {
            const open = expandedToolID === tool.id;
            const evidence = hasEvidence(tool.toolDetails);
            return (
              <div key={tool.id}>
                <button
                  type="button"
                  title={tool.text}
                  aria-label={`${tool.text} · ${t(`agent.tool.status.${tool.toolStatus ?? "pending"}`)}`}
                  className="flex h-8 w-full items-center gap-[7px]"
                  onClick={() => {
                    if (evidence) setExpandedToolID(open ? null : tool.id);
                  }}
                >
                  <span
                    aria-hidden
                    className="relative flex h-8 w-4 shrink-0 items-center justify-center"
                  >
                    <span className="absolute inset-y-0 w-px bg-border" />
                    <span className="relative size-[5px] rounded-full bg-subtle-foreground/70" />
                  </span>
                  <span className="min-w-0 flex-1 truncate text-left font-mono text-[11px] text-foreground">
                    {tool.text}
                  </span>
                  <span
                    aria-hidden
                    className={cn(
                      "size-[7px] shrink-0 rounded-full",
                      STATUS_COLOR[tool.toolStatus ?? "pending"],
                    )}
                  />
                </button>
                {open && evidence ? (
                  <div className="rounded bg-muted/60 py-2 pr-2 pl-6">
                    <ToolEvidence details={tool.toolDetails} onOpenLocation={onOpenLocation} />
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}

function InlineMarkdown({ text }: { text: string }) {
  return (
    <>
      {inlineSpans(text).map((span, index) => {
        switch (span.kind) {
          case "strong":
            return <strong key={index}>{span.text}</strong>;
          case "emphasis":
            return <em key={index}>{span.text}</em>;
          case "code":
            return (
              <code key={index} className="rounded bg-muted px-1 font-mono text-[0.92em]">
                {span.text}
              </code>
            );
          case "link":
            return (
              <a
                key={index}
                href={span.href}
                className="text-primary underline"
                onClick={(event) => {
                  event.preventDefault();
                  void openExternalBrowserUrl(span.href);
                }}
              >
                {span.text}
              </a>
            );
          default:
            return <span key={index}>{span.text}</span>;
        }
      })}
    </>
  );
}

function CodeBlock({ language, code }: { language: string; code: string }) {
  const { t } = useTranslation();
  const [didCopy, setDidCopy] = useState(false);
  useEffect(() => {
    if (!didCopy) return;
    const handle = setTimeout(() => setDidCopy(false), 1500);
    return () => clearTimeout(handle);
  }, [didCopy]);
  return (
    <div className="overflow-hidden rounded-md border border-border bg-surface">
      <div className="flex items-center bg-muted/60 px-2.5 py-1">
        <span className="flex-1 font-medium text-[10.5px] text-subtle-foreground">
          {language.length === 0 ? t("agent.transcript.code") : language}
        </span>
        <button
          type="button"
          aria-label={t("agent.transcript.copyCode")}
          title={t("agent.transcript.copyCode")}
          className={didCopy ? "text-success" : "text-subtle-foreground hover:text-foreground"}
          onClick={() => {
            void tryWriteClipboardText(code).then((copied) => setDidCopy(copied));
          }}
        >
          {didCopy ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
        </button>
      </div>
      <pre className="select-text overflow-x-auto p-2.5 font-mono text-[12px] text-foreground">
        {code}
      </pre>
    </div>
  );
}

function MessageRow({
  message,
  onOpenLocation,
}: {
  message: AgentConversationMessage;
  onOpenLocation: (location: AgentToolLocation) => void;
}) {
  if (message.role === "user") {
    return (
      <div className="flex justify-end pl-10">
        <div className="select-text whitespace-pre-wrap break-words rounded-[10px] bg-primary/18 px-3 py-2 text-foreground ui-text-base">
          {message.text}
        </div>
      </div>
    );
  }
  if (message.role === "tool") {
    return <ToolGroup tools={[message]} searchText="" onOpenLocation={onOpenLocation} />;
  }
  return (
    <div className="space-y-2">
      {messageSegments(message.text).map((segment, index) =>
        segment.kind === "code" ? (
          <CodeBlock key={index} language={segment.language} code={segment.code} />
        ) : (
          <div
            key={index}
            className="select-text whitespace-pre-wrap break-words text-foreground ui-text-base"
          >
            <InlineMarkdown text={segment.text} />
          </div>
        ),
      )}
    </div>
  );
}

/** Only this row ticks while waiting; it never republishes the conversation. */
function ThinkingRow({
  isCancelling,
  startedAt,
  now,
}: {
  isCancelling: boolean;
  startedAt: number | null;
  now: () => number;
}) {
  const { t } = useTranslation();
  const [, setTick] = useState(0);
  useEffect(() => {
    const handle = setInterval(() => setTick((value) => value + 1), 1000);
    return () => clearInterval(handle);
  }, []);
  const elapsed = startedAt === null ? null : Math.max(0, (now() - startedAt) / 1000);
  return (
    <div
      className="flex items-center gap-2 pl-0.5 text-subtle-foreground ui-text-sm"
      title={t("agent.turn.elapsedHint")}
    >
      <Spinner className="size-3.5" />
      <span>{isCancelling ? t("agent.transcript.stopping") : t("agent.transcript.thinking")}</span>
      {elapsed === null ? null : <span className="tabular-nums">{durationLabel(elapsed, t)}</span>}
    </div>
  );
}

function TurnStatistics({ turn }: { turn: AgentTurnStatistics }) {
  const { t } = useTranslation();
  const usage = turn.usage;
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-subtle-foreground tabular-nums ui-text-caption">
      <span title={t("agent.turn.elapsedHint")}>
        {t("agent.turn.elapsed", { duration: durationLabel(turnElapsed(turn, 0), t) })}
      </span>
      {usage === null ? null : (
        <span className="flex flex-wrap gap-x-2.5" title={usageDetails(usage, t)}>
          <span>{t("agent.turn.input", { count: usage.inputTokens.toLocaleString() })}</span>
          <span>{t("agent.turn.output", { count: usage.outputTokens.toLocaleString() })}</span>
        </span>
      )}
    </div>
  );
}

/** Docked below the transcript so the choice is always visible. */
function PermissionCard({
  prompt,
  onAnswer,
  onOpenLocation,
}: {
  prompt: AgentPermissionPrompt;
  onAnswer: (optionID: string | null) => void;
  onOpenLocation: (location: AgentToolLocation) => void;
}) {
  const { t } = useTranslation();
  const offersReject = prompt.choices.some((choice) => choice.kind?.startsWith("reject") === true);
  return (
    <div className="mx-3 mb-2 space-y-2.5 rounded-lg border border-warning/50 bg-surface p-3">
      <div className="flex items-center gap-2 font-semibold text-foreground ui-text-sm">
        <HandIcon className="size-3.5 text-warning" />
        {t("agent.permission.title")}
      </div>
      <div className="select-text font-mono text-[12px] text-foreground">{prompt.title}</div>
      {hasEvidence(prompt.details) ? (
        <div className="max-h-[180px] overflow-y-auto">
          <ToolEvidence details={prompt.details} onOpenLocation={onOpenLocation} />
        </div>
      ) : null}
      <div className="flex flex-col items-start gap-2">
        {prompt.choices.map((choice) => (
          <Button
            key={choice.id}
            type="button"
            size="xs"
            variant={choice.kind?.startsWith("reject") === true ? "danger" : "accent"}
            className="border border-current/30"
            onClick={() => onAnswer(choice.id)}
          >
            {choice.label}
          </Button>
        ))}
        {offersReject ? null : (
          <Button type="button" size="xs" variant="ghost" onClick={() => onAnswer(null)}>
            {t("agent.permission.deny")}
          </Button>
        )}
      </div>
    </div>
  );
}

interface AgentTranscriptProps {
  conversation: AgentConversation | null;
  agentName: string | null;
  agentVersion: string | null;
  pendingPrompt: string | null;
  pendingStartedAt: number | null;
  isCreatingSession: boolean;
  searchText: string;
  now: () => number;
  onSwitchAgent: () => void;
  onOpenLocation: (location: AgentToolLocation) => void;
  onAnswerPermission: (optionID: string | null) => void;
}

/**
 * Message list of the selected conversation, then the pending permission and
 * the activity bar, as `AgentTranscriptView` on macOS.
 */
export function AgentTranscript({
  conversation,
  agentName,
  agentVersion,
  pendingPrompt,
  pendingStartedAt,
  isCreatingSession,
  searchText,
  now,
  onSwitchAgent,
  onOpenLocation,
  onAnswerPermission,
}: AgentTranscriptProps) {
  const { t } = useTranslation();
  const messages = conversation?.messages ?? [];
  const items = useMemo(
    () =>
      groupTranscript(messages, conversation?.completedTurns ?? []).filter((item) =>
        itemMatches(item, searchText),
      ),
    [conversation?.completedTurns, messages, searchText],
  );
  const permission = conversation === null ? null : currentPermission(conversation);
  const isResponding = conversation?.isResponding === true || isCreatingSession;
  const scrollRef = useRef<HTMLDivElement>(null);
  const lastText = messages[messages.length - 1]?.text;
  const turnCount = conversation?.completedTurns.length ?? 0;

  // Follow the reply as it streams, but never move the view while searching.
  useLayoutEffect(() => {
    if (searchText.length > 0) return;
    const element = scrollRef.current;
    if (element !== null) element.scrollTop = element.scrollHeight;
  }, [lastText, messages.length, turnCount, isResponding, searchText]);

  const showHero =
    conversation?.isLoading !== true && messages.length === 0 && pendingPrompt === null;

  return (
    <div className="flex h-full min-h-0 flex-col">
      {showHero ? (
        <AgentHero
          agentName={agentName}
          agentVersion={agentVersion}
          onSwitchAgent={onSwitchAgent}
        />
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto">
          <div className="flex flex-col gap-3.5 p-3">
            {conversation?.isLoading === true ? (
              <div className="flex items-center gap-2 text-subtle-foreground ui-text-sm">
                <Spinner className="size-3.5" />
                {t("agent.transcript.loading")}
              </div>
            ) : null}
            {searchText.length > 0 && items.length === 0 ? (
              <div className="text-subtle-foreground ui-text-sm">
                {t("agent.transcript.noMatch")}
              </div>
            ) : null}
            {items.map((item) => {
              switch (item.kind) {
                case "message":
                  return (
                    <MessageRow
                      key={item.id}
                      message={item.message}
                      onOpenLocation={onOpenLocation}
                    />
                  );
                case "toolGroup":
                  return (
                    <ToolGroup
                      key={item.id}
                      tools={item.tools}
                      searchText={searchText}
                      onOpenLocation={onOpenLocation}
                    />
                  );
                case "turnSummary":
                  return <TurnStatistics key={item.id} turn={item.turn} />;
              }
            })}
            {conversation === null && pendingPrompt !== null ? (
              <MessageRow
                message={{
                  id: "pending",
                  role: "user",
                  text: pendingPrompt,
                  toolStatus: null,
                  toolDetails: {
                    kind: null,
                    input: null,
                    output: null,
                    locations: [],
                    content: [],
                  },
                }}
                onOpenLocation={onOpenLocation}
              />
            ) : null}
            {isResponding ? (
              <ThinkingRow
                isCancelling={conversation?.isCancelling === true}
                startedAt={conversation?.activeTurn?.startedAt ?? pendingStartedAt}
                now={now}
              />
            ) : null}
          </div>
        </div>
      )}
      {permission === null ? null : (
        <PermissionCard
          prompt={permission}
          onAnswer={onAnswerPermission}
          onOpenLocation={onOpenLocation}
        />
      )}
      <AgentActivitySummaryBar messages={messages} />
    </div>
  );
}
