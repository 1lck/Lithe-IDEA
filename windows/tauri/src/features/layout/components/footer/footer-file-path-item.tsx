import { FilePathBreadcrumb } from "@/features/editor/components/toolbar/file-path-breadcrumb";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { FooterLeadingItemId } from "@/features/layout/config/item-order";
import type { ChromeItem } from "@/features/layout/utils/chrome-items";
import { useShallow } from "zustand/react/shallow";

export function useFooterFilePathItem(): ChromeItem<FooterLeadingItemId> | null {
  const breadcrumbsEnabled = useSettingsStore((state) => state.settings.coreFeatures.breadcrumbs);
  const activeBuffer = useBufferStore(
    useShallow((state) => {
      const buffer = getBufferById(state.buffers, state.activeBufferId);
      return buffer
        ? {
            path: buffer.path,
            type: buffer.type,
          }
        : null;
    }),
  );

  if (!breadcrumbsEnabled || !activeBuffer?.path) return null;

  return {
    id: "filePath",
    label: "File path",
    content: (
      <FilePathBreadcrumb
        filePath={activeBuffer.path}
        interactive={!activeBuffer.path.includes("://") || activeBuffer.path.startsWith("remote://")}
        menuSide="top"
        className="max-w-full"
      />
    ),
  };
}
