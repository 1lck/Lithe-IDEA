import { ScrollArea as ScrollAreaPrimitive } from "@base-ui/react/scroll-area";
import { useCallback, useLayoutEffect, useState } from "react";
import type * as React from "react";
import {
  bindOverlayWheelToScrollContainer,
  bindScrollContainerWheel,
} from "@/ui/scroll-container-wheel";
import { cn } from "@/utils/cn";

type ScrollAreaOrientation = "vertical" | "horizontal" | "both";

type ScrollAreaProps = React.ComponentProps<typeof ScrollAreaPrimitive.Root> & {
  orientation?: ScrollAreaOrientation;
  reserveScrollbarGutter?: boolean;
  smoothWheelScroll?: boolean;
  viewportClassName?: string;
  viewportProps?: Omit<
    React.ComponentProps<typeof ScrollAreaPrimitive.Viewport>,
    "children" | "className"
  > & {
    [key: `data-${string}`]: string | number | boolean | undefined;
  };
  contentClassName?: string;
};

function ScrollArea({
  className,
  children,
  orientation = "vertical",
  reserveScrollbarGutter = false,
  smoothWheelScroll = false,
  viewportClassName,
  viewportProps,
  contentClassName,
  ...props
}: ScrollAreaProps) {
  const { ref: viewportRef, style: viewportStyle, ...resolvedViewportProps } = viewportProps ?? {};
  const [rootNode, setRootNode] = useState<HTMLDivElement | null>(null);
  const [viewportNode, setViewportNode] = useState<HTMLDivElement | null>(null);

  useLayoutEffect(() => {
    if (!viewportNode || (smoothWheelScroll && !rootNode)) return;
    // One animator owns the viewport and its sibling scrollbars. Capturing at
    // the root also lets pointer input on a thumb cancel unfinished wheel motion.
    return bindScrollContainerWheel(viewportNode, {
      smooth: smoothWheelScroll,
      eventTarget: smoothWheelScroll ? rootNode! : viewportNode,
      // Base UI's scrollbar wheel handler writes the viewport directly even
      // after preventDefault. Once consumed here, it must not run a second time.
      stopPropagation: smoothWheelScroll,
    });
  }, [viewportNode, rootNode, smoothWheelScroll]);

  useLayoutEffect(() => {
    if (!rootNode || smoothWheelScroll) return;
    return bindOverlayWheelToScrollContainer(rootNode, () => viewportNode);
  }, [rootNode, viewportNode, smoothWheelScroll]);

  const setViewportRef = useCallback(
    (node: HTMLDivElement | null) => {
      setViewportNode(node);
      if (typeof viewportRef === "function") {
        viewportRef(node);
      } else if (viewportRef) {
        viewportRef.current = node;
      }
    },
    [viewportRef],
  );

  return (
    <ScrollAreaPrimitive.Root
      {...props}
      ref={setRootNode}
      data-slot="scroll-area"
      className={cn("group/scroll-area relative min-h-0 overflow-hidden", className)}
    >
      <ScrollAreaPrimitive.Viewport
        ref={setViewportRef}
        data-slot="scroll-area-viewport"
        className={cn(
          "size-full min-h-0 rounded-[inherit] outline-none focus-visible:ring-2 focus-visible:ring-primary/20",
          reserveScrollbarGutter && orientation !== "horizontal" && "pr-2.5",
          reserveScrollbarGutter && orientation !== "vertical" && "pb-2.5",
          viewportClassName,
        )}
        style={{
          overflowX: orientation === "vertical" ? "hidden" : "scroll",
          overflowY: orientation === "horizontal" ? "hidden" : "scroll",
          ...viewportStyle,
        }}
        {...resolvedViewportProps}
      >
        <ScrollAreaPrimitive.Content
          data-slot="scroll-area-content"
          className={cn(
            "min-h-full min-w-full",
            orientation !== "vertical" && "w-max",
            contentClassName,
          )}
          style={
            orientation === "vertical"
              ? {
                  minWidth: "100%",
                  width: "100%",
                }
              : undefined
          }
        >
          {children}
        </ScrollAreaPrimitive.Content>
      </ScrollAreaPrimitive.Viewport>
      {orientation !== "horizontal" ? <ScrollBar /> : null}
      {orientation !== "vertical" ? <ScrollBar orientation="horizontal" /> : null}
      {orientation === "both" ? (
        <ScrollAreaPrimitive.Corner
          data-slot="scroll-area-corner"
          className="absolute right-0 bottom-0 size-2.5 bg-transparent"
        />
      ) : null}
    </ScrollAreaPrimitive.Root>
  );
}

function ScrollBar({
  className,
  orientation = "vertical",
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive.Scrollbar>) {
  return (
    <ScrollAreaPrimitive.Scrollbar
      data-slot="scroll-area-scrollbar"
      orientation={orientation}
      className={cn(
        "absolute z-10 flex touch-none select-none opacity-0 transition-opacity group-hover/scroll-area:opacity-100 data-scrolling:opacity-100",
        orientation === "vertical" && "inset-y-0 right-0 w-2.5 flex-col items-center py-1",
        orientation === "horizontal" && "inset-x-0 bottom-0 h-2.5 items-center px-1",
        className,
      )}
      {...props}
    >
      {/* Base UI sizes the thumb with --scroll-area-thumb-height/width; a flex-grow
          class would stretch it over the whole track and hide how much is scrollable. */}
      <ScrollAreaPrimitive.Thumb
        data-slot="scroll-area-thumb"
        className="relative shrink-0 rounded-full bg-(--app-scrollbar-thumb) hover:bg-(--app-scrollbar-thumb-hover) data-[orientation=horizontal]:h-1.5 data-[orientation=vertical]:w-1.5"
      />
    </ScrollAreaPrimitive.Scrollbar>
  );
}

export { ScrollArea, ScrollBar };
export type { ScrollAreaOrientation, ScrollAreaProps };
