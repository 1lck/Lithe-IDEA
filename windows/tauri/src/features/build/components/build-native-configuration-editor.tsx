import { useEffect, useState, useSyncExternalStore } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import Switch from "@/ui/switch";
import { Spinner } from "@/ui/spinner";
import { useBuildWorkspace } from "../hooks/use-build-workspace";
import type { BuildEntry } from "../services/build-workspace-controller";
import type { BuildNativeConfiguration } from "../services/build-provider-workspace";
import type { BuildNativeConfigurationController } from "../services/build-native-configuration-controller";

export function nativeConfigurationEntries(entries: BuildEntry[], manifests: Record<string, Record<string, unknown>>, pluginID: string): BuildEntry[] {
  const declarations = manifests[pluginID]?.buildSystems;
  if (!Array.isArray(declarations)) return [];
  return entries.filter(entry => entry.pluginID === pluginID && declarations.some(system => system.id === entry.buildSystemID && system.configuration?.source === "provider"));
}

export function BuildNativeConfigurationSettings({ pluginID }: { pluginID: string }) {
  const { controller, snapshot } = useBuildWorkspace();
  if (!controller) return null;
  return <>{nativeConfigurationEntries(snapshot.entries, snapshot.manifests, pluginID).map(entry => <BuildNativeConfigurationEditor
    key={entry.id} controller={controller.nativeConfiguration(entry)} title={`${entry.displayName} · ${entry.root}`} />)}</>;
}

/** Opening and editing remain read-only until the source's explicit Save.
 * Hiding the settings component retains its draft in the workspace owner. */
export function BuildNativeConfigurationEditor({ controller, title,
  choosePath = (directory: boolean) => open({ directory, multiple: false }),
}: { controller: BuildNativeConfigurationController; title: string; choosePath?: (directory: boolean) => Promise<string | string[] | null> }) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(controller.subscribe, controller.snapshot, controller.snapshot);
  const busy = state.phase === "loading" || state.saving;
  useEffect(() => { if (controller.snapshot().phase === "idle") void controller.read(); }, [controller]);
  return <section className="mt-2 flex flex-col gap-2 border-t border-border pt-2" aria-label={t("native.nativeConfigurationTitle")}>
    <header className="flex items-center gap-2">
      <h4 className="mr-auto ui-text-sm font-semibold">{t("native.nativeConfigurationTitle")} · {title}</h4>
      {busy ? <Spinner compact /> : null}
      <Button size="sm" variant="ghost" disabled={busy} onClick={() => { void controller.read(true); }}>
        {t(state.requiresProjectTool ? "native.nativeConfigurationReadUsingProjectTool" : "native.reload")}
      </Button>
    </header>
    {state.error ? <div role="alert" className="text-destructive ui-text-sm">{state.error}</div> : null}
    {state.stale ? <div role="alert" className="text-warning ui-text-sm">{t("native.nativeConfigurationStale")}</div> : null}
    {!state.configuration && !busy ? <div className="text-subtle-foreground ui-text-sm">{t("native.nativeConfigurationNotRead")}</div> : null}
    {state.configuration?.sources.map(source => <NativeSource key={source.id + ":" + source.revision} source={source} controller={controller}
      busy={busy} stale={state.stale} choosePath={choosePath} />)}
  </section>;
}

function NativeSource({ source, controller, busy, stale, choosePath }: {
  source: BuildNativeConfiguration["sources"][number]; controller: BuildNativeConfigurationController; busy: boolean; stale: boolean;
  choosePath: (directory: boolean) => Promise<string | string[] | null>;
}) {
  const { t } = useTranslation(), state = controller.snapshot();
  const [pickerError, setPickerError] = useState<string>();
  useEffect(() => { setPickerError(undefined); }, [state.configuration]);
  const disabled = busy || stale || !source.writable;
  const dirty = Object.keys(controller.edits(source.id)).length > 0;
  const display = (value: unknown): string => typeof value === "boolean" ? t(value ? "native.on" : "native.off")
    : typeof value === "string" ? value : Array.isArray(value) ? value.join(", ") : "—";
  const choose = async (field: BuildNativeConfiguration["sources"][number]["fields"][number]) => {
    const baseline = state.configuration; setPickerError(undefined);
    try {
      const path = await choosePath(field.kind === "directory");
      if (typeof path === "string" && controller.snapshot().configuration === baseline) controller.set(source.id, field.id, { value: path });
    } catch (error) {
      if (controller.snapshot().configuration === baseline) setPickerError(error instanceof Error ? error.message : String(error));
    }
  };
  return <div role="group" aria-label={source.uri} className="flex flex-col gap-2 rounded border border-border p-2">
    <div className="flex items-center gap-2 ui-text-sm font-medium">
      <span>{t(`native.${source.scope}`)}</span>
      {!source.writable ? <span className="text-subtle-foreground">{t("native.readOnly")}</span> : null}
    </div>
    <div className="flex flex-wrap gap-2 ui-text-sm"><span>{t("native.changesAreWrittenTo")}</span><span className="break-all select-text">{source.uri}</span></div>
    {pickerError ? <div role="alert" className="text-destructive ui-text-sm">{pickerError}</div> : null}
    {source.fields.map(field => {
      const draft = state.drafts[source.id]?.[field.id];
      if (!draft) return null;
      const set = (value: unknown) => controller.set(source.id, field.id, { value });
      const text = Array.isArray(draft.value) ? draft.value.join("\n") : String(draft.value ?? "");
      return <div key={field.id} className="flex flex-col gap-1">
        <div className="flex items-center justify-between gap-2 ui-text-sm"><span>{field.id}</span>
          <label className="flex items-center gap-1"><Checkbox checked={draft.override} disabled={disabled}
            aria-label={`${field.id} ${t("native.override")}`} onCheckedChange={override => controller.set(source.id, field.id, { override })} />{t("native.override")}</label>
        </div>
        {field.kind === "boolean" ? <Switch checked={draft.value === true} onChange={set} disabled={disabled || !draft.override} aria-label={field.id} />
          : field.kind === "stringList" ? <Textarea value={text} disabled={disabled || !draft.override} aria-label={field.id}
            onChange={event => set(event.target.value.split(/\r?\n/).filter(line => line.length > 0))} />
          : <div className="flex items-center gap-1"><Input value={text} disabled={disabled || !draft.override} aria-label={field.id} onChange={event => set(event.target.value)} />
            {field.kind === "file" || field.kind === "directory" ? <Button size="sm" variant="ghost" disabled={disabled || !draft.override}
              onClick={() => { void choose(field); }}>{t("ui.choose")}</Button> : null}
          </div>}
        <div className="flex flex-wrap gap-2 text-subtle-foreground ui-text-sm"><span>{t("native.effectiveValue")}</span>
          <span className="select-text">{display(field.effectiveValue)}</span><span>{field.effectiveSource}</span></div>
      </div>;
    })}
    {source.writable ? <div className="flex justify-end gap-1">
      <Button size="sm" variant="ghost" disabled={!dirty || busy} onClick={() => controller.cancel(source.id)}>{t("ui.cancel")}</Button>
      <Button size="sm" variant="accent" disabled={!dirty || disabled} onClick={() => { void controller.save(source.id); }}>{t("ui.save")}</Button>
    </div> : null}
  </div>;
}
