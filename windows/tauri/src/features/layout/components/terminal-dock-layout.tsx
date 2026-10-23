import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTerminalStore } from "@/features/terminal/stores/terminal.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { TerminalWindowIcon } from "@/ui/icons";
import { clampResponsivePaneWidth } from "../utils/resizable-pane-layout";

type DockPosition = "bottom" | "left" | "right";
interface TerminalDock {
  position: DockPosition;
  activitySide: "left" | "right";
  width: number;
  height: number;
  clampWidth: (value: number) => number;
  clampHeight: (value: number) => number;
  resize: (value: number) => void;
  startDrag: (event: ReactPointerEvent, fromActivity?: boolean) => void;
  suppressActivityClick: (keyboard: boolean) => boolean;
  toggle: (keyboard: boolean) => void;
}
const TerminalDockContext = createContext<TerminalDock | null>(null);
export const useTerminalDock = () => useContext(TerminalDockContext);

// Note: 拖动和会话生命周期见 .agents/notes/implemented/architecture/2026-10-12-tool-window-docking.md。
export function TerminalDockLayout({
  sidebar,
  editor,
  tools,
  panel,
  leftRail,
  rightRail,
  workspaceKey,
}: {
  sidebar: ReactNode;
  editor: ReactNode;
  tools: ReactNode;
  panel: ReactNode;
  leftRail?: ReactNode;
  rightRail?: ReactNode;
  workspaceKey: string;
}) {
  const { t } = useTranslation();
  const storedPosition = useSettingsStore((state) => state.settings.terminalDockPosition);
  const storedWidth = useSettingsStore((state) => state.settings.terminalDockWidth);
  const storedHeight = useSettingsStore((state) => state.settings.bottomPaneHeight);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const activeTab = useUIState((state) => state.bottomPaneActiveTab);
  const visible = useUIState((state) => state.isBottomPaneVisible);
  const widthMode = useTerminalStore((state) => state.widthMode);
  const position = activeTab === "terminal" ? storedPosition : "bottom";
  const workbenchRef = useRef<HTMLDivElement>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<HTMLDivElement>(null);
  const sidebarRef = useRef<HTMLDivElement>(null);
  const toolsRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const cancelDrag = useRef<(() => void) | null>(null);
  const suppressClick = useRef(false);
  const [activationWorkspace, setActivationWorkspace] = useState<string | null>(null);
  const [space, setSpace] = useState({ width: window.innerWidth, height: window.innerHeight });
  const [preview, setPreview] = useState<{
    position: DockPosition;
    left: number;
    top: number;
    width: number;
    height: number;
  } | null>(null);
  const clampWidth = (value: number) =>
    clampResponsivePaneWidth({
      value,
      minWidth: 200,
      viewportWidth: space.width,
      reservedWidth: 0,
    });
  const clampHeight = (value: number) =>
    Math.min(Math.max(value, Math.min(200, space.height * 0.8)), space.height * 0.8);
  const width = clampWidth(storedWidth);
  const height = clampHeight(storedHeight);

  useLayoutEffect(() => {
    const measure = () => {
      const grid = gridRef.current!;
      const next = {
        width: Math.max(
          0,
          grid.clientWidth - sidebarRef.current!.offsetWidth - toolsRef.current!.offsetWidth,
        ),
        height: grid.clientHeight,
      };
      setSpace((previous) =>
        previous.width === next.width && previous.height === next.height ? previous : next,
      );
    };
    measure();
    const observer = new window.ResizeObserver(measure);
    for (const element of [gridRef.current, sidebarRef.current, toolsRef.current]) {
      if (element) observer.observe(element);
    }
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    cancelDrag.current?.();
    return () => cancelDrag.current?.();
  }, [workspaceKey, visible, activeTab, storedPosition, widthMode]);

  useEffect(() => {
    if (activationWorkspace === null) return;
    setActivationWorkspace(null);
    // xterm cannot focus a hidden pane. Wait for React to commit visibility,
    // and discard an activation superseded by a workspace/tool change.
    if (activationWorkspace === workspaceKey && visible && activeTab === "terminal") {
      window.dispatchEvent(new window.CustomEvent("terminal-ensure-session"));
    }
  }, [activationWorkspace, workspaceKey, visible, activeTab]);

  const startDrag = (event: ReactPointerEvent, fromActivity = false) => {
    if (event.button !== 0 || (!fromActivity && (activeTab !== "terminal" || !visible))) return;
    event.preventDefault();
    event.stopPropagation();
    cancelDrag.current?.();
    suppressClick.current = false;
    // Freeze geometry for the entire gesture; preview and hit testing use the same rectangles.
    const grid = gridRef.current!.getBoundingClientRect();
    const workbench = workbenchRef.current!.getBoundingClientRect();
    const editorBounds = editorRef.current!.getBoundingClientRect();
    const panelBounds = panelRef.current!.getBoundingClientRect();
    const styles = window.getComputedStyle(gridRef.current!);
    const gap = (name: string) => Number.parseFloat(styles.getPropertyValue(name)) || 0;
    const bottomHeight =
      position === "bottom" && visible
        ? panelBounds.height
        : height + gap("--lithe-bottom-pane-gap");
    const sideWidth =
      position !== "bottom" && visible ? panelBounds.width : width + gap("--lithe-workbench-gap");
    const bottomLeft =
      widthMode === "full"
        ? grid.left
        : editorBounds.left - (position === "left" ? panelBounds.width : 0);
    const bottomRight =
      widthMode === "full"
        ? grid.right
        : editorBounds.right + (position === "right" ? panelBounds.width : 0);
    const pointerId = event.pointerId;
    const startX = event.clientX;
    const startY = event.clientY;
    const oldCursor = document.body.style.cursor;
    const oldSelect = document.body.style.userSelect;
    let started = false;
    let disposed = false;
    let target: DockPosition | null = null;
    const resolve = (x: number, y: number): DockPosition | null => {
      if (x < workbench.left || x > workbench.right || y < grid.top || y > grid.bottom) return null;
      // Activity stripes are drop targets too, including their lower corners.
      if (x < grid.left) return "left";
      if (x > grid.right) return "right";
      // The current edge wins at the corner, so a horizontal drag along the bottom stays there.
      const bottom = x >= bottomLeft && x <= bottomRight && y >= grid.bottom - bottomHeight;
      const right = x >= grid.right - sideWidth;
      const left = x <= grid.left + sideWidth;
      if (position === "bottom" && bottom) return "bottom";
      if (position === "left" && left) return "left";
      if (position === "right" && right) return "right";
      if (bottom) return "bottom";
      if (right) return "right";
      if (left) return "left";
      return null;
    };
    const move = (pointer: PointerEvent) => {
      if (pointer.pointerId !== pointerId) return;
      if (!started && Math.hypot(pointer.clientX - startX, pointer.clientY - startY) < 6) return;
      started = true;
      suppressClick.current = true;
      document.body.style.cursor = "grabbing";
      document.body.style.userSelect = "none";
      const next = resolve(pointer.clientX, pointer.clientY);
      if (next === target) return;
      target = next;
      setPreview(
        next === null
          ? null
          : {
              position: next,
              left:
                next === "right"
                  ? grid.width - sideWidth
                  : next === "left"
                    ? 0
                    : bottomLeft - grid.left,
              top: next === "bottom" ? grid.height - bottomHeight : 0,
              width: next === "bottom" ? bottomRight - bottomLeft : sideWidth,
              height: next === "bottom" ? bottomHeight : grid.height,
            },
      );
    };
    const cleanup = () => {
      if (disposed) return;
      disposed = true;
      document.removeEventListener("pointermove", move, true);
      document.removeEventListener("pointerup", drop, true);
      document.removeEventListener("pointercancel", cancel, true);
      document.removeEventListener("keydown", keydown, true);
      window.removeEventListener("blur", cancel);
      window.removeEventListener("resize", cancel);
      document.body.style.cursor = oldCursor;
      document.body.style.userSelect = oldSelect;
      setPreview(null);
      cancelDrag.current = null;
    };
    const cancel = () => {
      suppressClick.current = true;
      cleanup();
    };
    const keydown = (key: KeyboardEvent) => {
      if (key.key === "Escape") {
        key.preventDefault();
        key.stopPropagation();
        cancel();
      }
    };
    const drop = (pointer: PointerEvent) => {
      if (pointer.pointerId !== pointerId) return;
      const destination = started ? resolve(pointer.clientX, pointer.clientY) : null;
      cleanup();
      if (destination) {
        updateSetting("terminalDockPosition", destination);
        if (fromActivity) {
          const ui = useUIState.getState();
          ui.setBottomPaneActiveTab("terminal");
          ui.setIsBottomPaneVisible(true);
          setActivationWorkspace(workspaceKey);
        }
      }
    };
    cancelDrag.current = cancel;
    document.addEventListener("pointermove", move, true);
    document.addEventListener("pointerup", drop, true);
    document.addEventListener("pointercancel", cancel, true);
    document.addEventListener("keydown", keydown, true);
    window.addEventListener("blur", cancel);
    window.addEventListener("resize", cancel);
  };

  return (
    <TerminalDockContext.Provider
      value={{
        position,
        activitySide: storedPosition === "right" ? "right" : "left",
        width,
        height,
        clampWidth,
        clampHeight,
        startDrag,
        suppressActivityClick: (keyboard) => !keyboard && suppressClick.current,
        resize: (value) =>
          updateSetting(position === "bottom" ? "bottomPaneHeight" : "terminalDockWidth", value),
        toggle: (keyboard) => {
          if (keyboard || !suppressClick.current)
            updateSetting("terminalDockPosition", position === "bottom" ? "right" : "bottom");
        },
      }}
    >
      <div
        ref={workbenchRef}
        data-terminal-dock-workbench
        className="relative flex min-h-0 min-w-0 flex-1 overflow-hidden"
      >
        {leftRail}
        <div
          ref={gridRef}
          data-terminal-dock={position}
          className="relative grid min-h-0 min-w-0 flex-1 overflow-hidden"
          style={{
            gridTemplateColumns:
              position === "left"
                ? "auto auto minmax(0, 1fr) auto"
                : position === "right"
                  ? "auto minmax(0, 1fr) auto auto"
                  : "auto minmax(0, 1fr) auto",
            gridTemplateRows: position !== "bottom" ? "minmax(0, 1fr)" : "minmax(0, 1fr) auto",
            gridTemplateAreas:
              position === "left"
                ? '"panel sidebar editor tools"'
                : position === "right"
                  ? '"sidebar editor tools panel"'
                  : widthMode === "full"
                    ? '"sidebar editor tools" "panel panel panel"'
                    : '"sidebar editor tools" "sidebar panel tools"',
          }}
        >
          <div ref={sidebarRef} className="flex min-h-0 min-w-0" style={{ gridArea: "sidebar" }}>
            {sidebar}
          </div>
          <div
            ref={editorRef}
            className="flex min-h-0 min-w-0 flex-col"
            style={{ gridArea: "editor" }}
          >
            {editor}
          </div>
          <div ref={toolsRef} className="flex min-h-0 min-w-0" style={{ gridArea: "tools" }}>
            {tools}
          </div>
          <div
            ref={panelRef}
            className="flex min-h-0 min-w-0 flex-col"
            style={{ gridArea: "panel" }}
          >
            {panel}
          </div>
          {preview && (
            <div
              data-terminal-dock-preview={preview.position}
              className="pointer-events-none absolute z-50 flex items-center justify-center rounded-(--lithe-island-radius) border-2 border-primary bg-primary/20 text-foreground"
              style={{
                left: preview.left,
                top: preview.top,
                width: preview.width,
                height: preview.height,
              }}
            >
              <span className="rounded bg-background px-3 py-1">
                {t(
                  preview.position === "right"
                    ? "terminal.dockRight"
                    : preview.position === "left"
                      ? "terminal.dockLeft"
                      : "terminal.dockBottom",
                )}
              </span>
            </div>
          )}
        </div>
        {rightRail}
      </div>
    </TerminalDockContext.Provider>
  );
}

export function TerminalDockHandle({ disabled = false }: { disabled?: boolean }) {
  const dock = useTerminalDock();
  const { t } = useTranslation();
  if (!dock || disabled) return null;
  return (
    <Button
      variant="ghost"
      size="icon-xs"
      className="cursor-grab touch-none"
      aria-label={t("terminal.movePanel")}
      tooltip={t("terminal.movePanel")}
      tooltipSide="bottom"
      onPointerDown={(event) => dock.startDrag(event)}
      onClick={(event) => dock.toggle(event.detail === 0)}
    >
      <TerminalWindowIcon />
    </Button>
  );
}
