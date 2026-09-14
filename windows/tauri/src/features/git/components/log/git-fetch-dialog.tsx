import { useEffect, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";

import type { GitFetchOptions } from "../../api/git-remotes-api";
type Plan = { options: GitFetchOptions; arguments: string[]; commands?: string[][] };
export function GitFetchDialog({ root, onClose, onFetch }: {
  root: string; onClose: () => void; onFetch: (options: GitFetchOptions) => void;
}) {
  const { t } = useTranslation();
  const [options, setOptions] = useState<GitFetchOptions | null>(null);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let current = true;
    void invoke<{ fetchOptions: GitFetchOptions | null; fetchError?: { message: string } }>("git.executionInspect", { root }).then((snapshot) => {
      if (!current) return;
      if (snapshot.fetchOptions) setOptions(snapshot.fetchOptions);
      else setError(snapshot.fetchError?.message ?? t("git.fetchFailed"));
    }).catch((error: unknown) => { if (current) setError(String(error)); });
    return () => { current = false; };
  }, [root, t]);
  useEffect(() => {
    if (!options) return;
    let current = true;
    setPlan(null); setError("");
    void invoke<Plan>("git.fetchPlan", { root, options }).then((plan) => { if (current) setPlan(plan); })
      .catch((error: unknown) => { if (current) setError(String(error)); });
    return () => { current = false; };
  }, [root, options]);
  const ready = plan && options && plan.options.remote === options.remote && plan.options.prune === options.prune && plan.options.submodules === options.submodules && plan.options.tags === options.tags;
  // Display argument boundaries without treating the preview as an executable shell script.
  const format = (args: string[]) => ["git", ...args.map((arg) => /^[a-zA-Z0-9_./=:-]+$/.test(arg) ? arg : JSON.stringify(arg))].join(" ");
  return <AppDialog title={t("git.fetch.options")} onClose={onClose} size="lg" footer={<>
    <Button onClick={onClose}>{t("git.console.cancel")}</Button>
    <Button disabled={!ready || !options} onClick={() => { if (ready && options) onFetch(options); }}>{t("git.fetch")}</Button>
  </>}>
    <div className="flex max-h-[65vh] flex-col gap-3 overflow-auto">
      <p className="break-all text-xs text-subtle-foreground">{root}</p>
      {options && <>
        <label className="flex gap-2 text-sm"><input type="checkbox" checked={options.remote === null} onChange={(event) => setOptions({ ...options, remote: event.target.checked ? null : "" })} />{t("git.fetch.allRemotes")}</label>
        {options.remote !== null && <Input aria-label={t("git.fetch.remoteName")} value={options.remote} onChange={(event) => setOptions({ ...options, remote: event.target.value })} />}
        <label className="flex gap-2 text-sm"><input type="checkbox" checked={options.prune} onChange={(event) => setOptions({ ...options, prune: event.target.checked, tags: !event.target.checked && options.tags === "prune" ? "inherit" : options.tags })} />{t("git.fetch.prune")}</label>
        <label className="flex flex-col gap-1 text-sm">{t("git.fetch.submodules")}<select className="rounded border bg-background p-2" value={options.submodules} onChange={(event) => setOptions({ ...options, submodules: event.target.value as GitFetchOptions["submodules"] })}>
          {(["inherit", "no", "onDemand", "yes"] as const).map((value) => <option key={value} value={value}>{t(`git.fetch.submodules.${value}`)}</option>)}
        </select></label>
        <label className="flex flex-col gap-1 text-sm">{t("git.fetch.tags")}<select className="rounded border bg-background p-2" value={options.tags} onChange={(event) => setOptions({ ...options, tags: event.target.value as GitFetchOptions["tags"], prune: event.target.value === "prune" || options.prune })}>
          {(["inherit", "all", "none", "prune"] as const).map((value) => <option key={value} value={value}>{t(`git.fetch.tags.${value}`)}</option>)}
        </select></label>
      </>}
      <p className="text-xs text-subtle-foreground">{t("git.fetch.oneTime")}</p>
      {ready && plan && <pre className="whitespace-pre-wrap break-all rounded bg-surface p-3 text-xs">{(plan.commands ?? [plan.arguments]).map(format).join("\n")}</pre>}
      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  </AppDialog>;
}
