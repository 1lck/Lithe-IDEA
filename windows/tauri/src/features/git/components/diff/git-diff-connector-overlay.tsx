import {
  ArrowLeftIcon as ArrowLeft,
  ArrowRightIcon as ArrowRight,
  ArrowsLeftRightIcon as ArrowsLeftRight,
} from "@/ui/icons";
import { useLayoutEffect, useRef } from "react";
import type { SplitDiffTransition } from "../../utils/git-diff-split-layout";

export const GIT_DIFF_CONNECTOR_GUTTER_WIDTH = 28;

interface GitDiffConnectorOverlayProps {
  transitions: SplitDiffTransition[];
  rowHeight: number;
}

function getMarkerTop(transition: SplitDiffTransition, rowHeight: number): number {
  if (transition.kind === "addition") return transition.leftStart * rowHeight;
  if (transition.kind === "removal") return transition.rightStart * rowHeight;

  return (
    Math.min(
      (transition.leftStart + transition.leftEnd) / 2,
      (transition.rightStart + transition.rightEnd) / 2,
    ) * rowHeight
  );
}

export default function GitDiffConnectorOverlay({
  transitions,
  rowHeight,
}: GitDiffConnectorOverlayProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const draw = () => {
      const width = canvas.clientWidth;
      const height = canvas.clientHeight;
      const density = window.devicePixelRatio || 1;
      canvas.width = Math.max(1, Math.round(width * density));
      canvas.height = Math.max(1, Math.round(height * density));

      const context = canvas.getContext("2d");
      if (!context) return;

      context.setTransform(density, 0, 0, density, 0, 0);
      context.clearRect(0, 0, width, height);

      const styles = window.getComputedStyle(canvas);
      const addedColor = styles.getPropertyValue("--git-added").trim() || "#4ade80";
      const deletedColor = styles.getPropertyValue("--git-deleted").trim() || "#f87171";
      const leftX = Math.max(0, (width - GIT_DIFF_CONNECTOR_GUTTER_WIDTH) / 2);
      const rightX = leftX + GIT_DIFF_CONNECTOR_GUTTER_WIDTH;
      const controlX1 = leftX + GIT_DIFF_CONNECTOR_GUTTER_WIDTH * 0.42;
      const controlX2 = leftX + GIT_DIFF_CONNECTOR_GUTTER_WIDTH * 0.58;

      for (const transition of transitions) {
        const color = transition.kind === "removal" ? deletedColor : addedColor;
        const leftStart = transition.leftStart * rowHeight;
        const leftEnd = transition.leftEnd * rowHeight;
        const rightStart = transition.rightStart * rowHeight;
        const rightEnd = transition.rightEnd * rowHeight;

        context.beginPath();
        context.moveTo(leftX, leftStart);
        context.bezierCurveTo(controlX1, leftStart, controlX2, rightStart, rightX, rightStart);
        context.lineTo(rightX, rightEnd);
        context.bezierCurveTo(controlX2, rightEnd, controlX1, leftEnd, leftX, leftEnd);
        context.closePath();
        context.globalAlpha = 0.18;
        context.fillStyle = color;
        context.fill();
        context.globalAlpha = 0.5;
        context.strokeStyle = color;
        context.lineWidth = 1;
        context.lineCap = "round";
        context.lineJoin = "round";
        context.stroke();

        context.globalAlpha = 0.66;
        context.beginPath();
        if (transition.kind === "addition") {
          const y = Math.max(0.5, Math.min(height - 0.5, leftStart));
          context.moveTo(4, y);
          context.lineTo(leftX, y);
        } else if (transition.kind === "removal") {
          const y = Math.max(0.5, Math.min(height - 0.5, rightStart));
          context.moveTo(rightX, y);
          context.lineTo(Math.max(rightX, width - 4), y);
        }
        context.stroke();
        context.globalAlpha = 1;
      }
    };

    draw();
    const observer = new ResizeObserver(draw);
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [rowHeight, transitions]);

  return (
    <div className="pointer-events-none absolute inset-0 z-10" aria-hidden="true">
      <canvas ref={canvasRef} className="absolute inset-0 size-full" />
      {transitions.map((transition) => {
        const colorClass =
          transition.kind === "removal" ? "text-git-deleted" : "text-git-added";
        const markerTop = getMarkerTop(transition, rowHeight);
        const Marker =
          transition.kind === "addition"
            ? ArrowRight
            : transition.kind === "removal"
              ? ArrowLeft
              : ArrowsLeftRight;

        return (
          <span
            key={transition.id}
            className={`absolute left-1/2 flex size-3.5 -translate-x-1/2 items-center justify-center ${colorClass}`}
            style={{ top: `${markerTop - 7}px` }}
          >
            <Marker size={11} />
          </span>
        );
      })}
    </div>
  );
}
