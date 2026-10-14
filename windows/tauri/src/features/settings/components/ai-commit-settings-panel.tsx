import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import { Checkbox } from "@/ui/checkbox";
import SettingsSelect from "@/ui/settings-select";
import { cloneElement, useEffect, useId, useRef, useState, type ReactElement } from "react";
import { useSettingsStore } from "../stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Section from "./settings-section";
import {
  commitAIError,
  commitKey,
  detectCommitConfigurations,
} from "@/features/git/services/ai-commit-service";
import {
  COMMIT_EFFORTS,
  COMMIT_FORMATS,
  COMMIT_PROTOCOLS,
  newCommitProvider,
  type CommitAISettings,
  type CommitDetection,
  type CommitProvider,
} from "@/features/git/types/ai-commit";

function Field({ label, children }: { label: string; children: ReactElement<{ id?: string }> }) {
  const id = useId();
  return (
    <div className="grid grid-cols-[minmax(110px,150px)_minmax(0,320px)] items-center gap-2">
      <label htmlFor={id}>{label}</label>
      {cloneElement(children, { id })}
    </div>
  );
}

function NumberField({
  label,
  value,
  min,
  max,
  step = 1,
  onCommit,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  onCommit: (value: number) => void;
}) {
  const [draft, setDraft] = useState(String(value));
  useEffect(() => setDraft(String(value)), [value]);
  return (
    <Field label={label}>
      <Input
        type="number"
        min={min}
        max={max}
        step={step}
        className="min-w-0 w-full"
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") e.currentTarget.blur();
        }}
        onBlur={() => {
          const parsed = draft.trim() ? Number(draft) : Number.NaN;
          const next = Number.isFinite(parsed)
            ? Math.min(max, Math.max(min, Math.round(parsed)))
            : value;
          setDraft(String(next));
          onCommit(next);
        }}
      />
    </Field>
  );
}

