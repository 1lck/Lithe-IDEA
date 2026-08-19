import type { ReactNode } from "react";
import { LockIcon as Lock } from "@/ui/icons";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import { useProFeature } from "../hooks/use-pro-feature";
import { ProBadge } from "./pro-badge";

interface ProGateProps {
  children: ReactNode;
  fallback?: ReactNode;
}

export function ProGate({ children, fallback }: ProGateProps) {
  const { t } = useTranslation();
  const { hasHostedAi } = useProFeature();

  if (hasHostedAi) {
    return <>{children}</>;
  }

  if (fallback) {
    return <>{fallback}</>;
  }

  return (
    <Empty>
      <EmptyHeader>
        <EmptyMedia variant="icon" className="size-10 rounded-full bg-primary/10 text-primary">
          <Lock className="size-5" />
        </EmptyMedia>
        <EmptyTitle className="flex items-center gap-2">
          {t("extensions.proFeature")}
          <ProBadge />
        </EmptyTitle>
        <EmptyDescription>{t("extensions.upgradeToPro")}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}
