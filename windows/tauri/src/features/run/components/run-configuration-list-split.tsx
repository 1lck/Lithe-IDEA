import type React from "react";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useRunPreferencesStore } from "../stores/run-preferences.store";
import {
  RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
  RUN_CONFIGURATION_LIST_MIN_WIDTH,
  clampRunConfigurationListWidth,
  getRunConfigurationListMaxWidth,
  getRunLanguageColumnWidth,
  getRunLanguageColumnMaxWidth,
  RUN_LANGUAGE_COLUMN_COMPACT_WIDTH,
  RUN_LANGUAGE_COLUMN_MIN_WIDTH,
  runLanguageColumnDragWidth,
} from "../utils/run-configuration-list-layout";
import {
  nextRunConfigurationListWidthForKey,
  RUN_CONFIGURATION_LIST_RESIZE_STEP,
  startDocumentResizeSession,
  type DocumentResizeSession,
} from "../utils/run-configuration-list-resize-session";

interface RunConfigurationListSplitProps {
  languages?: (compact: boolean) => React.ReactNode;
  list: React.ReactNode;
  content: React.ReactNode;
}

/**
 * Local layout container for the Run tool window's configuration list.
 * Keeps drag width mutations out of RunPane and only commits when a resize
 * session ends, matching macOS LitheSplitPaneView persistence.
 */
