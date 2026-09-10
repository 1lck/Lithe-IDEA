import { useDeferredValue, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useGroupRef, type Layout } from "react-resizable-panels";
import { useBufferStore } from "../stores/buffer.store";
import { getBufferById } from "../utils/buffer-index";
import { hasTextContent } from "@/features/panes/types/pane-content.types";
import { useTranslation } from "@/i18n/locale-provider";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";

type ViewMode = "editor" | "split" | "preview";

export function SvgEditor({
  enabled,
  bufferId,
  children,
}: {
  enabled: boolean;
  bufferId?: string;
  children: ReactNode;
}) {
  if (!enabled) return children;
  return (
    <SvgEditorSurface key={bufferId} bufferId={bufferId}>
      {children}
    </SvgEditorSurface>
  );
}

function SvgEditorSurface({ bufferId, children }: { bufferId?: string; children: ReactNode }) {
  const { t } = useTranslation();
  const [mode, setMode] = useState<ViewMode>("split");
  const groupRef = useGroupRef();
  const splitLayout = useRef<Layout>({ editor: 50, preview: 50 });
  useLayoutEffect(() => {
    groupRef.current?.setLayout(
      mode === "split"
        ? splitLayout.current
        : {
            editor: mode === "editor" ? 100 : 0,
            preview: mode === "preview" ? 100 : 0,
          },
    );
  }, [mode, groupRef]);
  function selectMode(next: ViewMode) {
    if (next === mode) return;
    if (mode === "split" && groupRef.current) {
      const layout = groupRef.current.getLayout();
      if (layout.editor > 0 && layout.preview > 0) splitLayout.current = layout;
    }
    setMode(next);
  }
  return (
    <div className="flex h-full min-h-0 flex-col">
      <div
        className="flex shrink-0 justify-end gap-1 border-b border-border p-1"
        role="group"
        aria-label={t("svg.viewMode")}
      >
        {(["editor", "split", "preview"] as const).map((value) => (
          <button
            key={value}
            type="button"
            aria-pressed={mode === value}
            className={`rounded px-2 py-1 text-xs hover:bg-hover ${mode === value ? "bg-hover text-foreground" : "text-muted-foreground"}`}
            onClick={() => selectMode(value)}
          >
            {t(`svg.${value}`)}
          </button>
        ))}
      </div>
      <div className="relative min-h-0 flex-1">
        {/* Keep Monaco mounted: releasing its last model owner discards undo history. */}
        <ResizablePanelGroup
          orientation="horizontal"
          groupRef={groupRef}
          disabled={mode !== "split"}
        >
          <ResizablePanel id="editor" defaultSize="50%" minSize={mode === "split" ? "20%" : "0%"}>
            <div className="relative h-full" hidden={mode === "preview"}>
              {children}
            </div>
          </ResizablePanel>
          <ResizableHandle
            aria-label={t("svg.resize")}
            disabled={mode !== "split"}
            style={mode === "split" ? undefined : { display: "none" }}
          />
          <ResizablePanel id="preview" defaultSize="50%" minSize={mode === "split" ? "20%" : "0%"}>
            {mode !== "editor" && <SvgPreview bufferId={bufferId} />}
          </ResizablePanel>
        </ResizablePanelGroup>
      </div>
    </div>
  );
}

function SvgPreview({ bufferId }: { bufferId?: string }) {
  const { t } = useTranslation();
  const source = useBufferStore((state) => {
    const buffer = getBufferById(state.buffers, bufferId ?? null);
    return buffer && hasTextContent(buffer) ? buffer.content : "";
  });
  const content = useDeferredValue(source);
  // An image resource cannot execute SVG scripts or access external resources.
  // Keep it out of the application's DOM and render the unsaved buffer directly.
  const src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(content)}`;
  const [failedSource, setFailedSource] = useState<string | null>(null);
  return (
    <div className="flex h-full min-w-0 items-center justify-center overflow-auto bg-background p-4">
      {failedSource === src ? (
        <p role="status" className="text-sm text-muted-foreground">
          {t("svg.invalid")}
        </p>
      ) : (
        <img
          key={src}
          src={src}
          alt={t("svg.preview")}
          className="max-h-full max-w-full object-contain"
          onError={() => setFailedSource(src)}
        />
      )}
    </div>
  );
}
