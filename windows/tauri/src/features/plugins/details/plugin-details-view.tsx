import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { DeclarativePluginSettingsEditor } from "../declarative-plugin-settings-editor";
import {
  invokePluginDetailsService,
  PluginDetailsSession,
  type PluginDetailsService,
} from "./plugin-details.service";
import type {
  PluginDetailFeature,
  PluginDetailsModel,
  PluginDetailsOperation,
  PluginDetailsSelection,
  PluginDetailsState,
  PluginVersionProvenance,
} from "./plugin-details.types";

export type PluginDetailTab = "overview" | "features" | "settings" | "permissions" | "versions";

const TABS: PluginDetailTab[] = ["overview", "features", "settings", "permissions", "versions"];

export interface PluginDetailsPanelProps {
  selection: PluginDetailsSelection | null;
  workspacePath: string | null;
  service?: PluginDetailsService;
  onChanged?: (selection: PluginDetailsSelection, workspacePath: string | null) => void;
}

/** Load-owning wrapper. The management page supplies the selected catalog identity. */
export function PluginDetailsPanel({
  selection,
  workspacePath,
  service = invokePluginDetailsService,
  onChanged,
}: PluginDetailsPanelProps) {
  const { t } = useTranslation();
  const [state, setState] = useState<PluginDetailsState>({
    phase: "idle",
    selection: null,
    workspacePath,
  });
  const session = useRef<PluginDetailsSession | null>(null);
  const selectedPluginId = selection?.pluginId;
  const selectedSource = selection?.source;

  useEffect(() => {
    const current = new PluginDetailsSession(service, setState, onChanged);
    session.current = current;
    current.select(
      selectedPluginId && selectedSource
        ? { pluginId: selectedPluginId, source: selectedSource }
        : null,
      workspacePath,
    );
    return () => {
      current.dispose();
      if (session.current === current) session.current = null;
    };
  }, [service, onChanged, selectedPluginId, selectedSource, workspacePath]);

  if (state.phase === "idle") {
    return <PluginDetailEmpty message={t("settings.declarativePluginDetails.noSelection")} />;
  }
  if (state.phase === "loading") {
    return (
      <div role="status" className="p-6 text-subtle-foreground ui-text-sm">
        {t("settings.declarativePluginDetails.loading")}
      </div>
    );
  }
  if (state.phase === "failed") {
    return (
      <div role="alert" className="m-4 rounded-md border border-destructive/40 bg-destructive/8 p-3 ui-text-sm">
        <p className="text-destructive">{state.error}</p>
        <button
          type="button"
          className="mt-2 h-7 rounded-[4px] border border-primary/30 px-2.5 text-primary"
          onClick={() => session.current?.select(state.selection, state.workspacePath)}
        >
          {t("settings.declarativePluginDetails.retry")}
        </button>
      </div>
    );
  }
  return (
    <PluginDetailsView
      key={`${state.details.identity.source}:${state.details.identity.pluginId}:${state.details.identity.version}`}
      details={state.details}
      workspacePath={state.workspacePath}
      operation={state.operation}
      operationError={state.error}
      onOperation={(operation) => void session.current?.perform(operation, state.details)}
    />
  );
}

