import type React from "react";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import { useRunPreferencesStore } from "../stores/run-preferences.store";
import {
  RUN_CONFIGURATION_LIST_HANDLE_THICKNESS,
  RUN_CONFIGURATION_LIST_MIN_WIDTH,
  clampRunConfigurationListWidth,
  getRunConfigurationListMaxWidth,
} from "../utils/run-configuration-list-layout";
import {
  nextRunConfigurationListWidthForKey,
  startDocumentResizeSession,
  type DocumentResizeSession,
} from "../utils/run-configuration-list-resize-session";

interface RunConfigurationListSplitProps {
  list: React.ReactNode;
  content: React.ReactNode;
}

/**
 * Local layout container for the Run tool window's configuration list.
 * Keeps drag width mutations out of RunPane and only commits when a resize
 * session ends, matching macOS LitheSplitPaneView persistence.
 */
export function RunConfigurationListSplit({ list, content }: RunConfigurationListSplitProps) {
  const { t } = useTranslation();
  const storedWidth = useRunPreferencesStore((state) => state.configurationListWidth);
  const setConfigurationListWidth = useRunPreferencesStore(
    (state) => state.actions.setConfigurationListWidth,
  );
  const containerRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const sessionRef = useRef<DocumentResizeSession | null>(null);
  const isMountedRef = useRef(true);
  const [containerWidth, setContainerWidth] = useState(0);
  const [width, setWidth] = useState(() =>
    clampRunConfigurationListWidth(storedWidth, typeof window !== "undefined" ? window.innerWidth : 1280),
  );
  const [isResizing, setIsResizing] = useState(false);

  const clampWidth = useCallback(
    (value: number) => clampRunConfigurationListWidth(value, containerWidth || 1280),
    [containerWidth],
  );

  const commitWidth = useCallback(
    (nextWidth: number) => {
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
      setContainerWidth(nextContainerWidth);
      setWidth((current) => clampRunConfigurationListWidth(current, nextContainerWidth));
    };

    updateWidth();
    const observer = new ResizeObserver(updateWidth);
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    setWidth(clampWidth(storedWidth));
  }, [storedWidth, clampWidth]);

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
      const nextWidth = nextRunConfigurationListWidthForKey(
        width,
        event.key,
        containerWidth || 1280,
      );
      if (nextWidth == null) {
        return;
      }

      event.preventDefault();
      setWidth(nextWidth);
      setConfigurationListWidth(nextWidth);
    },
    [width, containerWidth, setConfigurationListWidth],
  );

  const minWidth = Math.min(
    RUN_CONFIGURATION_LIST_MIN_WIDTH,
    getRunConfigurationListMaxWidth(containerWidth || 1280),
  );
  const maxWidth = getRunConfigurationListMaxWidth(containerWidth || 1280);

  return (
    <div ref={containerRef} className="flex min-h-0 min-w-0 flex-1">
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
          className={cn(
            "group absolute top-0 right-0 z-20 flex h-full translate-x-1/2 cursor-col-resize items-center justify-center",
            "transition-colors duration-(--app-duration-fast) ease-(--app-ease-smooth) hover:bg-primary/8",
          )}
          role="separator"
          aria-orientation="vertical"
          aria-label={t("run.resizeConfigurationList")}
          aria-valuenow={Math.round(width)}
          aria-valuemin={Math.round(minWidth)}
          aria-valuemax={Math.round(maxWidth)}
          tabIndex={0}
        >
          <div
            className={cn(
              "h-full w-px bg-transparent transition-colors duration-(--app-duration-fast) ease-(--app-ease-smooth) group-hover:bg-primary",
              isResizing && "bg-primary",
            )}
          />
        </div>
      </div>
      {isResizing ? <div className="fixed inset-0 z-40 cursor-col-resize" /> : null}
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">{content}</div>
    </div>
  );
}
