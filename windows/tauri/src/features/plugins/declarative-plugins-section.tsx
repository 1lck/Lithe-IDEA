import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
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
  type DeclarativePluginSummary,
  type PreparedDeclarativeInstall,
} from "./declarative-plugin-launch";
import { DeclarativePluginList } from "./declarative-plugin-list";
import { DeclarativeMarketplaceSources } from "./declarative-marketplace-sources-section";
import { DeclarativeMarketplaceSection } from "./marketplace/marketplace-section";
import { listMarketplaceInstalledPlugins, marketplaceHostService } from "./marketplace/marketplace-host-service";
import { PluginDetailsPanel, type PluginDetailsOperation, type PluginDetailsSelection } from "./details";
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
  const [selection, setSelection] = useState<PluginDetailsSelection | null>(null);
  const [refreshing, setRefreshing] = useState(true);
  const [marketplaceRevision, setMarketplaceRevision] = useState(0);
  const ownerRef = useRef<{ active: boolean; refresh: number; busy: boolean } | null>(null);
  const pendingRef = useRef<PreparedDeclarativeInstall | null>(null);
  const workspacePath = useWorkspaceTabsStore((state) =>
    state.projectTabs.find((tab) => tab.isActive)?.path ?? null,
  );
  const selectedSummary = plugins.find((plugin) =>
    selection !== null && plugin.pluginId === selection.pluginId && plugin.source === selection.source);
  // A stable scan keeps the active tab and pending operation mounted. An
  // externally changed package/state must instead reload its host details.
  const detailKey = selectedSummary
    ? `${selectedSummary.source}:${selectedSummary.pluginId}:${selectedSummary.version}:${selectedSummary.status}:${selectedSummary.enabled}`
    : selection ? `${selection.source}:${selection.pluginId}` : "none";

  const refresh = useCallback(async () => {
    const owner = ownerRef.current;
    if (!owner?.active) return;
    const generation = ++owner.refresh;
    const current = () => owner.active && owner.refresh === generation;
    setRefreshing(true);
    setError(null);
    try {
      await rescanDeclarativePlugins();
      if (!current()) return;
      const [next, windows] = await Promise.all([listDeclarativePlugins(), listDeclarativeWebWindows()]);
      if (!current()) return;
      setPlugins(next);
      setWebWindows(windows);
    } catch (reason) {
      if (current()) setError(String(reason));
    } finally {
      if (current()) setRefreshing(false);
    }
  }, []);

  const handleChanged = useCallback((changed: PluginDetailsSelection, _workspacePath: string | null, operation: PluginDetailsOperation) => {
    if (!ownerRef.current?.active) return;
    if (operation === "uninstall") {
      setSelection((current) => current?.pluginId === changed.pluginId && current.source === changed.source ? null : current);
    }
    setMarketplaceRevision((revision) => revision + 1);
    void refresh();
  }, [refresh]);
  const marketplaceService = useMemo(() => marketplaceHostService(() => void refresh()), [refresh]);

  useEffect(() => {
    const owner = { active: true, refresh: 0, busy: false };
    ownerRef.current = owner;
    void refresh();
    return () => {
      owner.active = false;
      owner.refresh += 1;
      const review = pendingRef.current;
      pendingRef.current = null;
      if (review) void discardReview(review);
    };
  }, [refresh]);

  const importPackage = async () => {
    const owner = ownerRef.current;
    if (!owner?.active || owner.busy || pendingRef.current) return;
    owner.busy = true;
    setBusy(true);
    setError(null);
    try {
      const path = await import("@tauri-apps/plugin-dialog").then(({ open }) =>
        open({ multiple: false, filters: [{ name: "Lithe plugin package", extensions: ["zip"] }] }),
      );
      if (typeof path !== "string" || !owner.active) return;
      const review = await prepareDeclarativeDiskInstall(path);
      if (!owner.active) {
        // Preparation can finish after the page closes, before a review was
        // ever rendered. The initiating owner must still release its snapshot.
        await discardReview(review);
        return;
      }
      pendingRef.current = review;
      setPending(review);
    } catch (reason) {
      if (owner.active) setError(String(reason));
    } finally {
      owner.busy = false;
      if (owner.active) setBusy(false);
    }
  };

  const confirmInstall = async () => {
    const owner = ownerRef.current;
    const review = pendingRef.current;
    if (!owner?.active || owner.busy || !review) return;
    owner.busy = true;
    setBusy(true);
    setError(null);
    try {
      await confirmDeclarativeDiskInstall(review.sessionId, review.manifestDigest);
      if (!owner.active) return;
      pendingRef.current = null;
      setPending(null);
      setMarketplaceRevision((revision) => revision + 1);
      await refresh();
    } catch (reason) {
      if (owner.active) {
        setError(String(reason));
        pendingRef.current = null;
        setPending(null);
        // An IPC failure may precede the host's confirmation cleanup.
        await discardReview(review);
      }
    } finally {
      owner.busy = false;
      if (owner.active) setBusy(false);
    }
  };

  return (
    <section aria-label={t("settings.declarativePlugins.title")} className="flex min-w-0 flex-col gap-2">
      <SettingsSectionGroup
        title={t("settings.declarativePlugins.title")}
        description={t("settings.declarativePlugins.description")}
        action={
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="ghost" disabled={refreshing || busy} onClick={() => void refresh()}>
              {t("settings.declarativePluginList.refresh")}
            </Button>
            <Button variant="accent" size="sm" disabled={refreshing || busy || Boolean(pending)} onClick={() => void importPackage()}>
              {t("settings.declarativePlugins.import")}
            </Button>
          </div>
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
          onCancel={() => {
            pendingRef.current = null;
            setPending(null);
            void discardReview(pending);
          }}
          busy={busy}
        />
      )}
      {refreshing && <p role="status" className="text-subtle-foreground ui-text-sm">{t("settings.declarativePluginList.loading")}</p>}
      <DeclarativePluginList plugins={plugins} selection={selection} onSelect={setSelection} />
      <div className="min-h-64 overflow-hidden rounded-md border border-border">
        <PluginDetailsPanel
          key={detailKey}
          selection={selection}
          workspacePath={workspacePath}
          onChanged={handleChanged}
        />
      </div>
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
      <DeclarativeMarketplaceSources onChanged={() => setMarketplaceRevision((revision) => revision + 1)} />
      <DeclarativeMarketplaceSection key={marketplaceRevision} service={marketplaceService} installed={listMarketplaceInstalledPlugins} />
    </section>
  );
}

async function discardReview(review: PreparedDeclarativeInstall): Promise<void> {
  try {
    await cancelDeclarativeDiskInstall(review.sessionId);
  } catch (reason) {
    console.warn("Could not discard plugin install review", reason);
  }
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
    <div className="flex min-w-0 flex-wrap items-start justify-between gap-3">
      <div>
        <h3 className="ui-text-sm font-semibold">{title}</h3>
        <p className="text-subtle-foreground ui-text-sm">{description}</p>
      </div>
      {action}
    </div>
  );
}