export function PluginDetailsView({
  details,
  workspacePath,
  operation,
  operationError,
  onOperation,
}: {
  details: PluginDetailsModel;
  workspacePath: string | null;
  operation: PluginDetailsOperation | null;
  operationError: string | null;
  onOperation: (operation: PluginDetailsOperation) => void;
}) {
  const { language, t } = useTranslation();
  const [tab, setTab] = useState<PluginDetailTab>("overview");
  const description = details.localizedDescriptions[language] ?? details.description;

  return (
    <section className="flex min-w-0 flex-1 flex-col overflow-hidden" aria-label={details.displayName}>
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="truncate ui-text-lg font-semibold">{details.displayName}</h2>
            <StatusBadge details={details} />
          </div>
          <p className="truncate text-subtle-foreground ui-text-sm">
            {[details.vendorName, details.identity.version].filter(Boolean).join(" · ")}
          </p>
        </div>
        <PluginDetailActions
          details={details}
          operation={operation}
          onOperation={onOperation}
        />
        {details.rejection && (
          <p role="alert" className="w-full rounded-md bg-destructive/8 p-2 text-destructive ui-text-sm">
            {details.rejection.code}: {details.rejection.message}
          </p>
        )}
        {details.versions.current.origin === "community" && details.status !== "rejected" && (
          <p className="w-full rounded-md bg-warning/8 p-2 text-warning ui-text-sm">
            {details.versions.current.channel === "disk"
              ? t("settings.declarativePluginDetails.notice.diskCommunity")
              : t("settings.declarativePluginDetails.notice.community")}
          </p>
        )}
        {operationError && (
          <p role="alert" className="w-full text-destructive ui-text-sm">{operationError}</p>
        )}
      </header>
      <PluginDetailTabBar value={tab} details={details} onChange={setTab} />
      <div
        id={panelId(details)}
        role="tabpanel"
        aria-labelledby={tabId(details, tab)}
        className="min-h-0 min-w-0 flex-1 overflow-auto p-4"
      >
        {tab === "overview" && <OverviewTab details={details} description={description} />}
        {tab === "features" && <FeaturesTab features={details.features} />}
        {tab === "settings" && (
          <SettingsTab details={details} workspacePath={workspacePath} />
        )}
        {tab === "permissions" && (
          <PermissionsAndProgramsTab permissions={details.permissions} programs={details.programs} />
        )}
        {tab === "versions" && <VersionsAndSourceTab details={details} />}
      </div>
    </section>
  );
}

function PluginDetailActions({
  details,
  operation,
  onOperation,
}: {
  details: PluginDetailsModel;
  operation: PluginDetailsOperation | null;
  onOperation: (operation: PluginDetailsOperation) => void;
}) {
  const { t } = useTranslation();
  const disabled = operation !== null;
  return (
    <div className="flex flex-wrap items-center justify-end gap-2">
      {details.operations.canSetEnabled && details.status === "accepted" && (
        <button
          type="button"
          disabled={disabled}
          className="h-7 rounded-[4px] border border-primary/30 bg-primary/12 px-2.5 text-primary ui-text-sm disabled:opacity-50"
          onClick={() => onOperation(details.enabled ? "disable" : "enable")}
        >
          {details.enabled
            ? t("settings.declarativePluginDetails.action.disable")
            : t("settings.declarativePluginDetails.action.enable")}
        </button>
      )}
      {details.operations.canRollback && (
        <button
          type="button"
          disabled={disabled}
          className="h-7 rounded-[4px] border border-border px-2.5 ui-text-sm disabled:opacity-50"
          onClick={() => onOperation("rollback")}
        >
          {t("settings.declarativePluginDetails.action.rollback")}
        </button>
      )}
      {details.operations.canUninstall && (
        <button
          type="button"
          disabled={disabled}
          className="h-7 rounded-[4px] px-2.5 text-destructive ui-text-sm disabled:opacity-50"
          onClick={() => onOperation("uninstall")}
        >
          {t("settings.declarativePluginDetails.action.uninstall")}
        </button>
      )}
    </div>
  );
}

function PluginDetailTabBar({
  value,
  details,
  onChange,
}: {
  value: PluginDetailTab;
  details: PluginDetailsModel;
  onChange: (tab: PluginDetailTab) => void;
}) {
  const { t } = useTranslation();
  const counts: Partial<Record<PluginDetailTab, number>> = {
    features: details.features.length,
    settings: details.settings.length,
    permissions: details.permissions.length + details.programs.length,
  };
  const selectRelative = (event: KeyboardEvent<HTMLButtonElement>, current: PluginDetailTab) => {
    let index = TABS.indexOf(current);
    if (event.key === "ArrowRight") index = (index + 1) % TABS.length;
    else if (event.key === "ArrowLeft") index = (index - 1 + TABS.length) % TABS.length;
    else if (event.key === "Home") index = 0;
    else if (event.key === "End") index = TABS.length - 1;
    else return;
    event.preventDefault();
    onChange(TABS[index]!);
    document.getElementById(tabId(details, TABS[index]!))?.focus();
  };
  return (
    <div
      role="tablist"
      aria-label={t("settings.declarativePluginDetails.tabs")}
      className="flex min-w-0 overflow-x-auto border-b border-border px-3"
    >
      {TABS.map((tab) => (
        <button
          key={tab}
          id={tabId(details, tab)}
          type="button"
          role="tab"
          aria-selected={value === tab}
          aria-controls={panelId(details)}
          tabIndex={value === tab ? 0 : -1}
          className="shrink-0 border-b-2 border-transparent px-3 py-2 text-subtle-foreground ui-text-sm aria-selected:border-primary aria-selected:text-foreground"
          onClick={() => onChange(tab)}
          onKeyDown={(event) => selectRelative(event, tab)}
        >
          {t(`settings.declarativePluginDetails.tab.${tab}`)}
          {counts[tab] ? <span className="ml-1 text-xs">{counts[tab]}</span> : null}
        </button>
      ))}
    </div>
  );
}

