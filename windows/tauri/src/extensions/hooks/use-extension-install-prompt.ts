import { useEffect, useRef } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useToast } from "@/features/layout/contexts/toast-context";
import { useTranslation } from "@/i18n/locale-provider";
import { useExtensionStore } from "../registry/extension-store";

interface ExtensionInstallNeededEvent {
  extensionId: string;
  extensionName: string;
  filePath: string;
}

// Track active prompts at module level to persist across re-renders
const activePrompts = new Map<string, string>();

export const useExtensionInstallPrompt = () => {
  const { t } = useTranslation();
  const { showToast, dismissToast, updateToast, hasToast } = useToast();
  const { installExtension } = useExtensionStore.use.actions();
  const dismissedExtensions = useRef<Set<string>>(new Set());

  useEffect(() => {
    const handleInstallNeeded = (event: Event) => {
      const customEvent = event as CustomEvent<ExtensionInstallNeededEvent>;
      const { extensionId, extensionName, filePath } = customEvent.detail;

      // Check if already installed in store (synchronous check to handle timing issues)
      const { installedExtensions } = useExtensionStore.getState();
      if (installedExtensions.has(extensionId)) {
        return;
      }

      // Don't show if user already dismissed this extension prompt in this session
      if (dismissedExtensions.current.has(extensionId)) {
        return;
      }

      // Don't show multiple toasts for the same extension
      const existingToastId = activePrompts.get(extensionId);
      if (existingToastId && hasToast(existingToastId)) {
        return;
      }

      const toastId = showToast({
        message: t("extensions.installPrompt", { name: extensionName }),
        type: "info",
        duration: 0, // Don't auto-dismiss
        action: {
          label: t("extensions.install"),
          onClick: async () => {
            try {
              // Update toast to show installing status
              updateToast(toastId, {
                message: t("extensions.installing", { name: extensionName }),
                action: undefined, // Remove action button while installing
              });

              // Install the extension
              await installExtension(extensionId);

              // Show success
              updateToast(toastId, {
                message: t("extensions.installSuccess", { name: extensionName }),
                type: "success",
              });

              // Re-trigger tokenization for the current file
              const { activeBufferId, buffers } = useBufferStore.getState();
              const activeBuffer = buffers.find((b) => b.id === activeBufferId);
              if (activeBuffer && activeBuffer.path === filePath) {
                // Dispatch event to re-tokenize the file
                window.dispatchEvent(
                  new CustomEvent("extension-installed", {
                    detail: { extensionId, filePath },
                  }),
                );
              }

              // Auto-dismiss success message after 3 seconds
              setTimeout(() => {
                dismissToast(toastId);
                activePrompts.delete(extensionId);
              }, 3000);
            } catch (error) {
              // Show error
              const errorMessage =
                error instanceof Error ? error.message : t("extensions.installFailedGeneric");
              console.error(`Failed to install ${extensionName}:`, error);

              updateToast(toastId, {
                message: t("extensions.installFailedWithMessage", {
                  name: extensionName,
                  message: errorMessage,
                }),
                type: "error",
                action: {
                  label: t("ui.retry"),
                  onClick: () => {
                    // Retry installation
                    dismissToast(toastId);
                    activePrompts.delete(extensionId);
                    window.dispatchEvent(
                      new CustomEvent("extension-install-needed", {
                        detail: customEvent.detail,
                      }),
                    );
                  },
                },
              });
            }
          },
        },
      });

      activePrompts.set(extensionId, toastId);
    };

    const handleToastDismiss = (event: Event) => {
      const customEvent = event as CustomEvent<{ toastId: string }>;
      const { toastId } = customEvent.detail;

      // Find and remove the extension from activePrompts if its toast was dismissed
      for (const [extId, tId] of activePrompts.entries()) {
        if (tId === toastId) {
          activePrompts.delete(extId);
          // Mark as dismissed so we don't show again this session
          dismissedExtensions.current.add(extId);
          break;
        }
      }
    };

    window.addEventListener("extension-install-needed", handleInstallNeeded);
    window.addEventListener("toast-dismissed", handleToastDismiss);

    return () => {
      window.removeEventListener("extension-install-needed", handleInstallNeeded);
      window.removeEventListener("toast-dismissed", handleToastDismiss);
    };
  }, [t, showToast, dismissToast, updateToast, installExtension, hasToast]);
};
