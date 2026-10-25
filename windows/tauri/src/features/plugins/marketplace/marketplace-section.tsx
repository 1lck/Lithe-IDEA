import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { NativeSelect, NativeSelectOption } from "@/ui/native-select";
import { describeMarketplaceError } from "./marketplace-service";
import { MarketplaceSession, type MarketplaceSessionState } from "./marketplace-session";
import {
  marketplaceEntryDescription,
  marketplaceEntryMatches,
  marketplaceInstallState,
  selectMarketplaceOffer,
  type DeclarativeMarketplaceService,
  type MarketplaceInstallState,
  type MarketplaceInstalledPlugin,
  type MarketplaceInstalledProvider,
  type MarketplaceOffer,
} from "./marketplace-types";

/**
 * Marketplace browse page for contract v1 plugin sources: cached catalog,
 * per-source refresh with retry, search, and the install pipeline with its
 * confirmation card. Everything asynchronous is owned by a
 * `MarketplaceSession` created per mount, so StrictMode remounts and page
 * close cancel this page's operations and drop late results.
 *
 * The service and the installed-list provider are injected. Until the real
 * backend bindings are wired, mounting without them renders an explicit
 * not-connected notice instead of faking a catalog.
 */

const ALL_SOURCES = "all";

const KEY_PREFIX = "settings.declarativePlugins.marketplace";

function emptySessionState(): MarketplaceSessionState {
  return {
    load: { phase: "loading" },
    sources: [],
    indexes: {},
    installed: [],
    installedReady: false,
    installedFailed: false,
    busy: {},
    errors: {},
    review: null,
  };
}

export interface DeclarativeMarketplaceSectionProps {
  service?: DeclarativeMarketplaceService;
  installed?: MarketplaceInstalledProvider;
}

/** Mountable marketplace page; the host page provides the backend bindings. */
export function DeclarativeMarketplaceSection({
  service,
  installed,
}: DeclarativeMarketplaceSectionProps) {
  const { t } = useTranslation();
  if (!service || !installed) {
    return (
      <section
        aria-label={t(`${KEY_PREFIX}.title`)}
        className="flex flex-col gap-2"
        data-testid="marketplace-not-connected"
      >
        <h3 className="ui-text-sm font-semibold">{t(`${KEY_PREFIX}.title`)}</h3>
        <p role="status" className="text-subtle-foreground ui-text-sm">
          {t(`${KEY_PREFIX}.notConnected`)}
        </p>
      </section>
    );
  }
  return <MarketplaceBrowser service={service} installed={installed} />;
}