export function OverviewTab({ details, description }: { details: PluginDetailsModel; description: string | null }) {
  const { t } = useTranslation();
  return (
    <div className="flex flex-col gap-4 ui-text-sm">
      {description && <p className="max-w-3xl whitespace-pre-wrap">{description}</p>}
      <DefinitionList rows={[
        [t("settings.declarativePluginDetails.field.status"), statusText(details, t)],
        [t("settings.declarativePluginDetails.field.provides"), details.features.map((feature) => feature.title).join(", ") || "—"],
        [t("settings.declarativePluginDetails.field.source"), sourceText(details.versions.current, t)],
        [t("settings.declarativePluginDetails.field.settings"), String(details.settings.length)],
      ]} />
    </div>
  );
}

export function FeaturesTab({ features }: { features: PluginDetailFeature[] }) {
  const { t } = useTranslation();
  if (!features.length) return <PluginDetailEmpty message={t("settings.declarativePluginDetails.empty.features")} />;
  return (
    <ul className="grid min-w-0 grid-cols-[repeat(auto-fit,minmax(min(100%,14rem),1fr))] gap-2">
      {features.map((feature) => (
        <li key={`${feature.kind}:${feature.subject}`} className="min-w-0 rounded-md border border-border p-3">
          <p className="truncate ui-text-sm font-medium">{feature.title}</p>
          <p className="text-subtle-foreground ui-text-sm">
            <code>{feature.kind}</code> · {t(`settings.declarativePluginDetails.availability.${feature.availability}`)}
          </p>
          {feature.detail !== null && (
            <pre className="mt-2 overflow-auto whitespace-pre-wrap break-all rounded bg-muted p-2 text-xs">
              {JSON.stringify(feature.detail, null, 2)}
            </pre>
          )}
        </li>
      ))}
    </ul>
  );
}

export function SettingsTab({
  details,
  workspacePath,
}: {
  details: PluginDetailsModel;
  workspacePath: string | null;
}) {
  const { t } = useTranslation();
  if (!details.settings.length) {
    return <PluginDetailEmpty message={t("settings.declarativePluginDetails.empty.settings")} />;
  }
  if (!details.enabled || details.status !== "accepted") {
    return <PluginDetailEmpty message={t("settings.declarativePluginDetails.settingsDisabled")} />;
  }
  return (
    <div className="min-w-[30rem]" data-testid="plugin-details-settings-editor">
      <DeclarativePluginSettingsEditor
        pluginId={details.identity.pluginId}
        settings={details.settings}
        workspacePath={workspacePath}
        languageId={details.primaryLanguageId}
      />
    </div>
  );
}

export function PermissionsAndProgramsTab({
  permissions,
  programs,
}: {
  permissions: string[];
  programs: unknown[];
}) {
  const { t } = useTranslation();
  return (
    <div className="flex min-w-0 flex-col gap-5">
      <section>
        <h3 className="mb-2 ui-text-sm font-semibold">{t("settings.declarativePluginDetails.permissions")}</h3>
        {permissions.length ? (
          <ul className="list-disc space-y-1 pl-5 ui-text-sm">
            {permissions.map((permission) => (
              <li key={permission}>
                {t(`settings.declarativePluginDetails.permission.${permission}`)}
                <code className="ml-2 text-subtle-foreground">{permission}</code>
              </li>
            ))}
          </ul>
        ) : <PluginDetailEmpty message={t("settings.declarativePluginDetails.empty.permissions")} />}
      </section>
      <section>
        <h3 className="mb-2 ui-text-sm font-semibold">{t("settings.declarativePluginDetails.programs")}</h3>
        {programs.length ? (
          <div className="flex flex-col gap-2">
            {programs.map((program, index) => (
              <details key={index} className="rounded-md border border-border p-2" open={index === 0}>
                <summary className="cursor-default ui-text-sm">
                  {t("settings.declarativePluginDetails.program", { index: index + 1 })}
                </summary>
                <pre className="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-all rounded bg-muted p-2 text-xs">
                  {JSON.stringify(program, null, 2)}
                </pre>
              </details>
            ))}
          </div>
        ) : <PluginDetailEmpty message={t("settings.declarativePluginDetails.empty.programs")} />}
      </section>
    </div>
  );
}

