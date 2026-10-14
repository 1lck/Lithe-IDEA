import SettingsSelect from "@/ui/settings-select";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { useRepositoryStore } from "@/features/git/stores/git-repository.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useSettingsStore } from "../stores/settings.store";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { Checkbox } from "@/ui/checkbox";
import Section from "./settings-section";

type Field = { key: string; choices: string[]; configuredValues: string[] };
type Snapshot = {
  executable: string | null;
  version: string;
  scope: string;
  fields: Field[];
  temporaryConfig: string[][];
  entries: { key: string; value: string; origin: string; scope: string; effective: boolean }[];
  fetchOptions?: { prune: boolean; submodules: string; tags: string };
  fetchSources?: Record<string, { scope: string; origin: string | null }>;
  fetchError?: { message: string } | null;
};
export function GitExecutionSettings() {
  const { t } = useTranslation();
  const activeRoot = useRepositoryStore.use.activeRepoPath();
  const workspace = useProjectStore((state) => state.rootFolderPath);
  const root = activeRoot ?? workspace;
  const executable = useSettingsStore((state) => state.settings.gitExecutable);
  const fetchPrune = useSettingsStore((state) => state.settings.gitFetchPrune);
  const fetchSubmodules = useSettingsStore((state) => state.settings.gitFetchSubmodules);
  const fetchTags = useSettingsStore((state) => state.settings.gitFetchTags);
  const helper = useSettingsStore((state) => state.settings.gitUseCredentialHelper);
  const update = useSettingsStore((state) => state.actions.updateSetting);
  const [path, setPath] = useState(executable);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [scope, setScope] = useState("local");
  const [key, setKey] = useState("lithe.fetch.prune");
  const [value, setValue] = useState("");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0);
  const [saved, setSaved] = useState(false);
  const generation = useRef(0);
  const field = snapshot?.fields.find((item) => item.key === key);
  useEffect(() => {
    setPath(executable);
  }, [executable]);
  useEffect(() => {
    setValue(field?.configuredValues[field.configuredValues.length - 1] ?? "");
  }, [field]);
  useEffect(() => {
    const current = ++generation.current;
    setSnapshot(null);
    setError("");
    setSaved(false);
    setBusy(advancedOpen && !!root);
    if (advancedOpen && root)
      void invoke<Snapshot>("git.executionInspect", { root, scope })
        .then((result) => {
          if (generation.current === current) setSnapshot(result);
        })
        .catch((error: unknown) => {
          if (generation.current === current) setError(String(error));
        })
        .finally(() => {
          if (generation.current === current) setBusy(false);
        });
    return () => {
      generation.current++;
    };
  }, [
    advancedOpen,
    root,
    scope,
    executable,
    helper,
    fetchPrune,
    fetchSubmodules,
    fetchTags,
    reload,
  ]);
  async function save(value: string | null) {
    if (!root || !field || busy) return;
    const current = ++generation.current;
    setBusy(true);
    setError("");
    setSaved(false);
    try {
      const result = await invoke<Snapshot>("git.executionConfigure", {
        root,
        scope,
        key: field.key,
        value,
        expectedValues: field.configuredValues,
      });
      if (generation.current === current) {
        setSnapshot(result);
        setSaved(true);
      }
    } catch (error) {
      if (generation.current === current) setError(String(error));
    } finally {
      if (generation.current === current) setBusy(false);
    }
  }
  return (
    <Section title={t("git.execution.title")}>
      <label className="text-sm">{t("git.execution.executable")}</label>
      <div className="flex gap-2">
        <Input
          value={path}
          onChange={(event) => setPath(event.target.value)}
          placeholder={t("git.execution.pathDefault")}
        />
        <Button
          disabled={path === executable}
          onClick={() => void update("gitExecutable", path.trim())}
        >
          {t("git.execution.save")}
        </Button>
        <Button onClick={() => void update("gitExecutable", "")}>
          {t("git.execution.pathDefault")}
        </Button>
      </div>
      <label className="flex items-center gap-2 text-sm">
        <Checkbox
          checked={helper}
          onCheckedChange={(checked) => void update("gitUseCredentialHelper", checked)}
        />
        {t("git.execution.helper")}
      </label>
      <p className="text-xs text-subtle-foreground">{t("git.execution.credentials")}</p>
      <details
        className="space-y-3"
        open={advancedOpen}
        onToggle={(event) => setAdvancedOpen(event.currentTarget.open)}
      >
        <summary className="cursor-pointer text-sm font-medium">
          {t("git.execution.advanced")}
        </summary>
        <h3 className="text-sm font-medium">{t("git.execution.sources")}</h3>
        <p className="text-xs text-subtle-foreground">{t("git.execution.precedence")}</p>
        <SettingsSelect
          aria-label={t("git.setup.scope")}
          value={scope}
          disabled={busy}
          onChange={(selectedValue) => {
            setScope(selectedValue);
            setKey(selectedValue === "local" ? "lithe.fetch.prune" : "fetch.prune");
          }}
          options={[
            { value: "local", label: t("git.setup.local") },
            { value: "global", label: t("git.setup.global") },
          ]}
        />
        {snapshot && (
          <>
            <pre className="whitespace-pre-wrap text-xs">
              {snapshot.version}
              {"\n"}
              {snapshot.executable}
            </pre>
            <p className="text-xs">
              {t("git.execution.temporary")}:{" "}
              {snapshot.temporaryConfig.map((pair) => pair.join("=")).join(", ")}
            </p>
            {snapshot.fetchOptions && (
              <div className="font-mono text-xs">
                <p>{t("git.execution.effectiveFetch")}</p>
                {Object.entries(snapshot.fetchOptions)
                  .filter(([key]) => key !== "remote")
                  .map(([key, value]) => (
                    <p key={key}>
                      {key} = {String(value)} ·{" "}
                      {snapshot.fetchSources?.[key]?.scope ?? "application"} ·{" "}
                      {snapshot.fetchSources?.[key]?.origin ?? "Lithe"}
                    </p>
                  ))}
              </div>
            )}
            {snapshot.fetchError && (
              <p className="text-sm text-destructive">{snapshot.fetchError.message}</p>
            )}
            <SettingsSelect
              aria-label={t("git.execution.key")}
              value={key}
              disabled={busy}
              onChange={(selectedValue) => setKey(selectedValue)}
              options={snapshot.fields.map((field) => ({ value: field.key, label: field.key }))}
            />
            {field && (
              <div className="flex gap-2">
                <SettingsSelect
                  aria-label={t("git.execution.value")}
                  value={value}
                  disabled={busy}
                  onChange={(selectedValue) => setValue(selectedValue)}
                  options={[
                    { value: "", label: t("git.execution.chooseValue") },
                    ...field.choices.map((value) => ({ value, label: value })),
                  ]}
                />
                <Button
                  disabled={
                    busy ||
                    !value ||
                    (field.configuredValues.length === 1 && field.configuredValues[0] === value)
                  }
                  onClick={() => void save(value)}
                >
                  {t("git.execution.save")}
                </Button>
                <Button
                  disabled={busy || !field.configuredValues.length}
                  onClick={() => void save(null)}
                >
                  {t("git.execution.clear")}
                </Button>
              </div>
            )}
            <div className="max-h-64 overflow-auto font-mono text-xs">
              {snapshot.entries.map((entry, index) => (
                <div key={index} className="mb-3 break-words">
                  <p>
                    {entry.key} = {entry.value}
                  </p>
                  <p className="text-subtle-foreground">
                    {entry.scope} · {entry.origin}
                  </p>
                  {!entry.effective && (
                    <p className="text-subtle-foreground">{t("git.execution.overridden")}</p>
                  )}
                </div>
              ))}
            </div>
          </>
        )}
        {saved && <p className="text-sm">{t("git.execution.saved")}</p>}
        {error && <p className="text-sm text-destructive">{error}</p>}
        <Button disabled={busy || !root} onClick={() => setReload((value) => value + 1)}>
          {t("git.execution.reload")}
        </Button>
      </details>
    </Section>
  );
}