function MarketplaceBrowser({
  service,
  installed,
}: {
  service: DeclarativeMarketplaceService;
  installed: MarketplaceInstalledProvider;
}) {
  const { t, language } = useTranslation();
  const [state, setState] = useState<MarketplaceSessionState>(emptySessionState);
  const [scope, setScope] = useState<string>(ALL_SOURCES);
  const [query, setQuery] = useState("");
  const sessionRef = useRef<MarketplaceSession | null>(null);

  useEffect(() => {
    const session = new MarketplaceSession({ service, installed, publish: setState });
    sessionRef.current = session;
    session.start();
    return () => {
      sessionRef.current = null;
      session.dispose();
    };
  }, [service, installed]);

  const installedByPluginId = useMemo(
    () => new Map(state.installed.map((plugin) => [plugin.pluginId, plugin])),
    [state.installed],
  );

  // Offers within the current scope keep source order, and one row per plugin
  // ID shows the offer the fixed-source policy picks: the install source when
  // it still lists the plugin, otherwise the first enabled source.
  const listings = useMemo(() => {
    const byPlugin = new Map<string, MarketplaceOffer[]>();
    for (const status of state.sources) {
      if (scope !== ALL_SOURCES && scope !== status.sourceId) continue;
      const index = state.indexes[status.sourceId];
      if (!index) continue;
      for (const entry of index.plugins) {
        const offers = byPlugin.get(entry.id) ?? [];
        offers.push({ sourceId: status.sourceId, sourceName: status.sourceName, entry });
        byPlugin.set(entry.id, offers);
      }
    }
    return [...byPlugin.entries()]
      .map(([pluginId, offers]) => ({
        pluginId,
        offers,
        offer: selectMarketplaceOffer(offers, installedByPluginId.get(pluginId)),
      }))
      .filter(
        (listing) =>
          listing.offer !== null && marketplaceEntryMatches(listing.offer.entry, query),
      )
      .sort((left, right) => {
        const leftName = left.offer!.entry.name.toLowerCase();
        const rightName = right.offer!.entry.name.toLowerCase();
        return leftName === rightName
          ? left.pluginId < right.pluginId
            ? -1
            : 1
          : leftName < rightName
            ? -1
            : 1;
      });
  }, [state.sources, state.indexes, scope, query, installedByPluginId]);

  const scopedSources = state.sources.filter(
    (status) => scope === ALL_SOURCES || scope === status.sourceId,
  );
  const refreshing = scopedSources.some((status) => status.refreshing);
  const ready = state.load.phase === "ready";
  const session = () => sessionRef.current;

  const changeScope = (nextScope: string) => {
    if (nextScope === scope) return;
    // Switching the source releases this page's downloads and review card;
    // the session cancels them and drops anything that arrives late.
    session()?.scopeChanged();
    setScope(nextScope);
  };

  return (
    <section
      aria-label={t(`${KEY_PREFIX}.title`)}
      className="flex flex-col gap-2"
      data-testid="marketplace-page"
    >
      <div className="flex flex-wrap items-center gap-2">
        <div className="min-w-0 flex-1 basis-48">
          <h3 className="ui-text-sm font-semibold">{t(`${KEY_PREFIX}.title`)}</h3>
          <p className="text-subtle-foreground ui-text-sm">{t(`${KEY_PREFIX}.description`)}</p>
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <input
          type="search"
          className="min-w-0 flex-1 basis-40 rounded-md border border-border bg-transparent px-2 py-1 ui-text-sm"
          placeholder={t(`${KEY_PREFIX}.searchPlaceholder`)}
          aria-label={t(`${KEY_PREFIX}.searchPlaceholder`)}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          data-testid="marketplace-search-input"
        />
        <NativeSelect
          size="sm"
          className="min-w-0"
          aria-label={t(`${KEY_PREFIX}.allSources`)}
          value={scope}
          onChange={(event) => changeScope(event.target.value)}
          data-testid="marketplace-source-select"
        >
          <NativeSelectOption value={ALL_SOURCES}>
            {t(`${KEY_PREFIX}.allSources`)}
          </NativeSelectOption>
          {state.sources.map((status) => (
            <NativeSelectOption key={status.sourceId} value={status.sourceId}>
              {status.sourceName}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <Button
          variant="accent"
          size="sm"
          disabled={!ready}
          onClick={() => session()?.refresh(scope)}
          data-testid="marketplace-refresh-button"
        >
          {refreshing ? t(`${KEY_PREFIX}.refreshing`) : t(`${KEY_PREFIX}.refresh`)}
        </Button>
      </div>
      {state.load.phase === "loading" && (
        <p className="text-subtle-foreground ui-text-sm" role="status">
          {t(`${KEY_PREFIX}.loading`)}
        </p>
      )}
      {state.load.phase === "failed" && (
        <p role="alert" className="text-destructive ui-text-sm">
          {describeOperationError(t, state.load.reason, `${KEY_PREFIX}.loadFailed`)}{" "}
          <button
            type="button"
            className="underline"
            onClick={() => session()?.retryLoad()}
            data-testid="marketplace-retry-load"
          >
            {t(`${KEY_PREFIX}.retry`)}
          </button>
        </p>
      )}
      {state.installedFailed && (
        <p role="alert" className="text-destructive ui-text-sm" data-testid="marketplace-installed-warning">
          {t(`${KEY_PREFIX}.installedWarning`)}
        </p>
      )}
      {ready && scopedSources.length === 0 && (
        <p className="text-subtle-foreground ui-text-sm">{t(`${KEY_PREFIX}.noSources`)}</p>
      )}
      {scopedSources.map(
        (status) =>
          (status.problem !== null ||
            status.refreshError !== null ||
            status.rejectedCount > 0) && (
            <div
              key={status.sourceId}
              className="flex flex-wrap items-center gap-2"
              data-testid={`marketplace-source-status-${status.sourceId}`}
            >
              <p
                role={status.problem !== null || status.refreshError !== null ? "alert" : undefined}
                className={
                  status.problem !== null || status.refreshError !== null
                    ? "text-destructive ui-text-sm"
                    : "text-subtle-foreground ui-text-sm"
                }
              >
                {status.sourceName}:{" "}
                {status.problem !== null
                  ? describeOperationError(t, status.problem, `${KEY_PREFIX}.cacheProblem`)
                  : status.refreshError !== null
                    ? describeOperationError(
                        t,
                        status.refreshError,
                        `${KEY_PREFIX}.refreshFailed`,
                      )
                    : t(`${KEY_PREFIX}.rejectedCount`, { count: status.rejectedCount })}
              </p>
              {(status.problem !== null || status.refreshError !== null) && (
                <Button
                  size="sm"
                  disabled={status.refreshing}
                  onClick={() => session()?.refresh(status.sourceId)}
                  data-testid={`marketplace-source-retry-${status.sourceId}`}
                >
                  {t(`${KEY_PREFIX}.retry`)}
                </Button>
              )}
            </div>
          ),
      )}
      {state.review && (
        <MarketplaceReviewCard
          card={state.review}
          onConfirm={() => session()?.confirmReview()}
          onCancel={() => session()?.cancelReview()}
        />
      )}
      {ready && (
        <ul className="flex flex-col gap-1" data-testid="declarative-marketplace-plugin-list">
          {listings.map(({ pluginId, offer }) => (
            <MarketplacePluginRow
              key={pluginId}
              pluginId={pluginId}
              offer={offer!}
              showSource={scope === ALL_SOURCES}
              installed={installedByPluginId.get(pluginId)}
              busy={state.busy[pluginId] ?? null}
              error={state.errors[pluginId] ?? null}
              reviewOpen={state.review?.review.prepared.review.pluginId === pluginId}
              language={language}
              onInstall={() => session()?.install(offer!.sourceId, pluginId)}
              onCancelPrepare={() => session()?.cancelInstall(pluginId)}
            />
          ))}
          {listings.length === 0 && (
            <li className="text-subtle-foreground ui-text-sm" data-testid="marketplace-empty">
              {t(`${KEY_PREFIX}.empty`)}
            </li>
          )}
        </ul>
      )}
    </section>
  );
}

function MarketplacePluginRow({
  pluginId,
  offer,
  showSource,
  installed,
  busy,
  error,
  reviewOpen,
  language,
  onInstall,
  onCancelPrepare,
}: {
  pluginId: string;
  offer: MarketplaceOffer;
  showSource: boolean;
  installed: MarketplaceInstalledPlugin | undefined;
  busy: "prepare" | "confirm" | null;
  error: string | null;
  reviewOpen: boolean;
  language: string;
  onInstall: () => void;
  onCancelPrepare: () => void;
}) {
  const { t } = useTranslation();
  const installState = marketplaceInstallState(offer, installed);
  const entry = offer.entry;
  const version =
    entry.availability.status === "available"
      ? entry.availability.version
      : entry.latestVersion ?? "";
  const busyPreparing = busy === "prepare";
  const busyConfirming = busy === "confirm";
  const canInstall =
    (installState.kind === "installable" || installState.kind === "updateAvailable") &&
    !busy &&
    !reviewOpen;

  return (
    <li
      className="flex flex-wrap items-center gap-3 rounded-md border border-border px-3 py-2"
      data-testid={`marketplace-plugin-${pluginId}`}
    >
      <div className="min-w-0 flex-1 basis-48">
        <p className="truncate ui-text-sm font-medium">
          {entry.name}{" "}
          <span className="text-subtle-foreground">
            {version ? `· ${version}` : ""} · {entry.author}
            {showSource ? ` · ${offer.sourceName}` : ""}
          </span>
        </p>
        <p className="truncate text-subtle-foreground ui-text-sm" title={entry.description}>
          {marketplaceEntryDescription(entry, language)}
        </p>
        <InstallStateLine state={installState} />
        {busyPreparing && (
          <p className="text-subtle-foreground ui-text-sm">{t(`${KEY_PREFIX}.preparing`)}</p>
        )}
        {busyConfirming && (
          <p className="text-subtle-foreground ui-text-sm">{t(`${KEY_PREFIX}.installing`)}</p>
        )}
        {reviewOpen && !busy && (
          <p className="text-subtle-foreground ui-text-sm">
            {t(`${KEY_PREFIX}.awaitingConfirmation`)}
          </p>
        )}
        {error && (
          <p role="alert" className="text-destructive ui-text-sm">
            {describeOperationError(t, error, `${KEY_PREFIX}.errorFallback`)}
          </p>
        )}
      </div>
      {busyPreparing ? (
        <Button variant="accent" size="sm" onClick={onCancelPrepare}>
          {t("ui.cancel")}
        </Button>
      ) : (
        canInstall && (
          <Button
            variant="accent"
            size="sm"
            disabled={busyConfirming}
            onClick={onInstall}
            data-testid={`marketplace-install-${pluginId}`}
          >
            {installState.kind === "updateAvailable"
              ? t(`${KEY_PREFIX}.update`)
              : t(`${KEY_PREFIX}.install`)}
          </Button>
        )
      )}
    </li>
  );
}

/** The textual status of one row; unsupported entries say why they cannot install. */
function InstallStateLine({ state }: { state: MarketplaceInstallState }) {
  const { t } = useTranslation();
  const text = (() => {
    switch (state.kind) {
      case "installable":
        return null;
      case "installed":
        return t(`${KEY_PREFIX}.state.installed`, { version: state.version });
      case "updateAvailable":
        return t(`${KEY_PREFIX}.state.updateAvailable`, {
          installed: state.installed,
          available: state.available,
        });
      case "installedFromOtherSource":
        return t(`${KEY_PREFIX}.state.fromOtherSource`, { source: state.sourceName });
      case "managedOutsideMarketplace":
        return t(`${KEY_PREFIX}.state.managedOutside`);
      case "unsupported":
        switch (state.reason) {
          case "platform":
            return t(`${KEY_PREFIX}.state.unsupported.platform`, {
              platform: state.platform ?? "",
            });
          case "api":
            return t(`${KEY_PREFIX}.state.unsupported.api`);
          default:
            return t(`${KEY_PREFIX}.state.unsupported.unknown`, { message: state.message });
        }
    }
  })();
  if (text === null) return null;
  return (
    <p className="text-subtle-foreground ui-text-sm" data-testid="marketplace-install-state">
      {text}
    </p>
  );
}

function MarketplaceReviewCard({
  card,
  onConfirm,
  onCancel,
}: {
  card: NonNullable<MarketplaceSessionState["review"]>;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const { review, displayName, availableVersion, confirming } = card;
  const { permissions, programs, newPrograms } = review.prepared.review;
  return (
    <div
      role="dialog"
      aria-label={t(`${KEY_PREFIX}.review.title`, { name: displayName, version: availableVersion })}
      className="flex flex-col gap-2 rounded-md border border-border p-3"
      data-testid="marketplace-review-card"
    >
      <p className="ui-text-sm font-medium">
        {t(`${KEY_PREFIX}.review.title`, { name: displayName, version: availableVersion })}
      </p>
      <p className="text-subtle-foreground ui-text-sm">
        {t(`${KEY_PREFIX}.review.source`, { source: review.sourceName })} · {review.indexUrl}
      </p>
      {/* Only the host's verified conclusion may show an official badge. */}
      {review.officialPublisherVerified ? (
        <p className="ui-text-sm" data-testid="marketplace-official-badge">
          {t(`${KEY_PREFIX}.review.officialVerified`)}
        </p>
      ) : (
        <p className="text-subtle-foreground ui-text-sm" data-testid="marketplace-unverified-notice">
          {t(`${KEY_PREFIX}.review.unverifiedNotice`)}
        </p>
      )}
      <p className="text-subtle-foreground ui-text-sm">{t(`${KEY_PREFIX}.review.notice`)}</p>
      {permissions.length > 0 && (
        <div className="ui-text-sm">
          <p className="font-medium">{t(`${KEY_PREFIX}.review.permissions`)}</p>
          <ul className="mt-1 list-disc pl-5">
            {permissions.map((permission) => (
              <li key={permission}>{permission}</li>
            ))}
          </ul>
        </div>
      )}
      {newPrograms.length > 0 && (
        <p className="ui-text-sm">
          {t(`${KEY_PREFIX}.review.newPrograms`, { count: newPrograms.length })}
        </p>
      )}
      {programs.length > 0 && <ProgramDeclarationList programs={programs} />}
      <div className="flex gap-2">
        <Button
          size="sm"
          disabled={confirming}
          onClick={onConfirm}
          data-testid="marketplace-review-confirm"
        >
          {t("settings.declarativePlugins.confirmInstall")}
        </Button>
        <Button
          size="sm"
          variant="accent"
          disabled={confirming}
          onClick={onCancel}
          data-testid="marketplace-review-cancel"
        >
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
    <div className="ui-text-sm">
      <button
        type="button"
        className="text-left underline"
        onClick={() => setExpanded((value) => !value)}
        data-testid="marketplace-review-programs-toggle"
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

/** Maps a raw session rejection to localized text; known host rejections get
 * their own wording and unknown ones keep the raw message for diagnosis. */
function describeOperationError(
  t: (key: string, values?: Record<string, string | number>) => string,
  reason: string,
  fallbackKey: string,
): string {
  const described = describeMarketplaceError(reason);
  if (described.key === "generic") {
    return `${t(fallbackKey)} (${reason})`;
  }
  return t(`${KEY_PREFIX}.error.${described.key}`);
}