export function VersionsAndSourceTab({ details }: { details: PluginDetailsModel }) {
  const { t } = useTranslation();
  return (
    <div className="flex min-w-0 flex-col gap-4 ui-text-sm">
      <VersionCard
        title={t("settings.declarativePluginDetails.currentVersion")}
        provenance={details.versions.current}
      />
      {details.versions.previous && (
        <VersionCard
          title={t("settings.declarativePluginDetails.previousVersion")}
          provenance={details.versions.previous}
        />
      )}
      <DefinitionList rows={[
        [t("settings.declarativePluginDetails.field.update"), t("settings.declarativePluginDetails.update.unknown")],
        [t("settings.declarativePluginDetails.field.pluginId"), details.identity.pluginId],
      ]} />
    </div>
  );
}

function VersionCard({ title, provenance }: { title: string; provenance: PluginVersionProvenance }) {
  const { t } = useTranslation();
  return (
    <section className="min-w-0 rounded-md border border-border p-3">
      <h3 className="mb-2 ui-text-sm font-semibold">{title}</h3>
      <DefinitionList rows={[
        [t("settings.declarativePluginDetails.field.version"), provenance.version],
        [t("settings.declarativePluginDetails.field.source"), sourceText(provenance, t)],
        [t("settings.declarativePluginDetails.field.verification"), verificationText(provenance, t)],
        [t("settings.declarativePluginDetails.field.repository"), provenance.repository ?? "—"],
        [t("settings.declarativePluginDetails.field.archiveDigest"), provenance.archiveSha256 ?? "—"],
        [t("settings.declarativePluginDetails.field.contentDigest"), provenance.contentDigest ?? "—"],
      ]} />
    </section>
  );
}

function DefinitionList({ rows }: { rows: Array<[string, string]> }) {
  return (
    <dl className="grid min-w-0 grid-cols-[minmax(7rem,auto)_minmax(0,1fr)] gap-x-4 gap-y-2">
      {rows.map(([term, value]) => (
        <div key={term} className="contents">
          <dt className="text-subtle-foreground">{term}</dt>
          <dd className="min-w-0 break-all">{value}</dd>
        </div>
      ))}
    </dl>
  );
}

function StatusBadge({ details }: { details: PluginDetailsModel }) {
  const { t } = useTranslation();
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs ${details.status === "rejected" ? "bg-destructive/10 text-destructive" : "bg-success/10 text-success"}`}>
      {statusText(details, t)}
    </span>
  );
}

function PluginDetailEmpty({ message }: { message: string }) {
  return <p className="p-6 text-center text-subtle-foreground ui-text-sm">{message}</p>;
}

function statusText(details: PluginDetailsModel, t: (key: string) => string): string {
  if (details.status === "rejected") return t("settings.declarativePluginDetails.status.quarantined");
  return details.enabled
    ? t("settings.declarativePluginDetails.status.enabled")
    : t("settings.declarativePluginDetails.status.disabled");
}

function sourceText(
  provenance: PluginVersionProvenance,
  t: (key: string) => string,
): string {
  const channel = t(`settings.declarativePluginDetails.source.${provenance.channel}`);
  return provenance.sourceName
    ? `${channel} · ${provenance.sourceName}`
    : provenance.fileName
      ? `${channel} · ${provenance.fileName}`
      : channel;
}

function verificationText(
  provenance: PluginVersionProvenance,
  t: (key: string) => string,
): string {
  const text = t(`settings.declarativePluginDetails.verification.${provenance.verification.status}`);
  return provenance.verification.keyId ? `${text} · ${provenance.verification.keyId}` : text;
}

function tabId(details: PluginDetailsModel, tab: PluginDetailTab): string {
  return `plugin-details-${safeId(details.identity.pluginId)}-${tab}`;
}

function panelId(details: PluginDetailsModel): string {
  return `plugin-details-${safeId(details.identity.pluginId)}-panel`;
}

function safeId(value: string): string {
  return value.replace(/[^a-zA-Z0-9_-]/g, "-");
}
