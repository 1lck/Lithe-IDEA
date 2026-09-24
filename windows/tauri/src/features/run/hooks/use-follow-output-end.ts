import { type RefObject, useEffect } from "react";

/**
 * Keeps `containerRef` scrolled to its newest output while `enabled`.
 *
 * Follows only while the container is laid out: a display:none container
 * reports no usable scroll geometry, so updates made while hidden are caught
 * by re-scrolling when `visible` turns true again.
 */
export function useFollowOutputEnd(
  containerRef: RefObject<HTMLElement | null>,
  output: string,
  enabled: boolean,
  visible: boolean,
): void {
  useEffect(() => {
    if (!enabled || !visible) return;
    const node = containerRef.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [containerRef, output, enabled, visible]);
}
