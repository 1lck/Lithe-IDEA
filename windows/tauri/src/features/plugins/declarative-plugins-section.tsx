import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Switch from "@/ui/switch";
import {
  closeDeclarativeWebWindow,
  cancelDeclarativeDiskInstall,
  confirmDeclarativeDiskInstall,
  listDeclarativePlugins,
  listDeclarativeWebWindows,
  openDeclarativeWebWindow,
  prepareDeclarativeDiskInstall,
  type DeclarativeWebToolWindow,
  rescanDeclarativePlugins,
  rollbackDeclarativePlugin,
  setDeclarativePluginEnabled,
  uninstallDeclarativePlugin,
  type DeclarativePluginSummary,
  type PreparedDeclarativeInstall,
} from "./declarative-plugin-launch";
import { DeclarativePluginSettingsEditor } from "./declarative-plugin-settings-editor";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";

/**
 * Management surface for contract v1 declarative plugins. This block is
 * intentionally separate from the Worker extension browser: the two models
 * have different trust properties (contract packages run only host-launched
 * processes reviewed through Core's install review), so mixing them in one
 * list would hide that difference from the user.
 */
export function DeclarativePluginsSection() {
  const { t } = useTranslation();
  const [plugins, setPlugins] = useState<DeclarativePluginSummary[]>([]);
  const [webWindows, setWebWindows] = useState<DeclarativeWebToolWindow[]>([]);
  const [pending, setPending] = useState<PreparedDeclarativeInstall | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const workspacePath = useWorkspaceTabsStore((state) =>
    state.projectTabs.find((tab) => tab.isActive)?.path ?? null,
  );

  const refresh = useCallback(async () => {
    await rescanDeclarativePlugins();
    setPlugins(await listDeclarativePlugins());
    setWebWindows(await listDeclarativeWebWindows());
  }, []);

  useEffect(() => {
    refresh().catch((reason: unknown) => setError(String(reason)));
  }, [refresh]);

  useEffect(() => {
    if (!pending) return;
    return () => {
      void cancelDeclarativeDiskInstall(pending.sessionId).catch((reason: unknown) =>
        console.warn("Could not discard plugin install review", reason),
      );
    };
  }, [pending]);

  const importPackage = async () => {
    const selection = await import("@tauri-apps/plugin-dialog").then(({ open }) =>
      open({
        multiple: false,
        filters: [
          { name: "Lithe plugin package", extensions: ["zip"] },
        ],
      }),
    );
    if (typeof selection !== "string") return;
    setBusy(true);
    setError(null);
    try {
      setPending(await prepareDeclarativeDiskInstall(selection));
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  const confirmInstall = async () => {
    if (!pending) return;
    setBusy(true);
    setError(null);
    try {
      await confirmDeclarativeDiskInstall(pending.sessionId, pending.manifestDigest);
      setPending(null);
      await refresh();
    } catch (reason) {
      setError(String(reason));
      setPending(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section aria-label={t("settings.declarativePlugins.title")} className="flex flex-col gap-2">
      <SettingsSectionGroup
        title={t("settings.declarativePlugins.title")}
        description={t("settings.declarativePlugins.description")}
        action={
          <Button variant="accent" size="sm" disabled={busy || Boolean(pending)} onClick={() => void importPackage()}>
            {t("settings.declarativePlugins.import")}
          </Button>
        }
      />
      {error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {error}
        </p>
      )}
      {pending && (
        <InstallReviewCard
          pending={pending}
          onConfirm={() => void confirmInstall()}
          onCancel={() => setPending(null)}
          busy={busy}
        />
      )}
      <ul className="flex flex-col gap-1" data-testid="declarative-plugin-list">
        {plugins.map((plugin) => (
          <DeclarativePluginRow
            key={`${plugin.source}-${plugin.pluginId}`}
            plugin={plugin}
            workspacePath={workspacePath}
            onChanged={() => void refresh()}
          />
        ))}
        {!plugins.length && (
          <li className="text-subtle-foreground ui-text-sm">
            {t("settings.declarativePlugins.empty")}
          </li>
        )}
      </ul>
      {webWindows.length > 0 && (
        <div className="flex flex-col gap-1">
          <h3 className="ui-text-sm font-semibold">
            {t("settings.declarativePlugins.webWindows")}
          </h3>
          <ul className="flex flex-col gap-1" data-testid="declarative-web-window-list">
            {webWindows.map((window) => (
            <WebWindowRow key={`${window.pluginId}:${window.windowId}`} window={window} />
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}

function WebWindowRow({ window }: { window: DeclarativeWebToolWindow }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  return (
    <li className="flex items-center gap-3 rounded-md border border-border px-3 py-2">
      <div className="min-w-0 flex-1">
        <p className="truncate ui-text-sm">
          {window.title}
          <span className="text-subtle-foreground">
            {" "}
            · {t(`settings.declarativePlugins.placement.${window.placement}`)}
          </span>
        </p>
      </div>
      <Button
        variant="accent"
        size="sm"
        onClick={() => {
          if (open) {
            void closeDeclarativeWebWindow(window.pluginId, window.windowId).then(() => setOpen(false));
          } else {
            void openDeclarativeWebWindow(window.pluginId, window.windowId).then(() => setOpen(true));
          }
        }}
      >
        {open
          ? t("settings.declarativePlugins.closeWindow")
          : t("settings.declarativePlugins.openWindow")}
      </Button>
    </li>
  );
}

function InstallReviewCard({
  pending,
  onConfirm,
  onCancel,
  busy,
}: {
  pending: PreparedDeclarativeInstall;
  onConfirm: () => void;
  onCancel: () => void;
  busy: boolean;
}) {
  const { t } = useTranslation();
  return (
    <div
      role="dialog"
      aria-label={t("settings.declarativePlugins.reviewTitle")}
      className="rounded-md border border-border p-3"
    >
      <p className="ui-text-sm font-medium">
        {t("settings.declarativePlugins.reviewTitle", {
          name: pending.displayName,
          version: pending.review.version,
        })}
      </p>
      <p className="text-subtle-foreground ui-text-sm">
        {t("settings.declarativePlugins.unverified")}
      </p>
      {pending.review.permissions.length > 0 && (
        <ul className="mt-1 list-disc pl-5 ui-text-sm">
          {pending.review.permissions.map((permission) => (
            <li key={permission}>{permission}</li>
          ))}
        </ul>
      )}
      {pending.review.programs.length > 0 && (
        <ProgramDeclarationList programs={pending.review.programs} />
      )}
      <div className="mt-2 flex gap-2">
        <Button size="sm" disabled={busy} onClick={onConfirm}>
          {t("settings.declarativePlugins.confirmInstall")}
        </Button>
        <Button size="sm" variant="accent" disabled={busy} onClick={onCancel}>
          {t("ui.cancel")}
        </Button>
      </div>
    </div>
  );
}

function ProgramDeclarationList({ programs }: { programs: unknown[] }) {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="mt-1 ui-text-sm">
      <button
        type="button"
        className="text-left underline"
        onClick={() => setExpanded((value) => !value)}
      >
        {t("settings.declarativePlugins.programDeclaration", { count: programs.length })}
      </button>
      {expanded && (
        <pre className="mt-1 max-h-40 overflow-auto rounded bg-muted p-2 text-xs">
          {JSON.stringify(programs, null, 2)}
        </pre>
      )}
    </div>
  );
}

function DeclarativePluginRow({
  plugin,
  workspacePath,
  onChanged,
}: {
  plugin: DeclarativePluginSummary;
  workspacePath: string | null;
  onChanged: () => void;
}) {
  const { t } = useTranslation();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const rejected = plugin.status === "rejected";
  const declaredSettings =
    !rejected && Array.isArray(plugin.declaredSettings) ? plugin.declaredSettings : [];
  const hasSettings = declaredSettings.length > 0;

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await action();
      onChanged();
    } catch (reason) {
      setError(String(reason));
    } finally {
      setBusy(false);
    }
  };

  return (
    <li className="rounded-md border border-border px-3 py-2">
      <div className="flex items-center gap-3">
        <div className="min-w-0 flex-1">
          <p className="truncate ui-text-sm font-medium">
            {plugin.displayName}{" "}
            <span className="text-subtle-foreground">
              {plugin.version} · {t(`settings.declarativePlugins.source.${plugin.source}`)}
            </span>
          </p>
          {rejected && plugin.rejection && (
            <p className="text-destructive ui-text-sm">
              {plugin.rejection.code}: {plugin.rejection.message}
            </p>
          )}
          {error && <p className="text-destructive ui-text-sm">{error}</p>}
        </div>
        {!rejected && hasSettings && (
          <Button
            variant="accent"
            size="sm"
            disabled={busy}
            onClick={() => setShowSettings((value) => !value)}
          >
            {showSettings ? t("settings.declarativePlugins.hideSettings") : t("settings.declarativePlugins.showSettings")}
          </Button>
        )}
        {!rejected && plugin.source === "installed" && (
          <>
            <Switch
              checked={plugin.enabled}
              disabled={busy}
              onChange={(checked) =>
                void run(() => setDeclarativePluginEnabled(plugin.pluginId, checked))
              }
              aria-label={t("settings.declarativePlugins.toggle", { name: plugin.displayName })}
            />
            <Button
              variant="accent"
              size="sm"
              disabled={busy}
              onClick={() => void run(() => rollbackDeclarativePlugin(plugin.pluginId))}
            >
              {t("settings.declarativePlugins.rollback")}
            </Button>
            <Button
              variant="danger"
              size="sm"
              disabled={busy}
              onClick={() => void run(() => uninstallDeclarativePlugin(plugin.pluginId))}
            >
              {t("settings.declarativePlugins.uninstall")}
            </Button>
          </>
        )}
      </div>
      {!rejected && showSettings && hasSettings && (
        <DeclarativePluginSettingsEditor
          pluginId={plugin.pluginId}
          settings={declaredSettings}
          workspacePath={workspacePath}
          languageId={plugin.primaryLanguageId}
        />
      )}
    </li>
  );
}

function SettingsSectionGroup({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div>
        <h3 className="ui-text-sm font-semibold">{title}</h3>
        <p className="text-subtle-foreground ui-text-sm">{description}</p>
      </div>
      {action}
    </div>
  );
}
