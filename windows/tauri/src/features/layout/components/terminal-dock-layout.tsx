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

type DockPosition = "bottom" | "right";
interface TerminalDock {
  position: DockPosition;
  width: number;
  height: number;
  clampWidth: (value: number) => number;
  clampHeight: (value: number) => number;
  resize: (value: number) => void;
  startDrag: (event: ReactPointerEvent) => void;
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
  workspaceKey,
}: {
  sidebar: ReactNode;
  editor: ReactNode;
  tools: ReactNode;
  panel: ReactNode;
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
  const gridRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<HTMLDivElement>(null);
  const sidebarRef = useRef<HTMLDivElement>(null);
  const toolsRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const cancelDrag = useRef<(() => void) | null>(null);
  const suppressClick = useRef(false);
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

  const startDrag = (event: ReactPointerEvent) => {
    if (event.button !== 0 || activeTab !== "terminal" || !visible) return;
    event.preventDefault();
    event.stopPropagation();
    cancelDrag.current?.();
    suppressClick.current = false;
    // Freeze geometry for the entire gesture; preview and hit testing use the same rectangles.
    const grid = gridRef.current!.getBoundingClientRect();
    const editorBounds = editorRef.current!.getBoundingClientRect();
    const panelBounds = panelRef.current!.getBoundingClientRect();
    const styles = window.getComputedStyle(gridRef.current!);
    const gap = (name: string) => Number.parseFloat(styles.getPropertyValue(name)) || 0;
    const bottomHeight =
      position === "bottom" ? panelBounds.height : height + gap("--lithe-bottom-pane-gap");
    const rightWidth =
      position === "right" ? panelBounds.width : width + gap("--lithe-workbench-gap");
    const bottomLeft = widthMode === "full" ? grid.left : editorBounds.left;
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
      if (x < grid.left || x > grid.right || y < grid.top || y > grid.bottom) return null;
      // The current edge wins at the corner, so a horizontal drag along the bottom stays there.
      const bottom = x >= bottomLeft && x <= bottomRight && y >= grid.bottom - bottomHeight;
      const right = x >= grid.right - rightWidth;
      if (position === "bottom" && bottom) return "bottom";
      if (right) return "right";
      return bottom ? "bottom" : null;
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
              left: next === "right" ? grid.width - rightWidth : bottomLeft - grid.left,
              top: next === "right" ? 0 : grid.height - bottomHeight,
              width: next === "right" ? rightWidth : bottomRight - bottomLeft,
              height: next === "right" ? grid.height : bottomHeight,
            },
      );
    };
    const cleanup = () => {
      if (disposed) return;
      disposed = true;
      document.removeEventListener("pointermove", move, true);
      document.removeEventListener("pointerup", drop, true);
      document.removeEventListener("pointercancel", cancel, true);
      document.removeEventListener("keydown", keydown);
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
        cancel();
      }
    };
    const drop = (pointer: PointerEvent) => {
      if (pointer.pointerId !== pointerId) return;
      const destination = started ? resolve(pointer.clientX, pointer.clientY) : null;
      cleanup();
      if (destination) updateSetting("terminalDockPosition", destination);
    };
    cancelDrag.current = cancel;
    document.addEventListener("pointermove", move, true);
    document.addEventListener("pointerup", drop, true);
    document.addEventListener("pointercancel", cancel, true);
    document.addEventListener("keydown", keydown);
    window.addEventListener("blur", cancel);
    window.addEventListener("resize", cancel);
  };

  return (
    <TerminalDockContext.Provider
      value={{
        position,
        width,
        height,
        clampWidth,
        clampHeight,
        startDrag,
        resize: (value) =>
          updateSetting(position === "right" ? "terminalDockWidth" : "bottomPaneHeight", value),
        toggle: (keyboard) => {
          if (keyboard || !suppressClick.current)
            updateSetting("terminalDockPosition", position === "right" ? "bottom" : "right");
        },
      }}
    >
      <div
        ref={gridRef}
        data-terminal-dock={position}
        className="relative grid min-h-0 min-w-0 flex-1 overflow-hidden"
        style={{
          gridTemplateColumns:
            position === "right" ? "auto minmax(0, 1fr) auto auto" : "auto minmax(0, 1fr) auto",
          gridTemplateRows: position === "right" ? "minmax(0, 1fr)" : "minmax(0, 1fr) auto",
          gridTemplateAreas:
            position === "right"
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
        <div ref={panelRef} className="flex min-h-0 min-w-0 flex-col" style={{ gridArea: "panel" }}>
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
              {t(preview.position === "right" ? "terminal.dockRight" : "terminal.dockBottom")}
            </span>
          </div>
        )}
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
      onPointerDown={dock.startDrag}
      onClick={(event) => dock.toggle(event.detail === 0)}
    >
      <TerminalWindowIcon />
    </Button>
  );
}