export function AiCommitSettingsPanel() {
  const customInstructionsId = useId();
  const { t } = useTranslation();
  const settings = useSettingsStore((s) => s.settings.aiCommit);
  const [detection, setDetection] = useState<CommitDetection | null>(null);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [key, setKey] = useState("");
  const [hasKey, setHasKey] = useState(false);
  const [message, setMessage] = useState("");
  const mounted = useRef(true);
  const profileId = useRef(settings.activeProviderId);
  profileId.current = settings.activeProviderId;
  const provider = settings.providers.find((p) => p.id === settings.activeProviderId);
  const managed = provider?.source !== "local";
  const update = (patch: Partial<CommitAISettings>) => {
    const store = useSettingsStore.getState();
    void store.actions.updateSetting("aiCommit", { ...store.settings.aiCommit, ...patch });
  };
  const edit = (patch: Partial<CommitProvider>) =>
    update({
      providers: settings.providers.map((p) => (p.id === provider?.id ? { ...p, ...patch } : p)),
    });

  const reload = async () => {
    setLoading(true);
    try {
      const next = await detectCommitConfigurations();
      if (!mounted.current) return;
      setDetection(next);
      const current = useSettingsStore.getState().settings.aiCommit;
      update({
        providers: current.providers.map((p) => {
          const detected = next.configurations.find((c) => c.provider.source === p.source);
          return p.source !== "local" && detected
            ? { ...detected.provider, id: p.id, allowsInsecureHttp: p.allowsInsecureHttp }
            : p;
        }),
      });
    } catch (error) {
      if (mounted.current) setMessage(commitAIError(error, t));
    } finally {
      if (mounted.current) setLoading(false);
    }
  };
  useEffect(() => {
    mounted.current = true;
    void reload();
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    let active = true;
    setKey("");
    setHasKey(false);
    setMessage("");
    if (provider?.source === "local")
      void commitKey(provider.id, "status")
        .then((value) => {
          if (active) setHasKey(value);
        })
        .catch((error) => {
          if (active) setMessage(commitAIError(error, t));
        });
    return () => {
      active = false;
    };
  }, [provider?.id, provider?.source]);

  const keyAction = async (action: "save" | "remove") => {
    if (!provider || managed) return;
    const id = provider.id;
    setBusy(true);
    setMessage("");
    try {
      const stored = await commitKey(id, action, key);
      if (mounted.current && profileId.current === id) {
        setHasKey(stored);
        setKey("");
        setMessage(t("aiCommit.saved"));
      }
    } catch (error) {
      if (mounted.current && profileId.current === id) setMessage(commitAIError(error, t));
    } finally {
      if (mounted.current) setBusy(false);
    }
  };
  const remove = async () => {
    if (!provider) return;
    const id = provider.id;
    setBusy(true);
    try {
      if (provider.source === "local") await commitKey(id, "remove");
      const current = useSettingsStore.getState().settings.aiCommit;
      const providers = current.providers.filter((p) => p.id !== id);
      update({
        providers,
        activeProviderId:
          current.activeProviderId === id ? (providers[0]?.id ?? null) : current.activeProviderId,
      });
    } catch (error) {
      if (mounted.current) setMessage(commitAIError(error, t));
    } finally {
      if (mounted.current) setBusy(false);
    }
  };

  return (
    <div className="flex flex-col gap-5 ui-text-sm">
      {message && (
        <p role="status" className="rounded border border-border p-2">
          {message}
        </p>
      )}
      <Section title={t("aiCommit.profiles")}>
        <Field label={t("aiCommit.profile")}>
          <SettingsSelect
            className="w-full"
            disabled={busy}
            value={settings.activeProviderId ?? ""}
            onChange={(selectedValue) => update({ activeProviderId: selectedValue })}
            options={[
              ...(!settings.providers.length ? [{ value: "", label: "—" }] : []),
              ...settings.providers.map((p) => ({
                value: p.id,
                label: p.name || p.model || t("aiCommit.name"),
              })),
            ]}
          />
        </Field>
        <div className="flex gap-2">
          <Button
            disabled={busy || settings.providers.length >= 30}
            onClick={() => {
              const added = newCommitProvider(crypto.randomUUID());
              update({ providers: [...settings.providers, added], activeProviderId: added.id });
            }}
          >
            {t("aiCommit.add")}
          </Button>
          <Button disabled={!provider || busy} onClick={() => void remove()}>
            {t("aiCommit.remove")}
          </Button>
        </div>
        {provider && (
          <>
            <Field label={t("aiCommit.name")}>
              <Input
                className="min-w-0 w-full"
                disabled={managed}
                value={provider.name}
                onChange={(e) => edit({ name: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.protocol")}>
              <SettingsSelect
                className="w-full"
                disabled={managed}
                value={provider.apiProtocol}
                onChange={(selectedValue) =>
                  edit({
                    apiProtocol: selectedValue as CommitProvider["apiProtocol"],
                    authentication: selectedValue === "anthropicMessages" ? "apiKey" : "bearer",
                  })
                }
                options={COMMIT_PROTOCOLS.map((p) => ({
                  value: p,
                  label:
                    p === "responses"
                      ? "Responses API"
                      : p === "chatCompletions"
                        ? "Chat Completions"
                        : "Anthropic Messages",
                }))}
              />
            </Field>
            {provider.apiProtocol === "chatCompletions" && (
              <Field label={t("aiCommit.tokenLimitField")}>
                <SettingsSelect
                  className="w-full"
                  disabled={managed}
                  value={provider.chatTokenLimitField}
                  onChange={(selectedValue) =>
                    edit({
                      chatTokenLimitField: selectedValue as CommitProvider["chatTokenLimitField"],
                    })
                  }
                  options={[
                    { value: "max_completion_tokens", label: "max_completion_tokens" },
                    {
                      value: "max_tokens",
                      label: `max_tokens (${t("aiCommit.legacyGateway")})`,
                    },
                  ]}
                />
              </Field>
            )}
            <Field label={t("aiCommit.endpoint")}>
              <Input
                type="url"
                className="min-w-0 w-full"
                disabled={managed}
                value={provider.endpoint}
                placeholder="https://api.example.com/v1"
                onChange={(e) => edit({ endpoint: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.model")}>
              <Input
                className="min-w-0 w-full"
                disabled={managed}
                value={provider.model}
                onChange={(e) => edit({ model: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.authentication")}>
              <SettingsSelect
                className="w-full"
                disabled={managed}
                value={provider.authentication}
                onChange={(selectedValue) =>
                  edit({ authentication: selectedValue as CommitProvider["authentication"] })
                }
                options={[
                  { value: "bearer", label: "Bearer" },
                  { value: "apiKey", label: "x-api-key" },
                ]}
              />
            </Field>
            {managed ? (
              <p className="text-subtle-foreground">
                {t("aiCommit.managed", {
                  source: provider.source === "codex" ? "Codex" : "Claude",
                })}
              </p>
            ) : (
              <>
                <Field label={t("aiCommit.key")}>
                  <Input
                    type="password"
                    autoComplete="off"
                    className="min-w-0 w-full"
                    value={key}
                    disabled={busy}
                    onChange={(e) => setKey(e.target.value)}
                    placeholder={hasKey ? t("aiCommit.keyStored") : ""}
                  />
                </Field>
                <div className="flex gap-2">
                  <Button disabled={busy || !key.trim()} onClick={() => void keyAction("save")}>
                    {t("aiCommit.saveKey")}
                  </Button>
                  <Button disabled={busy || !hasKey} onClick={() => void keyAction("remove")}>
                    {t("aiCommit.clearKey")}
                  </Button>
                </div>
              </>
            )}
            <label className="flex items-center gap-2">
              <Checkbox
                disabled={managed}
                checked={provider.requiresApiKey}
                onCheckedChange={(checked) => edit({ requiresApiKey: checked })}
              />
              {t("aiCommit.requiresKey")}
            </label>
            {provider.endpoint.trim().startsWith("http:") && (
              <label className="flex items-center gap-2">
                <Checkbox
                  checked={provider.allowsInsecureHttp}
                  onCheckedChange={(checked) => edit({ allowsInsecureHttp: checked })}
                />
                {t("aiCommit.allowHttp")}
              </label>
            )}
          </>
        )}
        {detection?.configurations.map((c) => (
          <div
            key={c.provider.source}
            className="flex flex-col gap-2 rounded-md border border-border bg-surface p-3"
          >
            <strong>
              {t("aiCommit.detected", {
                source: c.provider.source === "codex" ? "Codex" : "Claude",
              })}
            </strong>
            <span className="break-all font-mono text-subtle-foreground">
              {c.provider.model} · {c.provider.endpoint}
            </span>
            <span>{t(c.hasCredential ? "aiCommit.keyStored" : "aiCommit.noKey")}</span>
            <Button
              disabled={busy}
              onClick={() => {
                const existing = settings.providers.find((p) => p.source === c.provider.source);
                const imported = {
                  ...c.provider,
                  id: existing?.id ?? c.provider.id,
                  allowsInsecureHttp: existing?.allowsInsecureHttp ?? false,
                };
                update({
                  providers: [
                    ...settings.providers.filter((p) => p.source !== imported.source),
                    imported,
                  ],
                  activeProviderId: imported.id,
                });
              }}
            >
              {t("aiCommit.import", { source: c.provider.source === "codex" ? "Codex" : "Claude" })}
            </Button>
          </div>
        ))}
        {detection && !detection.configurations.length && <p>{t("aiCommit.notDetected")}</p>}
        {detection?.warnings.map((w) => (
          <p key={w.source} role="alert">
            {w.source}: {commitAIError(w.code, t)}
          </p>
        ))}
        <Button disabled={loading} onClick={() => void reload()}>
          {t("aiCommit.detect")}
        </Button>
      </Section>
      <Section title={t("aiCommit.rules")}>
        <label className="flex items-center gap-2">
          <Checkbox
            checked={settings.enabled}
            onCheckedChange={(checked) => update({ enabled: checked })}
          />
          {t("aiCommit.enabled")}
        </label>
        <Field label={t("aiCommit.effort")}>
          <SettingsSelect
            className="w-full"
            value={settings.reasoningEffort}
            disabled={provider?.apiProtocol === "anthropicMessages"}
            onChange={(selectedValue) =>
              update({ reasoningEffort: selectedValue as CommitAISettings["reasoningEffort"] })
            }
            options={COMMIT_EFFORTS.map((e) => ({
              value: e,
              label: e === "default" ? t("aiCommit.defaultEffort") : e,
            }))}
          />
        </Field>
        <Field label={t("aiCommit.language")}>
          <SettingsSelect
            className="w-full"
            value={settings.language}
            onChange={(selectedValue) =>
              update({ language: selectedValue as CommitAISettings["language"] })
            }
            options={[
              { value: "english", label: "English" },
              { value: "simplifiedChinese", label: "简体中文" },
            ]}
          />
        </Field>
        <Field label={t("aiCommit.format")}>
          <SettingsSelect
            className="w-full"
            value={settings.format}
            onChange={(selectedValue) =>
              update({ format: selectedValue as CommitAISettings["format"] })
            }
            options={COMMIT_FORMATS.map((f) => ({
              value: f,
              label: t(`aiCommit.${f === "custom" ? "customFormat" : f}`),
            }))}
          />
        </Field>
        {settings.format === "custom" ? (
          <div className="flex flex-col gap-2">
            <label htmlFor={customInstructionsId}>{t("aiCommit.custom")}</label>
            <Textarea
              id={customInstructionsId}
              rows={4}
              maxLength={4000}
              className="font-mono"
              value={settings.customInstructions}
              onChange={(e) => update({ customInstructions: e.target.value })}
            />
          </div>
        ) : (
          <p className="rounded bg-surface p-2 font-mono">
            {t("aiCommit.example")}: {settings.format === "conventional" ? "feat(editor): " : ""}
            {settings.language === "simplifiedChinese"
              ? "添加编辑器内存占用指示器"
              : "Add an editor memory indicator"}
          </p>
        )}
        <label className="flex items-center gap-2">
          <Checkbox
            checked={settings.includeBody}
            onCheckedChange={(checked) => update({ includeBody: checked })}
          />
          {t("aiCommit.body")}
        </label>
        <NumberField
          label={t("aiCommit.subject")}
          min={20}
          max={200}
          value={settings.subjectMaximumLength}
          onCommit={(value) => update({ subjectMaximumLength: value })}
        />
        <NumberField
          label={t("aiCommit.diff")}
          min={8000}
          max={120000}
          step={4000}
          value={settings.maximumDiffCharacters}
          onCommit={(value) => update({ maximumDiffCharacters: value })}
        />
        <p className="text-subtle-foreground">{t("aiCommit.disclosure")}</p>
      </Section>
    </div>
  );
}
