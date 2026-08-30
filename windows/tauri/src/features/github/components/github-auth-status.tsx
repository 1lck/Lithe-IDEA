import { WarningCircleIcon as AlertCircle } from "@/ui/icons";
import type { ReactNode } from "react";
import { Button } from "@/ui/button";
import {
  Empty,
  EmptyContent,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import { Spinner } from "@/ui/spinner";
import { useGitHubStore } from "../stores/github.store";

function GitHubAuthState({
  title,
  description,
  error,
  children,
  tone = "neutral",
}: {
  title: string;
  description: string;
  error?: string | null;
  children?: ReactNode;
  tone?: "neutral" | "error";
}) {
  return (
    <Empty tone={tone} className="rounded-none p-4" role={tone === "error" ? "alert" : undefined}>
      <EmptyHeader>
        <EmptyMedia>
          <AlertCircle />
        </EmptyMedia>
        <EmptyTitle>{title}</EmptyTitle>
        <EmptyDescription>{description}</EmptyDescription>
        {error ? <EmptyDescription>{error}</EmptyDescription> : null}
      </EmptyHeader>
      {children ? <EmptyContent className="flex-row">{children}</EmptyContent> : null}
    </Empty>
  );
}

export function GitHubAuthStatusMessage() {
  const authError = useGitHubStore.use.authError();
  const isCheckingAuth = useGitHubStore.use.isCheckingAuth();
  const checkAuth = useGitHubStore.use.actions().checkAuth;
  const { t } = useTranslation();

  const retry = () => void checkAuth({ force: true });

  if (isCheckingAuth) {
    return (
      <Empty className="rounded-none p-4">
        <EmptyDescription>
          <Spinner label={t("github.checkingAccount")} showLabel compact />
        </EmptyDescription>
      </Empty>
    );
  }

  if (authError) {
    return (
      <GitHubAuthState
        title={t("github.temporarilyUnavailable")}
        description={authError}
        tone="error"
      >
        <Button
          onClick={retry}
          variant="ghost"
          className="h-auto px-0 text-primary hover:bg-transparent hover:text-primary/80"
          aria-label={t("github.retryAuthCheck")}
          size="xs"
        >
          {t("github.retry")}
        </Button>
      </GitHubAuthState>
    );
  }

  return (
    <GitHubAuthState
      title={t("github.notAuthenticated")}
      description={t("github.notAuthenticatedDescription")}
      error={authError}
    >
      <Button
        onClick={retry}
        variant="ghost"
        className="h-auto px-0 text-primary hover:bg-transparent hover:text-primary/80"
        aria-label={t("github.retryAuthCheck")}
        size="xs"
      >
        {t("github.retry")}
      </Button>
    </GitHubAuthState>
  );
}