export function RunConfigurationListSplit({
  languages,
  list,
  content,
}: RunConfigurationListSplitProps) {
  const { t } = useTranslation();
  const storedWidth = useRunPreferencesStore((state) => state.configurationListWidth);
  const storedLanguageWidth = useRunPreferencesStore((state) => state.languageColumnWidth);
  const languageCollapsed = useRunPreferencesStore((state) => state.languageColumnCollapsed);
  const setLanguageColumnLayout = useRunPreferencesStore(
    (state) => state.actions.setLanguageColumnLayout,
  );
  const setConfigurationListWidth = useRunPreferencesStore(
    (state) => state.actions.setConfigurationListWidth,
  );
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const languageRef = useRef<HTMLDivElement>(null);
  const observedWidthRef = useRef(0);
  const sessionRef = useRef<DocumentResizeSession | null>(null);
  const isMountedRef = useRef(true);
  const [containerWidth, setContainerWidth] = useState(0);
  const [width, setWidth] = useState(() =>
    clampRunConfigurationListWidth(
      storedWidth,
      typeof window !== "undefined" ? window.innerWidth : 1280,
    ),
  );
  const [isResizing, setIsResizing] = useState(false);
  const hasLanguages = Boolean(languages);
  const availableWidth = containerWidth || 1280;
  const languageWidth = hasLanguages
    ? getRunLanguageColumnWidth(availableWidth, storedLanguageWidth, languageCollapsed)
    : 0;
  const compact = languageWidth === RUN_LANGUAGE_COLUMN_COMPACT_WIDTH;
  const languageMaxWidth = getRunLanguageColumnMaxWidth(availableWidth);
  const canExpandLanguage = languageMaxWidth >= RUN_LANGUAGE_COLUMN_MIN_WIDTH;
  const listContainerWidth =
    availableWidth - languageWidth - (hasLanguages ? RUN_CONFIGURATION_LIST_HANDLE_THICKNESS : 0);

  const clampWidth = useCallback(
    (value: number) => clampRunConfigurationListWidth(value, listContainerWidth),
    [listContainerWidth],
  );

  const commitWidth = useCallback(
    (nextWidth: number) => {
      if (listRef.current) listRef.current.style.width = `${nextWidth}px`;
      setConfigurationListWidth(nextWidth);
      if (isMountedRef.current) {
        setWidth(nextWidth);
        setIsResizing(false);
      }
      sessionRef.current = null;
    },
    [setConfigurationListWidth],
  );

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const updateWidth = () => {
      const nextContainerWidth = container.getBoundingClientRect().width;
      if (nextContainerWidth !== observedWidthRef.current) {
        // A drag's bounds belong to its starting layout; end it before changing those bounds.
        sessionRef.current?.dispose({ commit: true });
        observedWidthRef.current = nextContainerWidth;
      }
      setContainerWidth(nextContainerWidth);
    };

    updateWidth();
    const observer = new ResizeObserver(updateWidth);
    observer.observe(container);
    return () => observer.disconnect();
  }, [hasLanguages]);

  useLayoutEffect(() => {
    setWidth(clampWidth(storedWidth));
  }, [storedWidth, clampWidth]);

  const handleLanguagePointerDown = useCallback(
    (event: React.PointerEvent) => {
      if (!canExpandLanguage) return;
      event.preventDefault();
      sessionRef.current?.dispose({ commit: true });
      const languageEl = languageRef.current;
      const listEl = listRef.current;
      let previewWidth = languageWidth;
      let moved = false;
      const applyLanguageWidth = (nextWidth: number) => {
        if (languageEl) {
          languageEl.style.width = `${nextWidth}px`;
          // CSS switches labels and centering locally, without rendering the React tree per frame.
          languageEl.dataset.compact = String(nextWidth === RUN_LANGUAGE_COLUMN_COMPACT_WIDTH);
        }
        if (listEl) {
          listEl.style.width = `${clampRunConfigurationListWidth(
            storedWidth,
            availableWidth - nextWidth - RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
          )}px`;
        }
      };
      sessionRef.current = startDocumentResizeSession({
        startX: event.clientX,
        startWidth: languageWidth,
        clampWidth: (value) => {
          moved = true;
          previewWidth = runLanguageColumnDragWidth(
            value,
            availableWidth,
            previewWidth === RUN_LANGUAGE_COLUMN_COMPACT_WIDTH,
          );
          return previewWidth;
        },
        applyWidth: applyLanguageWidth,
        commitWidth: (nextWidth) => {
          // Pointerup may cancel the last frame, including a return to the unchanged starting state.
          applyLanguageWidth(nextWidth);
          if (moved) {
            const collapsed = nextWidth === RUN_LANGUAGE_COLUMN_COMPACT_WIDTH;
            setLanguageColumnLayout(collapsed ? storedLanguageWidth : nextWidth, collapsed);
          }
          if (isMountedRef.current) setIsResizing(false);
          sessionRef.current = null;
        },
        onActiveChange: (active) => {
          if (isMountedRef.current) setIsResizing(active);
        },
      });
    },
    [
      availableWidth,
      canExpandLanguage,
      languageWidth,
      storedLanguageWidth,
      storedWidth,
      setLanguageColumnLayout,
    ],
  );

  const handleLanguageKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      if (!canExpandLanguage || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
      event.preventDefault();
      sessionRef.current?.dispose({ commit: true });
      if (event.key === "ArrowLeft" && languageWidth <= RUN_LANGUAGE_COLUMN_MIN_WIDTH) {
        setLanguageColumnLayout(storedLanguageWidth, true);
      } else {
        const nextWidth = getRunLanguageColumnWidth(
          availableWidth,
          compact
            ? storedLanguageWidth
            : languageWidth +
                (event.key === "ArrowLeft"
                  ? -RUN_CONFIGURATION_LIST_RESIZE_STEP
                  : RUN_CONFIGURATION_LIST_RESIZE_STEP),
        );
        setLanguageColumnLayout(nextWidth, false);
      }
    },
    [
      availableWidth,
      canExpandLanguage,
      languageWidth,
      compact,
      storedLanguageWidth,
      setLanguageColumnLayout,
    ],
  );

  useEffect(() => {
    isMountedRef.current = true;
    return () => {
      isMountedRef.current = false;
      // Persist the in-flight width, then drop listeners/body styles/RAF.
      sessionRef.current?.dispose({ commit: true });
      sessionRef.current = null;
    };
  }, []);

  const handlePointerDown = useCallback(
    (event: React.PointerEvent) => {
      event.preventDefault();
      sessionRef.current?.dispose({ commit: true });

      const listEl = listRef.current;
      sessionRef.current = startDocumentResizeSession({
        startX: event.clientX,
        startWidth: width,
        clampWidth,
        applyWidth: (nextWidth) => {
          if (listEl) {
            listEl.style.width = `${nextWidth}px`;
          }
        },
        commitWidth,
        onActiveChange: (active) => {
          if (isMountedRef.current) {
            setIsResizing(active);
          }
        },
      });
    },
    [width, clampWidth, commitWidth],
  );

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      const nextWidth = nextRunConfigurationListWidthForKey(width, event.key, listContainerWidth);
      if (nextWidth == null) {
        return;
      }

      event.preventDefault();
      sessionRef.current?.dispose({ commit: true });
      setWidth(nextWidth);
      setConfigurationListWidth(nextWidth);
    },
    [width, listContainerWidth, setConfigurationListWidth],
  );

  const minWidth = Math.min(
    RUN_CONFIGURATION_LIST_MIN_WIDTH,
    getRunConfigurationListMaxWidth(listContainerWidth),
  );
  const maxWidth = getRunConfigurationListMaxWidth(listContainerWidth);

  return (
    <div ref={containerRef} className="flex min-h-0 min-w-0 flex-1">
      {languages ? (
        <div
          ref={languageRef}
          data-compact={compact}
          style={{ width: languageWidth }}
          className="group/run-languages relative flex min-h-0 shrink-0 flex-col border-border/70 border-r"
        >
          {languages(compact)}
          <div
            onPointerDown={handleLanguagePointerDown}
            onKeyDown={handleLanguageKeyDown}
            style={{ width: RUN_CONFIGURATION_LIST_HANDLE_THICKNESS }}
            className="absolute top-0 right-0 z-20 h-full translate-x-1/2 cursor-col-resize"
            role="separator"
            aria-orientation="vertical"
            aria-label={t("run.resizeLanguages")}
            title={t("run.resizeLanguagesHint")}
            aria-valuenow={Math.round(languageWidth)}
            aria-valuemin={RUN_LANGUAGE_COLUMN_COMPACT_WIDTH}
            aria-valuemax={Math.round(canExpandLanguage ? languageMaxWidth : languageWidth)}
            aria-disabled={!canExpandLanguage}
            tabIndex={canExpandLanguage ? 0 : -1}
          />
        </div>
      ) : null}
      <div
        ref={listRef}
        style={{ width: `${width}px` }}
        className="relative flex min-h-0 shrink-0 flex-col border-border/70 border-r"
      >
        {list}
        <div
          onPointerDown={handlePointerDown}
          onKeyDown={handleKeyDown}
          style={{ width: RUN_CONFIGURATION_LIST_HANDLE_THICKNESS }}
          className="absolute top-0 right-0 z-20 h-full translate-x-1/2 cursor-col-resize"
          role="separator"
          aria-orientation="vertical"
          aria-label={t("run.resizeConfigurationList")}
          aria-valuenow={Math.round(width)}
          aria-valuemin={Math.round(minWidth)}
          aria-valuemax={Math.round(maxWidth)}
          tabIndex={0}
        />
      </div>
      {isResizing ? <div className="fixed inset-0 z-40 cursor-col-resize" /> : null}
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">{content}</div>
    </div>
  );
}
