import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  ArrowsClockwiseIcon,
  CaretDownIcon,
  CaretRightIcon,
  CaretUpIcon,
  CheckCircleIcon,
  CheckIcon,
  CircleIcon,
  ClipboardTextIcon,
  CopyIcon,
  FileTextIcon,
  HandIcon,
  ListChecksIcon,
  PencilSimpleIcon,
  PulseIcon,
  WarningIcon,
} from "@/ui/icons";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/ui/hover-card";
import { Spinner } from "@/ui/spinner";
import MarkdownRenderer from "@/features/ai/components/messages/markdown-renderer";
import { cn } from "@/utils/cn";
import { classifyMarkdownLink } from "@/utils/markdown-links";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { useAgentSurfaceStore } from "../stores/agent-surface.store";
import {
  transcriptNavigation,
  type AgentTranscriptNavigationEntry,
} from "../services/agent-transcript-navigation";
import {
  activitySummary,
  groupTranscript,
  itemMatches,
  toolMatches,
} from "../services/agent-transcript-items";
import {
  currentPermission,
  planProgress,
  type AgentConversation,
  type AgentConversationMessage,
  type AgentMessageDelivery,
  type AgentPermissionPrompt,
  type AgentPlanEntry,
  type AgentPlanStatus,
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

/** Agent-reported plan above the activity bar, collapsed to progress by default. */
export function AgentPlanPanel({
  plan,
  isResponding,
}: {
  plan: AgentPlanEntry[];
  isResponding: boolean;
}) {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState(false);
  if (plan.length === 0) return null;
  const progress = planProgress(plan);
  const isComplete = progress.total > 0 && progress.completed === progress.total;
  return (
    <div className="mx-[18px] mb-1 shrink-0 overflow-hidden rounded-[5px] border border-border bg-surface">
      <button
        type="button"
        aria-expanded={expanded}
        title={expanded ? t("agent.plan.collapse") : t("agent.plan.expand")}
        className="flex h-7 w-full items-center gap-[7px] px-2.5 text-left text-foreground ui-text-caption"
        onClick={() => setExpanded((value) => !value)}
      >
        <ClipboardTextIcon
          className={cn("size-3 shrink-0", isComplete ? "text-success" : "text-primary")}
        />
        <span className="shrink-0 font-semibold tabular-nums">
          {t("agent.plan.progress", {
            completed: progress.completed,
            total: progress.total,
          })}
        </span>
        {expanded || progress.current === null ? null : (
          <span className="min-w-0 flex-1 truncate text-subtle-foreground">
            {progress.current}
          </span>
        )}
        <span className="ml-auto shrink-0">
          {expanded ? <CaretDownIcon className="size-3" /> : <CaretUpIcon className="size-3" />}
        </span>
      </button>
      {expanded ? (
        <ul className="max-h-[180px] space-y-1.5 overflow-y-auto border-t border-border px-2.5 py-2">
          {plan.map((entry, index) => (
            <li
              key={`${index}:${entry.content}`}
              aria-label={`${t(statusLabel(entry.status))}: ${entry.content}`}
              className="flex items-start gap-[7px] ui-text-caption"
            >
              <PlanEntryIcon status={entry.status} isResponding={isResponding} />
              <span
                className={cn(
                  "min-w-0 break-words",
                  entry.status === "completed"
                    ? "text-subtle-foreground line-through"
                    : "text-foreground",
                )}
              >
                {entry.content}
              </span>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function statusLabel(status: AgentPlanStatus) {
  if (status === "completed") return "agent.plan.completed" as const;
  if (status === "in_progress") return "agent.plan.running" as const;
  return "agent.plan.pending" as const;
}

/** Completed steps use a success check, running steps a ring, pending an open circle. */
function PlanEntryIcon({
  status,
  isResponding,
}: {
  status: AgentPlanStatus;
  isResponding: boolean;
}) {
  if (status === "completed") {
    return <CheckCircleIcon className="mt-px size-3 shrink-0 text-success" />;
  }
  if (status === "in_progress") {
    if (isResponding) {
      return <CircleIcon className="mt-px size-3 shrink-0 text-primary" />;
    }
    return (
      <span
        aria-hidden="true"
        className="mt-px size-3 shrink-0 rounded-full border border-primary text-primary"
        style={{ backgroundImage: "linear-gradient(90deg, currentColor 50%, transparent 50%)" }}
      />
    );
  }
  return (
    <span
      aria-hidden="true"
      className="mt-px size-3 shrink-0 rounded-full border border-subtle-foreground/60"
    />
  );
}

/**
 * Reasoning stays a quiet summary line over a rounded Markdown card. It opens
 * while it streams or the user asks, and a matching search keeps it open.
 */
function ReasoningRow({
  text,
  isStreaming = false,
  isSearching = false,
  expandedKey,
  onOpenLocation,
}: {
  text: string;
  isStreaming?: boolean;
  isSearching?: boolean;
  expandedKey: string;
  onOpenLocation: (location: AgentToolLocation) => void;
}) {
  const { t } = useTranslation();
  const manualExpanded = useAgentSurfaceStore((state) => state.reasoningExpanded[expandedKey]);
  const setReasoningExpanded = useAgentSurfaceStore(
    (state) => state.actions.setReasoningExpanded,
  );
  const expanded = isSearching || (manualExpanded ?? isStreaming);
  const scrollRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!isStreaming || !expanded) return;
    const element = scrollRef.current;
    if (element !== null) element.scrollTop = element.scrollHeight;
  }, [expanded, isStreaming, text]);
  return (
    <div className="flex flex-col gap-1.5">
      <button
        type="button"
        aria-expanded={expanded}
        title={expanded ? t("agent.transcript.hideReasoning") : t("agent.transcript.showReasoning")}
        className="flex w-fit items-center gap-[5px] py-0.5 text-left text-subtle-foreground ui-text-caption hover:text-foreground"
        onClick={() => {
          // A matching search must keep its text visible, including after a click.
          if (isSearching) return;
          setReasoningExpanded(expandedKey, !expanded);
        }}
      >
        {isStreaming ? <Spinner className="size-3 shrink-0" /> : null}
        <span>
          {isStreaming ? t("agent.transcript.thinking") : t("agent.transcript.reasoning")}
        </span>
        <CaretDownIcon
          className={cn("size-2.5 shrink-0 transition-transform", !expanded && "-rotate-90")}
        />
      </button>
      {expanded ? (
        <div
          ref={scrollRef}
          className="max-h-60 select-text overflow-y-auto rounded-[8px] border border-border bg-surface/50 px-3 py-2.5 text-subtle-foreground ui-text-caption"
        >
          <div className="space-y-2 select-text">
            <MarkdownRenderer
              content={text.trim()}
              showLinkIcons
              onOpenLink={(href) => openAgentLink(href, onOpenLocation)}
            />
          </div>
        </div>
      ) : null}
    </div>
  );
}

/**
 * Workspace file links open in the editor; web and GitHub links keep the
 * shared opener the AI chat uses. Mirrors `AgentMarkdownLink` handling on macOS.
 */
function openAgentLink(
  href: string,
  onOpenLocation: (location: AgentToolLocation) => void,
): boolean {
  const target = classifyMarkdownLink(href);
  if (target.kind !== "file") return false;
  onOpenLocation({ path: target.path, line: target.line });
  return true;
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

function deliveryLabel(delivery: AgentMessageDelivery, t: Translate): string {
  if (delivery === "sending") return t("agent.composer.sending");
  if (delivery === "received") return t("agent.composer.received");
  switch (delivery.failed) {
    case "The Agent is not connected.":
      return t("agent.error.notConnected");
    case "The Agent connection closed.":
      return t("agent.composer.connectionClosed");
    case "Supplementary message cancelled.":
      return t("agent.composer.supplementCancelled");
    case "The Agent did not accept the supplementary message.":
    case "The Agent did not accept the supplementary message":
      return t("agent.composer.supplementRejected");
    default:
      return delivery.failed;
  }
}

function MessageRow({
  message,
  sessionID,
  onOpenLocation,
  searchText = "",
  isStreaming = false,
}: {
  message: AgentConversationMessage;
  sessionID: string | null;
  onOpenLocation: (location: AgentToolLocation) => void;
  searchText?: string;
  isStreaming?: boolean;
}) {
  const { t } = useTranslation();
  if (message.role === "user") {
    return (
      <div className="flex justify-end pl-10">
        <div className="flex flex-col items-end">
          <div className="select-text whitespace-pre-wrap break-words rounded-[10px] bg-primary/18 px-3 py-2 text-foreground ui-text-base">
            {message.text}
          </div>
          {message.delivery === null ? null : (
            <div
              className={cn(
                "mt-1 max-w-full break-words text-right text-[10px]",
                typeof message.delivery === "object"
                  ? "text-destructive"
                  : "text-subtle-foreground",
              )}
            >
              {deliveryLabel(message.delivery, t)}
            </div>
          )}
        </div>
      </div>
    );
  }
  if (message.role === "tool") {
    return <ToolGroup tools={[message]} searchText="" onOpenLocation={onOpenLocation} />;
  }
  if (message.role === "reasoning") {
    const needle = searchText.toLocaleLowerCase();
    return (
      <ReasoningRow
        text={message.text}
        expandedKey={`${sessionID ?? "pending"}:${message.id}`}
        onOpenLocation={onOpenLocation}
        isStreaming={isStreaming}
        isSearching={needle.length > 0 && message.text.toLocaleLowerCase().includes(needle)}
      />
    );
  }
  return (
    <div className="select-text text-foreground ui-text-base">
      <MarkdownRenderer
        content={message.text}
        showLinkIcons
        copyableTables
        onOpenLink={(href) => openAgentLink(href, onOpenLocation)}
      />
    </div>
  )
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

/** `25K`/`1.2M`, matching `AgentSessionStatusPresentation.compactTokens`. */
function compactTokens(count: number): string {
  if (count >= 1_000_000) return (count / 1_000_000).toFixed(1).replace(/\.0$/, "") + "M";
  if (count >= 1_000) return (count / 1_000).toFixed(1).replace(/\.0$/, "") + "K";
  return count.toLocaleString();
}

/** `14:03` for a turn that ended today, `2026-10-15 14:03` otherwise. */
function completionTime(at: number): string {
  const date = new Date(at);
  const now = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  const time = pad(date.getHours()) + ":" + pad(date.getMinutes());
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  return sameDay
    ? time
    : date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + time;
}

/**
 * One frozen footer per locally observed turn, including failed or cancelled
 * turns. Copy, a compact usage pill and the completion time stay visible; the
 * full breakdown appears only in the pill's hover card, as on macOS.
 */
function TurnStatistics({ turn, reply }: { turn: AgentTurnStatistics; reply: string }) {
  const { t } = useTranslation();
  const [didCopy, setDidCopy] = useState(false);
  useEffect(() => {
    if (!didCopy) return;
    const handle = setTimeout(() => setDidCopy(false), 1500);
    return () => clearTimeout(handle);
  }, [didCopy]);
  const usage = turn.usage;
  const elapsed = durationLabel(turnElapsed(turn, 0), t);
  const pill = usage === null ? elapsed : elapsed + " · " + compactTokens(usage.totalTokens) + " tok";
  const details = usage === null ? t("agent.turn.elapsedHint") : usageDetails(usage, t);
  return (
    <div className="flex items-center gap-2 text-subtle-foreground tabular-nums ui-text-caption">
      {reply.length === 0 ? null : (
        <button
          type="button"
          aria-label={t("agent.transcript.copyReply")}
          title={t("agent.transcript.copyReply")}
          className={didCopy ? "text-success" : "text-subtle-foreground hover:text-foreground"}
          onClick={() => void tryWriteClipboardText(reply).then(setDidCopy)}
        >
          {didCopy ? <CheckIcon className="size-3" /> : <CopyIcon className="size-3" />}
        </button>
      )}
      <HoverCard>
        <HoverCardTrigger
          render={<button type="button" />}
          className="flex items-center gap-1 rounded-full bg-muted/60 px-1.5 py-0.5"
          title={details}
        >
          <PulseIcon className="size-3" />
          <span>{pill}</span>
        </HoverCardTrigger>
        <HoverCardContent side="top" align="start" className="w-64">
          <div className="space-y-1">
            <div className="font-medium text-foreground">{t("agent.turn.thisTurn")}</div>
            <div className="flex justify-between gap-3">
              <span>{t("agent.turn.elapsedLabel")}</span>
              <span className="tabular-nums text-foreground">{elapsed}</span>
            </div>
            {usage === null ? null : (
              <>
                <div className="flex justify-between gap-3">
                  <span>{t("agent.turn.inputLabel")}</span>
                  <span className="tabular-nums text-foreground">
                    {usage.inputTokens.toLocaleString()}
                  </span>
                </div>
                <div className="flex justify-between gap-3">
                  <span>{t("agent.turn.outputLabel")}</span>
                  <span className="tabular-nums text-foreground">
                    {usage.outputTokens.toLocaleString()}
                  </span>
                </div>
                {usage.thoughtTokens === null ? null : (
                  <div className="flex justify-between gap-3">
                    <span>{t("agent.turn.reasoningLabel")}</span>
                    <span className="tabular-nums text-foreground">
                      {usage.thoughtTokens.toLocaleString()}
                    </span>
                  </div>
                )}
                {usage.cachedReadTokens === null ? null : (
                  <div className="flex justify-between gap-3">
                    <span>{t("agent.turn.cacheReadLabel")}</span>
                    <span className="tabular-nums text-foreground">
                      {usage.cachedReadTokens.toLocaleString()}
                    </span>
                  </div>
                )}
                {usage.cachedWriteTokens === null ? null : (
                  <div className="flex justify-between gap-3">
                    <span>{t("agent.turn.cacheWriteLabel")}</span>
                    <span className="tabular-nums text-foreground">
                      {usage.cachedWriteTokens.toLocaleString()}
                    </span>
                  </div>
                )}
                <div className="flex justify-between gap-3">
                  <span>{t("agent.turn.totalLabel")}</span>
                  <span className="tabular-nums text-foreground">
                    {usage.totalTokens.toLocaleString()}
                  </span>
                </div>
                <div className="pt-1 text-subtle-foreground">{t("agent.turn.usageHint")}</div>
              </>
            )}
          </div>
        </HoverCardContent>
      </HoverCard>
      {turn.completedAt === null ? null : (
        <span title={new Date(turn.completedAt).toLocaleString()}>
          {completionTime(turn.completedAt)}
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

/**
 * Narrow rail on the right edge of the transcript, as
 * `AgentTranscriptNavigationRail` on macOS. Ticks stay invisible until the
 * pointer or keyboard focus enters the rail; the turns currently in view are
 * wider and brighter. Hovering a tick previews that turn's prompt and reply.
 */
function AgentTranscriptNavigationRail({
  entries,
  visibleTurnIDs,
  onSelect,
}: {
  entries: AgentTranscriptNavigationEntry[];
  visibleTurnIDs: Set<string>;
  onSelect: (id: string) => void;
}) {
  return (
    <div className="group/rail absolute inset-y-0 right-0 z-10 flex w-8 flex-col items-end justify-center">
      <div className="flex max-h-full flex-col overflow-y-auto py-2 opacity-0 transition-opacity focus-within:opacity-100 group-hover/rail:opacity-100 [scrollbar-width:none]">
        {entries.map((entry) => (
          <HoverCard key={entry.id}>
            <HoverCardTrigger
              render={<button type="button" />}
              aria-label={entry.prompt}
              className="flex h-5 w-7 shrink-0 items-center justify-end"
              onClick={() => onSelect(entry.id)}
            >
              <span
                className={cn(
                  "h-0.5 rounded-full transition-all",
                  visibleTurnIDs.has(entry.id)
                    ? "w-6 bg-foreground/70"
                    : "w-3 bg-subtle-foreground/40",
                )}
              />
            </HoverCardTrigger>
            <HoverCardContent side="left" align="center" className="w-72">
              <div className="space-y-2">
                <div className="line-clamp-2 font-medium text-foreground">{entry.prompt}</div>
                {entry.reply.length === 0 ? null : (
                  <div className="line-clamp-4 text-subtle-foreground">{entry.reply}</div>
                )}
              </div>
            </HoverCardContent>
          </HoverCard>
        ))}
      </div>
    </div>
  );
}
interface AgentTranscriptProps {
  conversation: AgentConversation | null;
  sessionID: string | null;
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
  sessionID,
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
  const scrollRef = useRef<HTMLDivElement>(null);
  const items = useMemo(
    () =>
      groupTranscript(messages, conversation?.completedTurns ?? []).filter((item) =>
        itemMatches(item, searchText),
      ),
    [conversation?.completedTurns, messages, searchText],
  );
  const navigation = useMemo(() => transcriptNavigation(messages), [messages]);
  const [visibleTurnIDs, setVisibleTurnIDs] = useState<Set<string>>(() => new Set());
  const navigationKey = navigation.entries.map((entry) => entry.id).join("|");

  // Only the rail observes viewport geometry; streamed text never republishes it.
  useEffect(() => {
    const root = scrollRef.current;
    if (root === null) return;
    const nodes = Array.from(root.querySelectorAll<HTMLElement>("[data-agent-turn-id]"));
    const observer = new IntersectionObserver(
      (observed) => {
        setVisibleTurnIDs((current) => {
          const next = new Set(current);
          for (const entry of observed) {
            const id = (entry.target as HTMLElement).dataset.agentTurnId;
            if (id === undefined) continue;
            if (entry.isIntersecting) next.add(id);
            else next.delete(id);
          }
          return next;
        });
      },
      { root, rootMargin: "-1px 0px -1px 0px", threshold: 0 },
    );
    for (const node of nodes) observer.observe(node);
    return () => observer.disconnect();
  }, [navigationKey, searchText]);

  const permission = conversation === null ? null : currentPermission(conversation);
  const isResponding = conversation?.isResponding === true || isCreatingSession;
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
        <div className="relative flex min-h-0 flex-1">
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
                    <div
                      key={item.id}
                      data-agent-turn-id={
                        item.message.role === "user" ? item.message.id : undefined
                      }
                    >
                      <MessageRow
                        message={item.message}
                        sessionID={sessionID}
                        searchText={searchText}
                        isStreaming={
                          conversation?.isResponding === true &&
                          item.message.id === messages[messages.length - 1]?.id
                        }
                        onOpenLocation={onOpenLocation}
                      />
                    </div>
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
                  return <TurnStatistics key={item.id} turn={item.turn} reply={item.reply} />;
              }
            })}
            {conversation === null && pendingPrompt !== null ? (
              <MessageRow
                message={{
                  id: "pending",
                  role: "user",
                  text: pendingPrompt,
                  delivery: null,
                  toolStatus: null,
                  toolDetails: {
                    kind: null,
                    input: null,
                    output: null,
                    locations: [],
                    content: [],
                  },
                }}
                sessionID={sessionID}
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
          <AgentTranscriptNavigationRail
            entries={navigation.entries}
            visibleTurnIDs={visibleTurnIDs}
            onSelect={(id) => {
              const target = scrollRef.current?.querySelector<HTMLElement>(
                '[data-agent-turn-id="' + id + '"]',
              );
              target?.scrollIntoView({ block: "start", behavior: "smooth" });
            }}
          />        </div>
      )}
      {permission === null ? null : (
        <PermissionCard
          prompt={permission}
          onAnswer={onAnswerPermission}
          onOpenLocation={onOpenLocation}
        />
      )}
      {conversation === null ? null : (
        <AgentPlanPanel plan={conversation.plan} isResponding={isResponding} />
      )}
      <AgentActivitySummaryBar messages={messages} />
    </div>
  );
}
