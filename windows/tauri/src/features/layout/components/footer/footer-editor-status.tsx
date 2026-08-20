import { useEffect, useState } from "react";
import { CursorPositionChip } from "@/features/editor/components/toolbar/editor-status-actions";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useEditorStateStore } from "@/features/editor/stores/state.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { useGitStore } from "@/features/git/stores/git.store";
import { useSidebarPaneController } from "@/features/layout/hooks/use-sidebar-pane-controller";
import type { FooterTrailingItemId } from "@/features/layout/config/item-order";
import {
  ApplicationMemoryPoller,
  type ApplicationMemoryUsage,
} from "@/features/layout/services/memory-api";
import {
  countUniqueGitChanges,
  formatMemoryMegabytes,
  TEXT_FILE_ENCODING,
} from "@/features/layout/utils/footer-status";
import type { ChromeItem } from "@/features/layout/utils/chrome-items";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { CheckCircleIcon, HardDrivesIcon, LockIcon, LockOpenIcon } from "@/ui/icons";
import { FooterStatusChip, FooterStatusLabel } from "./footer-status-chip";

const MEMORY_POLL_INTERVAL_MS = 10_000;

export function useFooterEditorStatusItems(): Array<ChromeItem<FooterTrailingItemId> | null> {
  const { t } = useTranslation();
  const { openSidebarView } = useSidebarPaneController();
  const tabSize = useSettingsStore((state) => state.settings.tabSize);
  const activeEditorViewKey = useEditorStateStore.use.activeEditorViewKey();
  const gitFiles = useGitStore((state) => state.gitStatus?.files ?? state.workspaceGitStatus?.files);
  const activeBuffer = useBufferStore((state) => {
    const buffer = getBufferById(state.buffers, state.activeBufferId);
    return buffer
      ? {
          type: buffer.type,
          readOnly: buffer.type === "editor" && buffer.readOnly === true,
        }
      : null;
  });
  const [memoryUsage, setMemoryUsage] = useState<ApplicationMemoryUsage | null>(null);
  const changeCount = countUniqueGitChanges(gitFiles);
  const isEditorBuffer = activeBuffer?.type === "editor";

  useEffect(() => {
    const poller = new ApplicationMemoryPoller(setMemoryUsage);
    poller.start();
    void poller.poll();

    const intervalId = window.setInterval(() => {
      if (document.visibilityState === "hidden") return;
      void poller.poll();
    }, MEMORY_POLL_INTERVAL_MS);

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void poller.poll();
      }
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.clearInterval(intervalId);
      poller.stop();
    };
  }, []);

  return [
    isEditorBuffer
      ? {
          id: "cursor",
          label: t("footer.cursor"),
          content: <CursorPositionChip editorViewKey={activeEditorViewKey} />,
        }
      : null,
    isEditorBuffer
      ? {
          id: "encoding",
          label: t("footer.encoding"),
          content: <FooterStatusLabel>{TEXT_FILE_ENCODING}</FooterStatusLabel>,
        }
      : null,
    isEditorBuffer
      ? {
          id: "indent",
          label: t("footer.indent"),
          content: (
            <FooterStatusLabel>{t("footer.spaces", { count: tabSize })}</FooterStatusLabel>
          ),
        }
      : null,
    isEditorBuffer
      ? {
          id: "readOnly",
          label: activeBuffer.readOnly ? t("footer.readOnly") : t("footer.writable"),
          content: (
            <FooterStatusLabel
              className="px-1"
              aria-label={activeBuffer.readOnly ? t("footer.readOnly") : t("footer.writable")}
            >
              {activeBuffer.readOnly ? <LockIcon /> : <LockOpenIcon />}
            </FooterStatusLabel>
          ),
        }
      : null,
    memoryUsage
      ? {
          id: "memory",
          label: t("footer.memory"),
          content: (
            <FooterStatusLabel className="max-w-none whitespace-nowrap">
              <HardDrivesIcon />
              {t("footer.memoryUsage", {
                total: formatMemoryMegabytes(memoryUsage.totalBytes),
                used: formatMemoryMegabytes(memoryUsage.litheBytes),
              })}
            </FooterStatusLabel>
          ),
        }
      : null,
    {
      id: "gitChanges",
      label: t("workbench.changes"),
      content: (
        <FooterStatusChip
          onClick={() => openSidebarView("git")}
          aria-label={
            changeCount === 0
              ? t("footer.noChanges")
              : t(changeCount === 1 ? "footer.change" : "footer.changes", { count: changeCount })
          }
        >
          {changeCount === 0 ? (
            <CheckCircleIcon className="text-success" />
          ) : (
            t(changeCount === 1 ? "footer.change" : "footer.changes", { count: changeCount })
          )}
        </FooterStatusChip>
      ),
    },
  ];
}
