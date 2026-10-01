/**
 * Search and labels for the session selectors, as
 * `AgentSessionSelectorPresentation` on macOS. The Agent still owns option ids,
 * choices and confirmed values; this only decides how they read.
 */

import type { AgentSessionConfigChoice, AgentSessionConfigOption } from "../types/agent.types";

/**
 * Chinese names for the option and choice labels Codex and Claude report, the
 * same entries macOS resolves through `String(localized:)`. A label that is not
 * listed is shown as the Agent sent it.
 */
const ZH_AGENT_LABELS: Record<string, string> = {
  "Approval mode": "权限模式",
  "Ask for approval": "请求批准",
  "Approve for me": "替我审批",
  "Full access": "完全访问",
  "Read-only": "只读",
  "Always ask to edit external files and use the internet":
    "修改工作区外文件或访问网络时先请求批准。",
  "Only ask for actions detected as potentially unsafe":
    "自动审批，仅在检测到潜在风险时请求你的确认。",
  "Unrestricted access to the internet and any file on your computer":
    "允许访问网络和电脑上的所有文件。",
  "Collaboration mode": "协作模式",
  Default: "默认",
  Plan: "计划",
  "Plan before making changes": "先制定计划，再进行修改。",
  "Reasoning effort": "推理强度",
  "Fast mode": "快速模式",
  Low: "低",
  Medium: "中",
  High: "高",
  XHigh: "超高",
  Max: "最大",
  "None (fastest)": "无（最快）",
  "Low (recommended)": "低（推荐）",
  Model: "模型",
};

export interface AgentSelectorLabels {
  language: "en-US" | "zh-CN";
  thinkingLevel: string;
  speed: string;
  standard: string;
  fast: string;
}

export function localizedAgentLabel(text: string, labels: AgentSelectorLabels): string {
  return labels.language === "zh-CN" ? (ZH_AGENT_LABELS[text] ?? text) : text;
}

export function filteredChoices(
  option: AgentSessionConfigOption,
  query: string,
): AgentSessionConfigChoice[] {
  const needle = query.trim().toLocaleLowerCase();
  if (needle.length === 0) return option.choices;
  return option.choices.filter((choice) =>
    [choice.name, choice.id, choice.group ?? ""].some((value) =>
      value.toLocaleLowerCase().includes(needle),
    ),
  );
}

export function optionTitle(option: AgentSessionConfigOption, labels: AgentSelectorLabels): string {
  if (option.category === "thought_level") return labels.thinkingLevel;
  if (option.id === "fast-mode") return labels.speed;
  return localizedAgentLabel(option.name, labels);
}

export function choiceTitle(
  choice: AgentSessionConfigChoice,
  option: AgentSessionConfigOption,
  labels: AgentSelectorLabels,
): string {
  if (option.id === "fast-mode") {
    if (choice.id === "off") return labels.standard;
    if (choice.id === "on") return labels.fast;
  }
  return option.category === "model" ? choice.name : localizedAgentLabel(choice.name, labels);
}

export function currentChoiceTitle(
  option: AgentSessionConfigOption,
  labels: AgentSelectorLabels,
): string {
  const current = option.choices.find((choice) => choice.id === option.currentValue);
  return current === undefined ? option.currentValue : choiceTitle(current, option, labels);
}

/**
 * The model, the approval mode, and the remaining settings ordered as macOS:
 * model configuration, then thinking level, then everything else.
 */
export function partitionOptions(options: AgentSessionConfigOption[]) {
  const model = options.find((option) => option.category === "model") ?? null;
  const mode = options.find((option) => option.category === "mode") ?? null;
  const remaining = options.filter((option) => option !== model && option !== mode);
  const settings = [
    ...remaining.filter((option) => option.category === "model_config"),
    ...remaining.filter((option) => option.category === "thought_level"),
    ...remaining.filter(
      (option) => option.category !== "model_config" && option.category !== "thought_level",
    ),
  ];
  return { model, mode, settings };
}

/** Model label with the current thinking level, e.g. `gpt-5.5 High`. */
export function modelSummary(
  model: AgentSessionConfigOption,
  options: AgentSessionConfigOption[],
  labels: AgentSelectorLabels,
): string {
  const effort = options.find((option) => option.category === "thought_level");
  return [
    currentChoiceTitle(model, labels),
    effort === undefined ? null : currentChoiceTitle(effort, labels),
  ]
    .filter((part): part is string => part !== null)
    .join(" ");
}

/** Context tooltip: `上下文: 0.0%` until usage exists, then `12.3% · 45.6k / 200k`. */
export function contextUsageDetails(
  usage: { usedTokens: number; capacityTokens: number; fraction: number } | null,
  format: {
    percent: (fraction: number, digits: number) => string;
    placeholder: (percent: string) => string;
    tokens: (percent: string, used: string, capacity: string) => string;
  },
): string {
  if (usage === null || usage.usedTokens <= 0) {
    return format.placeholder(format.percent(usage?.fraction ?? 0, 1));
  }
  const tokens = (count: number) =>
    count >= 1_000 ? `${Number((count / 1_000).toFixed(1))}k` : String(count);
  return format.tokens(
    format.percent(usage.fraction, 1),
    tokens(usage.usedTokens),
    tokens(usage.capacityTokens),
  );
}

/** `5h`, `7d` or `90m`, exactly as the macOS quota label names its windows. */
export function quotaWindowLabel(seconds: number): string {
  if (seconds % 86_400 === 0) return `${seconds / 86_400}d`;
  if (seconds % 3_600 === 0) return `${seconds / 3_600}h`;
  return `${Math.floor(seconds / 60)}m`;
}
