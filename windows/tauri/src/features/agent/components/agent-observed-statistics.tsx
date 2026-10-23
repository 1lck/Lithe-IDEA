import { useTranslation } from "@/i18n/locale-provider";
import { modelCallTotals, type AgentModelCall, type AgentModelCallTotals } from "../types/agent-observations";

/** Provider observations and ACP counters have different scopes; never sum them. */
export function AgentObservedStatistics({ calls, totals = modelCallTotals(calls) }: { calls: AgentModelCall[]; totals?: AgentModelCallTotals }) {
  const { t, language } = useTranslation();
  if (totals.calls === 0) return null;
  const number = (value: number) => value.toLocaleString(language, { maximumFractionDigits: 1 });
  const rows: [string, string][] = [
    [t("agent.stats.calls"), number(totals.calls)],
    [t("agent.stats.modelTime"), number(totals.durationMs / 1000) + " s"],
  ];
  if (totals.latencyCount > 0) rows.push([t("agent.stats.ttft"), number(totals.latencyMs / totals.latencyCount / 1000) + " s"]);
  if (totals.generatingMs > 0) rows.push([t("agent.stats.tps"), number(totals.streamingOutput / totals.generatingMs * 1000) + " tok/s"]);
  if (totals.nonStreaming > 0) rows.push([t("agent.stats.nonStreaming"), number(totals.nonStreaming)]);
  if (!totals.lowerBound || totals.input + totals.output + totals.cacheRead + totals.cacheWrite > 0) rows.push(
    [t("agent.turn.inputLabel"), number(totals.input)],
    [t("agent.turn.cacheReadLabel"), number(totals.cacheRead)],
    [t("agent.turn.cacheWriteLabel"), number(totals.cacheWrite)],
    [t("agent.turn.outputLabel"), number(totals.output)],
  );
  return <div className="space-y-1 text-subtle-foreground ui-text-caption">
    {rows.map(([label, value]) => <div key={label} className="flex justify-between gap-3"><span>{label}</span><span className="text-foreground tabular-nums">{value}</span></div>)}
    {totals.lowerBound ? <p>{t("agent.stats.lowerBound")}</p> : null}
  </div>;
}

export function AgentContextComposition({ calls }: { calls: AgentModelCall[] }) {
  const { t, language } = useTranslation();
  // Only the latest request describes the current context; billing is cumulative.
  const context = calls[calls.length - 1]?.context;
  if (context == null) return <p className="text-subtle-foreground ui-text-caption">{t("agent.stats.noComposition")}</p>;
  const entries = [
    { key: "system", count: context.systemPromptTokens, color: "bg-primary" },
    { key: "tools", count: context.toolTokens, color: "bg-success" },
    { key: "mcp", count: context.mcpToolTokens, color: "bg-warning" },
    { key: "messages", count: context.messageTokens, color: "bg-subtle-foreground" },
  ];
  const total = entries.reduce((sum, entry) => sum + entry.count, 0);
  return <div className="space-y-2 ui-text-caption">
    <div className="flex h-2 overflow-hidden rounded" aria-hidden>{entries.map((entry) => <span key={entry.key} className={entry.color} style={{ width: `${total === 0 ? 0 : entry.count / total * 100}%` }} />)}</div>
    {entries.map((entry) => <div key={entry.key} title={t(context.scaledToUsage ? "agent.stats.calibrated" : "agent.stats.estimated")} className="flex items-center gap-2"><span className={`size-2 rounded-sm ${entry.color}`} /><span className="flex-1 text-subtle-foreground">{t(`agent.stats.${entry.key}`)}</span><span className="tabular-nums">~{entry.count.toLocaleString(language)}</span></div>)}
    <div className="text-subtle-foreground">{t("agent.stats.toolCount", { tools: context.toolCount, mcp: context.mcpToolCount })}</div>
  </div>;
}
