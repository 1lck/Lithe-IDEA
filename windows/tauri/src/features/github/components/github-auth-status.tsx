import { WarningCircleIcon as AlertCircle } from "@/ui/icons";
import { openUrl } from "@tauri-apps/plugin-opener";
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
import { useDesktopSignIn } from "@/features/window/hooks/use-desktop-sign-in";
import { useAuthStore } from "@/features/window/stores/auth.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Spinner } from "@/ui/spinner";
import { GITHUB_ACCOUNT_API_BASE, GITHUB_CONNECTION_URL } from "../services/github-token-service";
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
  const githubAccountStatus = useGitHubStore.use.githubAccountStatus();
  const authError = useGitHubStore.use.authError();
  const isCheckingAuth = useGitHubStore.use.isCheckingAuth();
  const checkAuth = useGitHubStore.use.actions().checkAuth;
  const isLitheAuthenticated = useAuthStore((s) => s.isAuthenticated);
  const isLitheAuthLoading = useAuthStore((s) => s.isLoading);
  const { t } = useTranslation();
  const { signIn, isSigningIn } = useDesktopSignIn({
    apiBase: GITHUB_ACCOUNT_API_BASE,
    onSuccess: () => void checkAuth({ force: true }),
  });

  const retry = () => void checkAuth({ force: true });
  const openGitHubConnection = () => void openUrl(GITHUB_CONNECTION_URL);

  if (
    isLitheAuthLoading ||
    isCheckingAuth ||
    (isLitheAuthenticated && githubAccountStatus === "unknown")
  ) {
    return (
      <Empty className="rounded-none p-4">
        <EmptyDescription>
          <Spinner label={t("github.checkingAccount")} showLabel compact />
        </EmptyDescription>
      </Empty>
    );
  }

  if (authError && githubAccountStatus === "unknown") {
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

  if (!isLitheAuthenticated || githubAccountStatus === "notSignedIn") {
    return (
      <GitHubAuthState
        title={t("github.accountRequired")}
        description={t("github.accountRequiredDescription")}
        error={authError}
      >
        <Button
          onClick={() => void signIn().catch(() => undefined)}
          variant="ghost"
          size="xs"
          disabled={isSigningIn}
          className="h-auto px-0 text-primary hover:bg-transparent hover:text-primary/80"
          aria-label={t("github.signInToLithe")}
        >
          {isSigningIn ? t("github.signingIn") : t("account.signIn")}
        </Button>
      </GitHubAuthState>
    );
  }

  if (githubAccountStatus === "notConnected") {
    return (
      <GitHubAuthState
        title={t("github.notConnected")}
        description={t("github.notConnectedDescription")}
        error={authError}
      >
        <Button
          onClick={openGitHubConnection}
          variant="ghost"
          className="h-auto px-0 text-primary hover:bg-transparent hover:text-primary/80"
          aria-label={t("github.connectGitHub")}
          size="xs"
        >
          {t("github.connectGitHub")}
        </Button>
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
        onClick={openGitHubConnection}
        variant="ghost"
        className="h-auto px-0 text-primary hover:bg-transparent hover:text-primary/80"
        aria-label={t("github.connectGitHub")}
        size="xs"
      >
        {t("github.connectGitHub")}
      </Button>
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
