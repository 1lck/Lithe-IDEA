import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Switch from "@/ui/switch";
import {
  addDeclarativeMarketplaceSource,
  listDeclarativeMarketplaceSources,
  removeDeclarativeMarketplaceSource,
  setDeclarativeMarketplaceSourceEnabled,
  type DeclarativeMarketplaceSource,
  type DeclarativeMarketplaceSourcesState,
} from "./declarative-marketplace-sources";

/**
 * Source management for the declarative marketplace. The parent invalidates
 * its browsing session after a successful source mutation.
 *
 * Async discipline:
 * - Mutations are serialized by a synchronous in-flight flag checked at
 *   every entry (keyboard and pointer paths share it), so double-Enter or
 *   Enter+click can never reach the host twice.
 * - Reads and mutations own separate lifetimes: a read that started while a
 *   mutation was in flight is discarded no matter which resolves first, so
 *   a language switch cannot clobber a pending mutation, and the mutation's
 *   `finally` clears the busy flag unconditionally — a later read can never
 *   strand it.
 * - No response touches an unmounted component, and operations stay
 *   disabled until the first load resolves.
 */
export function DeclarativeMarketplaceSources({ onChanged }: { onChanged?: () => void }) {
  const { t, language } = useTranslation();
  const [state, setState] = useState<DeclarativeMarketplaceSourcesState | null>(null);
  const [urlInput, setUrlInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<{
    kind: "load" | "mutation";
    message: string;
  } | null>(null);
  const requestRef = useRef(0);
  const lastMutationStartRef = useRef(0);
  const inFlightRef = useRef(false);
  const mountedRef = useRef(true);
  // The flag is set on every mount (StrictMode remounts included) and only
  // cleared when the component really unmounts.
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);
  // Translations resolve at call time so `load` stays a stable read of the
  // list; the localized strings it produces are always the current ones.
  const tRef = useRef(t);
  tRef.current = t;
  const onChangedRef = useRef(onChanged);
  onChangedRef.current = onChanged;

  const applyIfMounted = useCallback((update: () => void) => {
    if (!mountedRef.current) return;
    update();
  }, []);

  // A read only owns the list when no mutation was in flight (or started
  // earlier) when the read began; otherwise the mutation's authoritative
  // list wins and the read is discarded whatever the resolve order is.
  const readOwnsState = useCallback((request: number) => {
    return !inFlightRef.current && request > lastMutationStartRef.current;
  }, []);

  const load = useCallback(async () => {
    const request = ++requestRef.current;
    const ownsState = readOwnsState(request);
    try {
      const next = await listDeclarativeMarketplaceSources();
      if (!ownsState || request !== requestRef.current) return;
      applyIfMounted(() => {
        setState(next);
        // A successful retry only resolves a previous read failure. A
        // language-triggered read must not erase a newer mutation failure
        // that still needs the user's attention.
        setError((current) => (current?.kind === "load" ? null : current));
        if (next.problem) {
          // The localized notice renders; the raw host diagnosis stays in
          // the log where a report can include it.
          console.warn("declarative marketplace sources:", next.problem);
        }
      });
    } catch (reason) {
      console.warn("declarative marketplace sources load failed:", reason);
      if (!ownsState || request !== requestRef.current) return;
      applyIfMounted(() =>
        setError({
          kind: "load",
          message: tRef.current("settings.declarativePlugins.sources.errorLoad"),
        }),
      );
    }
    // A language switch re-reads the list on purpose; the t reference is
    // resolved through tRef so the callback identity only follows the
    // language.
  }, [applyIfMounted, language, readOwnsState]);

  useEffect(() => {
    void load();
  }, [load]);

  // Host rejections carry stable plugin.* codes; the user sees localized
  // text, and the raw reason only reaches the log.
  const describeError = useCallback(
    (reason: unknown) => {
      const message = reason instanceof Error ? reason.message : String(reason);
      console.warn("declarative marketplace sources operation failed:", reason);
      if (message.includes("plugin.marketplace.sourceAlreadyAdded")) {
        return t("settings.declarativePlugins.sources.errorAlreadyAdded");
      }
      if (message.includes("plugin.marketplace.officialSourceCannotBeRemoved")) {
        return t("settings.declarativePlugins.sources.errorOfficialCannotBeRemoved");
      }
      if (message.includes("plugin.marketplace.sourceNotFound")) {
        return t("settings.declarativePlugins.sources.errorNotFound");
      }
      if (
        message.includes("plugin.marketplace.sources.emptyInput") ||
        message.includes("plugin.source.invalid")
      ) {
        return t("settings.declarativePlugins.sources.errorInvalidInput");
      }
      return t("settings.declarativePlugins.sources.errorGeneric");
    },
    [t],
  );

  // The one serialized mutation path. The synchronous in-flight gate makes
  // re-entry from keyboard and pointer alike a no-op, and the busy flag is
  // always cleared in `finally` — never subject to request generations — so
  // a language switch during an operation can never strand it.
  const runSourceAction = useCallback(
    (
      action: () => Promise<DeclarativeMarketplaceSource[]>,
      onSuccess: (next: DeclarativeMarketplaceSource[]) => void,
    ) => {
      if (inFlightRef.current || state === null) return;
      inFlightRef.current = true;
      const request = ++requestRef.current;
      lastMutationStartRef.current = request;
      setBusy(true);
      setError(null);
      void action()
        .then((next) => {
          applyIfMounted(() => {
            // A successful rewrite replaced the store, so any earlier
            // corruption notice no longer describes the current file.
            setState({ sources: next, problem: null });
            onSuccess(next);
            onChangedRef.current?.();
          });
        })
        .catch((reason: unknown) => {
          const described = describeError(reason);
          applyIfMounted(() => setError({ kind: "mutation", message: described }));
        })
        .finally(() => {
          inFlightRef.current = false;
          applyIfMounted(() => setBusy(false));
        });
    },
    [applyIfMounted, describeError, state],
  );

  const addSource = () => {
    const url = urlInput.trim();
    if (!url) return;
    runSourceAction(
      () => addDeclarativeMarketplaceSource(url),
      () => setUrlInput((current) => current.trim() === url ? "" : current),
    );
  };

  const ready = state !== null && !busy;

  return (
    <div className="flex flex-col gap-1" data-testid="declarative-marketplace-sources">
      <div>
        <h3 className="ui-text-sm font-semibold">
          {t("settings.declarativePlugins.sources.title")}
        </h3>
        <p className="text-subtle-foreground ui-text-sm">
          {t("settings.declarativePlugins.sources.description")}
        </p>
      </div>
      <div className="flex gap-2">
        <input
          type="text"
          className="min-w-0 flex-1 rounded-md border border-border bg-transparent px-2 py-1 ui-text-sm"
          placeholder={t("settings.declarativePlugins.sources.addPlaceholder")}
          aria-label={t("settings.declarativePlugins.sources.addPlaceholder")}
          value={urlInput}
          disabled={state === null}
          onChange={(event) => setUrlInput(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") addSource();
          }}
        />
        <Button
          variant="accent"
          size="sm"
          disabled={!ready || !urlInput.trim()}
          onClick={addSource}
        >
          {t("settings.declarativePlugins.sources.add")}
        </Button>
      </div>
      {error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {error.message}
          {state === null && error.kind === "load" && (
            <>
              {" "}
              <button type="button" className="underline" onClick={() => void load()}>
                {t("settings.declarativePlugins.sources.retry")}
              </button>
            </>
          )}
        </p>
      )}
      {state?.problem && (
        <p role="alert" className="text-destructive ui-text-sm">
          {t("settings.declarativePlugins.sources.corruptNotice")}
        </p>
      )}
      <ul className="flex flex-col gap-1" data-testid="declarative-marketplace-source-list">
        {(state?.sources ?? []).map((source) => (
          <SourceRow
            key={source.id}
            source={source}
            busy={busy || state === null}
            onToggle={(enabled) =>
              runSourceAction(
                () => setDeclarativeMarketplaceSourceEnabled(source.id, enabled),
                () => {},
              )
            }
            onRemove={() =>
              runSourceAction(
                () => removeDeclarativeMarketplaceSource(source.id),
                () => {},
              )
            }
          />
        ))}
        {state && !state.sources.some((source) => source.kind === "thirdParty") && (
          <li className="text-subtle-foreground ui-text-sm">
            {t("settings.declarativePlugins.sources.empty")}
          </li>
        )}
      </ul>
    </div>
  );
}

function SourceRow({
  source,
  busy,
  onToggle,
  onRemove,
}: {
  source: DeclarativeMarketplaceSource;
  busy: boolean;
  onToggle: (enabled: boolean) => void;
  onRemove: () => void;
}) {
  const { t } = useTranslation();
  return (
    <li className="flex items-center gap-3 rounded-md border border-border px-3 py-2">
      <div className="min-w-0 flex-1">
        <p
          className="truncate ui-text-sm font-medium"
          data-testid={`declarative-marketplace-source-${source.id}`}
        >
          {source.name}
          <span className="text-subtle-foreground">
            {" "}
            · {t(`settings.declarativePlugins.sources.${source.kind}`)}
          </span>
        </p>
        <p className="truncate text-subtle-foreground ui-text-sm">{source.indexURL}</p>
      </div>
      <Switch
        checked={source.isEnabled}
        disabled={busy}
        onChange={onToggle}
        aria-label={t("settings.declarativePlugins.sources.toggle", { name: source.name })}
      />
      {source.deletable && (
        <Button variant="danger" size="sm" disabled={busy} onClick={onRemove}>
          {t("settings.declarativePlugins.sources.remove")}
        </Button>
      )}
    </li>
  );
}
