import { cloneElement, useEffect, useId, useRef, useState, type ReactElement } from "react";
import { useSettingsStore } from "../stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
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

const control =
  "min-w-0 w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-foreground outline-none focus:border-primary disabled:opacity-60";
function Field({ label, children }: { label: string; children: ReactElement<{ id?: string }> }) {
  const id = useId();
  return (
    <div className="grid grid-cols-[minmax(110px,1fr)_minmax(0,1.6fr)] items-center gap-3">
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
      <input
        type="number"
        min={min}
        max={max}
        step={step}
        className={control}
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
      <section className="flex flex-col gap-3">
        <h3 className="font-semibold">{t("aiCommit.profiles")}</h3>
        <Field label={t("aiCommit.profile")}>
          <select
            className={control}
            disabled={busy}
            value={settings.activeProviderId ?? ""}
            onChange={(e) => update({ activeProviderId: e.target.value })}
          >
            {!settings.providers.length && <option value="">—</option>}
            {settings.providers.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name || p.model || t("aiCommit.name")}
              </option>
            ))}
          </select>
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
              <input
                className={control}
                disabled={managed}
                value={provider.name}
                onChange={(e) => edit({ name: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.protocol")}>
              <select
                className={control}
                disabled={managed}
                value={provider.apiProtocol}
                onChange={(e) =>
                  edit({
                    apiProtocol: e.target.value as CommitProvider["apiProtocol"],
                    authentication: e.target.value === "anthropicMessages" ? "apiKey" : "bearer",
                  })
                }
              >
                {COMMIT_PROTOCOLS.map((p) => (
                  <option key={p} value={p}>
                    {p === "responses"
                      ? "Responses API"
                      : p === "chatCompletions"
                        ? "Chat Completions"
                        : "Anthropic Messages"}
                  </option>
                ))}
              </select>
            </Field>
            {provider.apiProtocol === "chatCompletions" && (
              <Field label={t("aiCommit.tokenLimitField")}>
                <select
                  className={control}
                  disabled={managed}
                  value={provider.chatTokenLimitField}
                  onChange={(e) =>
                    edit({
                      chatTokenLimitField: e.target.value as CommitProvider["chatTokenLimitField"],
                    })
                  }
                >
                  <option value="max_completion_tokens">max_completion_tokens</option>
                  <option value="max_tokens">max_tokens ({t("aiCommit.legacyGateway")})</option>
                </select>
              </Field>
            )}
            <Field label={t("aiCommit.endpoint")}>
              <input
                type="url"
                className={control}
                disabled={managed}
                value={provider.endpoint}
                placeholder="https://api.example.com/v1"
                onChange={(e) => edit({ endpoint: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.model")}>
              <input
                className={control}
                disabled={managed}
                value={provider.model}
                onChange={(e) => edit({ model: e.target.value })}
              />
            </Field>
            <Field label={t("aiCommit.authentication")}>
              <select
                className={control}
                disabled={managed}
                value={provider.authentication}
                onChange={(e) =>
                  edit({ authentication: e.target.value as CommitProvider["authentication"] })
                }
              >
                <option value="bearer">Bearer</option>
                <option value="apiKey">x-api-key</option>
              </select>
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
                  <input
                    type="password"
                    autoComplete="off"
                    className={control}
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
              <input
                type="checkbox"
                disabled={managed}
                checked={provider.requiresApiKey}
                onChange={(e) => edit({ requiresApiKey: e.target.checked })}
              />
              {t("aiCommit.requiresKey")}
            </label>
            {provider.endpoint.trim().startsWith("http:") && (
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={provider.allowsInsecureHttp}
                  onChange={(e) => edit({ allowsInsecureHttp: e.target.checked })}
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
      </section>
      <section className="flex flex-col gap-3 border-t border-border pt-4">
        <h3 className="font-semibold">{t("aiCommit.rules")}</h3>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={settings.enabled}
            onChange={(e) => update({ enabled: e.target.checked })}
          />
          {t("aiCommit.enabled")}
        </label>
        <Field label={t("aiCommit.effort")}>
          <select
            className={control}
            value={settings.reasoningEffort}
            disabled={provider?.apiProtocol === "anthropicMessages"}
            onChange={(e) =>
              update({ reasoningEffort: e.target.value as CommitAISettings["reasoningEffort"] })
            }
          >
            {COMMIT_EFFORTS.map((e) => (
              <option key={e} value={e}>
                {e === "default" ? t("aiCommit.defaultEffort") : e}
              </option>
            ))}
          </select>
        </Field>
        <Field label={t("aiCommit.language")}>
          <select
            className={control}
            value={settings.language}
            onChange={(e) => update({ language: e.target.value as CommitAISettings["language"] })}
          >
            <option value="english">English</option>
            <option value="simplifiedChinese">简体中文</option>
          </select>
        </Field>
        <Field label={t("aiCommit.format")}>
          <select
            className={control}
            value={settings.format}
            onChange={(e) => update({ format: e.target.value as CommitAISettings["format"] })}
          >
            {COMMIT_FORMATS.map((f) => (
              <option key={f} value={f}>
                {t(`aiCommit.${f === "custom" ? "customFormat" : f}`)}
              </option>
            ))}
          </select>
        </Field>
        {settings.format === "custom" ? (
          <div className="flex flex-col gap-2">
            <label htmlFor={customInstructionsId}>{t("aiCommit.custom")}</label>
            <textarea
              id={customInstructionsId}
              rows={4}
              maxLength={4000}
              className={`${control} resize-y font-mono`}
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
          <input
            type="checkbox"
            checked={settings.includeBody}
            onChange={(e) => update({ includeBody: e.target.checked })}
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
      </section>
    </div>
  );
}
