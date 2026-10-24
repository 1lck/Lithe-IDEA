import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import SettingsSelect from "@/ui/settings-select";
import Switch from "@/ui/switch";
import AppDialog, { showConfirmDialog } from "@/ui/dialog";
import { SettingRow } from "../settings-section";
import {
  hookEvents, hookMatchers, hookAgents, manageHooks, validHook,
  type AgentHook, type HookLibrary, type HookEntry,
} from "@/features/agent/services/agent-hooks";

const agentTitle = (id: string) => id === "codex-acp" ? "Codex" : "Claude Code";
function editable(entry: HookEntry): AgentHook {
  const { configuredAgents: _configured, needsSync: _sync, ...hook } = entry;
  return hook;
}

export function AgentHooksSettings() {
  const { t } = useTranslation();
  const [library, setLibrary] = useState<HookLibrary | null>(null);
  const [draft, setDraft] = useState<AgentHook | null>(null);
  const [timeout, setTimeoutText] = useState("");
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const mounted = useRef(false);
  const pending = useRef(false);

  useEffect(() => {
    mounted.current = true;
    let current = true;
    setBusy(true);
    pending.current = true;
    void manageHooks("read").then(result => { if (current) setLibrary(result); })
      .catch(failure => { if (current) setError(String(failure)); })
      .finally(() => { if (current) { setBusy(false); pending.current = false; } });
    return () => { current = false; mounted.current = false; };
  }, []);

  const run = async (action: "read" | "save" | "remove" | "sync", hook?: AgentHook, id?: string) => {
    if (pending.current) return;
    pending.current = true;
    setBusy(true); setError(null);
    try {
      const result = await manageHooks(action, library ?? undefined, hook, id);
      if (mounted.current) { setLibrary(result); if (action === "save") setDraft(null); }
    } catch (failure) { if (mounted.current) setError(t(failure instanceof Error ? failure.message : String(failure))); }
    finally { pending.current = false; if (mounted.current) setBusy(false); }
  };
  const edit = (hook: AgentHook) => { setDraft(hook); setTimeoutText(hook.timeoutSeconds?.toString() ?? ""); };
  const update = <K extends keyof AgentHook>(key: K, value: AgentHook[K]) => setDraft(previous => previous ? { ...previous, [key]: value } : previous);
  const remove = async (hook: HookEntry) => {
    const confirmed = await showConfirmDialog(t("hooks.deleteHint"), { title: t("hooks.deleteTitle"), confirmLabel: t("hooks.delete"), cancelLabel: t("ui.cancel") });
    if (confirmed && mounted.current) await run("remove", undefined, hook.id);
  };
  const timeoutValid = timeout === "" || (/^[0-9]+$/.test(timeout) && Number(timeout) >= 1 && Number(timeout) <= 86400);
  const duplicate = draft && library?.hooks.some(h => h.id !== draft.id && h.name.toLowerCase() === draft.name.toLowerCase());
  return <div className="space-y-3">
    <h2 className="font-medium">{t("settings.tabs.hooks")}</h2>
    <p className="ui-text-sm text-subtle-foreground">{t("hooks.intro")}</p>
    <div className="flex flex-wrap items-center gap-2">
      <Input aria-label={t("hooks.search")} placeholder={t("hooks.search")} value={query} onChange={e => setQuery(e.target.value)} />
      <Button disabled={busy} onClick={() => void run("read")}>{t("hooks.reload")}</Button>
      <Button disabled={busy || !library} onClick={() => edit({ id: crypto.randomUUID(), name: "", description: "", command: "", event: "turn-end", matcher: "all", timeoutSeconds: null, agents: [...hookAgents], enabled: true, pendingRemoval: false })}>{t("hooks.add")}</Button>
    </div>
    {error ? <p role="alert" className="text-warning">{error}</p> : null}
    {library?.targets.map(target => <div key={target.agentId}>
      {target.issue ? <p role="alert" className="text-warning">{agentTitle(target.agentId)}: {t(target.issue)}</p> : null}
      {target.disabled ? <p role="alert" className="text-warning">{t("hooks.disabledAll")}</p> : null}
    </div>)}
    {library?.hooks.some(h => h.needsSync || h.pendingRemoval) ? <Button disabled={busy} onClick={() => void run("sync")}>{t("hooks.retry")}</Button> : null}
    {library?.hooks.length === 0 ? <p className="py-8 text-subtle-foreground">{t("hooks.empty")}</p> : null}
    {library?.hooks.filter(h => [h.name, h.description, h.command].some(value => value.toLowerCase().includes(query.toLowerCase()))).map(hook => <div key={hook.id} className="space-y-2 rounded-md border border-border p-3">
      <div className="flex flex-wrap items-center gap-2">
        <strong title={hook.description}>{hook.name}</strong>
        <span className="ml-auto ui-text-sm text-warning">{hook.pendingRemoval ? t("hooks.pendingRemoval") : hook.needsSync ? t("hooks.needsSync") : ""}</span>
        <Switch aria-label={`${hook.name}: ${t("hooks.enabled")}`} checked={hook.enabled} disabled={busy || hook.pendingRemoval} onChange={enabled => void run("save", { ...editable(hook), enabled })} />
        <Button disabled={busy || hook.pendingRemoval} onClick={() => edit(editable(hook))}>{t("hooks.edit")}</Button>
        <Button disabled={busy} onClick={() => void remove(hook)}>{t("hooks.delete")}</Button>
      </div>
      <p className="ui-text-sm text-subtle-foreground">{t(`hooks.event.${hook.event}`)} · {hook.agents.map(agentTitle).join(" · ")}</p>
      <pre className="whitespace-pre-wrap break-all font-mono ui-text-sm">{hook.command}</pre>
    </div>)}
    <p className="ui-text-sm text-subtle-foreground">{t("hooks.codexApproval")}</p>
    {draft ? <AppDialog title={t("hooks.editor")} onClose={() => { if (!busy) setDraft(null); }} size="lg" footer={<>
      <Button disabled={busy} onClick={() => setDraft(null)}>{t("ui.cancel")}</Button>
      <Button disabled={busy || !validHook(draft) || !timeoutValid || !!duplicate} onClick={() => void run("save", draft)}>{t("hooks.save")}</Button>
    </>}><fieldset disabled={busy} className="space-y-3">
      <SettingRow label={t("hooks.name")} description={t("hooks.nameHint")}><Input value={draft.name} onChange={e => update("name", e.target.value)} /></SettingRow>
      <SettingRow label={t("hooks.description")}><Input maxLength={200} value={draft.description} onChange={e => update("description", e.target.value)} /></SettingRow>
      <SettingRow label={t("hooks.when")}><SettingsSelect value={draft.event} options={hookEvents.map(event => ({ value: event, label: t(`hooks.event.${event}`) }))} onChange={event => setDraft({ ...draft, event: event as AgentHook["event"], matcher: "all" })} /></SettingRow>
      {draft.event === "before-tool" || draft.event === "after-tool" ? <SettingRow label={t("hooks.matcher")}><SettingsSelect value={draft.matcher} options={hookMatchers.map(matcher => ({ value: matcher, label: t(`hooks.matcher.${matcher}`) }))} onChange={matcher => update("matcher", matcher as AgentHook["matcher"])} /></SettingRow> : null}
      <label className="block space-y-1"><span>{t("hooks.command")}</span><Textarea aria-label={t("hooks.command")} rows={4} value={draft.command} onChange={e => update("command", e.target.value)} /></label>
      <SettingRow label={t("hooks.timeout")} description={t("hooks.timeoutHint")}><Input value={timeout} onChange={e => { setTimeoutText(e.target.value); update("timeoutSeconds", e.target.value === "" ? null : Number(e.target.value)); }} /></SettingRow>
      <SettingRow label={t("hooks.agents")}><div className="flex gap-3">{hookAgents.map(agent => <label key={agent} className="flex items-center gap-1"><input type="checkbox" checked={draft.agents.includes(agent)} onChange={e => update("agents", e.target.checked ? [...draft.agents, agent] : draft.agents.filter(id => id !== agent))} />{agentTitle(agent)}</label>)}</div></SettingRow>
      {error ? <p role="alert" className="text-warning">{error}</p> : null}
    </fieldset></AppDialog> : null}
  </div>;
}
