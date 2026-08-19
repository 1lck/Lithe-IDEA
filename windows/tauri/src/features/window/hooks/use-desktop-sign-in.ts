import { openUrl } from "@tauri-apps/plugin-opener";
import { useState } from "react";
import { toast } from "sonner";
import { useAuthStore } from "@/features/window/stores/auth.store";
import { useTranslation } from "@/i18n/locale-provider";
import {
  beginDesktopAuthSession,
  DesktopAuthError,
  waitForDesktopAuthToken,
} from "@/features/window/services/auth-api";

interface UseDesktopSignInOptions {
  apiBase?: string;
  onSuccess?: () => void;
}

export function useDesktopSignIn(options: UseDesktopSignInOptions = {}) {
  const { t } = useTranslation();
  const handleAuthCallback = useAuthStore((state) => state.actions.handleAuthCallback);
  const [isSigningIn, setIsSigningIn] = useState(false);

  const signIn = async () => {
    setIsSigningIn(true);

    try {
      const { sessionId, pollSecret, loginUrl, apiBase } = await beginDesktopAuthSession({
        apiBase: options.apiBase,
      });
      await openUrl(loginUrl);
      toast.info(t("auth.completeSignInInBrowser"));

      const token = await waitForDesktopAuthToken(sessionId, pollSecret, undefined, {
        apiBase,
      });
      await handleAuthCallback(token);
      toast.success(t("auth.signedInSuccessfully"));
      options.onSuccess?.();
    } catch (error) {
      if (error instanceof DesktopAuthError && error.code === "endpoint_unavailable") {
        toast.error(t("auth.desktopEndpointUnavailable"));
      } else {
        const message = error instanceof Error ? error.message : t("auth.authenticationFailed");
        toast.error(message);
      }

      throw error;
    } finally {
      setIsSigningIn(false);
    }
  };

  return {
    isSigningIn,
    signIn,
  };
}
