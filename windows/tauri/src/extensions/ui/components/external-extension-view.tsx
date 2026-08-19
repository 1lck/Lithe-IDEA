import { useCallback, useEffect, useState } from "react";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import { Spinner } from "@/ui/spinner";
import { uiExtensionHost } from "../services/ui-extension-host";
import { useUIExtensionStore } from "../stores/ui-extension-store";
import type { ExtensionViewAction, ExtensionViewNode } from "../types/extension-view";
import { ExtensionViewRenderer } from "./extension-view-renderer";

interface ExternalExtensionViewProps {
  extensionId: string;
  viewId: string;
}

export function ExternalExtensionView({ extensionId, viewId }: ExternalExtensionViewProps) {
  const { t } = useTranslation();
  const revision = useUIExtensionStore((state) => state.viewRevisions.get(viewId) ?? 0);
  const [node, setNode] = useState<ExtensionViewNode | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let current = true;
    setError(null);
    void uiExtensionHost
      .renderView(extensionId, viewId)
      .then((result) => current && setNode(result))
      .catch((cause) => {
        if (current) setError(cause instanceof Error ? cause.message : String(cause));
      });
    return () => {
      current = false;
    };
  }, [extensionId, revision, viewId]);

  const execute = useCallback(
    (action: ExtensionViewAction, extraArgs: unknown[] = []) => {
      void uiExtensionHost
        .executeCommand(extensionId, action.command, [...(action.args ?? []), ...extraArgs])
        .catch((cause) => setError(cause instanceof Error ? cause.message : String(cause)));
    },
    [extensionId],
  );

  if (error) {
    return (
      <Empty tone="error" role="alert">
        <EmptyHeader>
          <EmptyTitle>{t("extensions.extensionError")}</EmptyTitle>
          <EmptyDescription>{error}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }
  if (!node) {
    return <Spinner showLabel label={t("extensions.loadingExtension")} className="m-auto" />;
  }
  return <ExtensionViewRenderer node={node} execute={execute} />;
}
