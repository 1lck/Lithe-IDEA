import { openUrl } from "@tauri-apps/plugin-opener";
import { useEffect, useRef, useState } from "react";
import { getServiceUrls } from "@/config/services";
import { useAIChatStore } from "@/features/ai/stores/ai-chat.store";
import {
  extractAutocompleteUsage,
  formatUsageDate,
  formatUsdFromCents,
  getAccountPlanLabel,
  getAiUsageModeLabel,
  getUsageProgress,
} from "@/features/window/lib/account-usage";
import { useAuthStore } from "@/features/window/stores/auth.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { Dropdown, MenuItemsList, type MenuItem } from "@/ui/dropdown";
import {
  BookOpenIcon,
  CreditCardIcon,
  MoneyIcon,
  OpenExternalIcon,
  GearSixIcon,
  SignInIcon,
  SignOutIcon,
  UserIcon,
  UsersThreeIcon,
} from "@/ui/icons";
import { Progress } from "@/ui/progress";
import Tooltip from "@/ui/tooltip";
import { useDesktopSignIn } from "@/features/window/hooks/use-desktop-sign-in";
import { cn } from "@/utils/cn";
import { useTranslation } from "@/i18n/locale-provider";

interface AccountMenuProps {
  className?: string;
}

export const AccountMenu = ({ className }: AccountMenuProps) => {
  const { t } = useTranslation();
  const services = getServiceUrls();
  const user = useAuthStore((s) => s.user);
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated);
  const subscription = useAuthStore((s) => s.subscription);
  const logout = useAuthStore((s) => s.actions.logout);
  const checkAllProviderApiKeys = useAIChatStore((state) => state.actions.checkAllProviderApiKeys);
  const hasOpenRouterKey = useAIChatStore(
    (state) => state.providerApiKeys.get("openrouter") || false,
  );
  const setIsSettingsDialogVisible = useUIState((state) => state.setIsSettingsDialogVisible);
  const openSettingsDialog = useUIState((state) => state.openSettingsDialog);
  const hasBlockingModalOpen = useUIState(
    (state) =>
      state.isQuickOpenVisible ||
      state.isCommandPaletteVisible ||
      state.isGlobalSearchVisible ||
      state.isSettingsDialogVisible ||
      state.isProjectPickerVisible ||
      state.isDatabaseConnectionVisible,
  );

  const [isOpen, setIsOpen] = useState(false);
  const buttonRef = useRef<HTMLButtonElement>(null);
  const { signIn, isSigningIn } = useDesktopSignIn({
    onSuccess: () => setIsOpen(false),
  });

  const handleSignIn = async () => {
    if (import.meta.env.DEV) {
      console.log("[Auth] Starting desktop sign-in flow from account menu");
    }
    await signIn();
  };

  const handleSignOut = async () => {
    await logout();
  };

  const handleManageAccount = async () => {
    await openUrl(services.dashboardUrl);
  };

  const handleOpenBillingDashboard = async () => {
    await openUrl(services.dashboardBillingUrl);
  };

  const handleOpenDocs = async () => {
    await openUrl(services.docsUrl);
  };

  const handleOpenSettings = () => {
    setIsSettingsDialogVisible(true);
  };

  const handleOpenCollaboration = () => {
    openSettingsDialog("collaboration");
  };

  const subscriptionStatus = subscription?.status ?? "free";
  const isEnterprise = subscription?.subscription?.plan === "enterprise";
  const isTeams = Boolean(subscription?.collaboration?.enabled);
  const isPro = subscriptionStatus === "pro";
  const planLabel = t(`account.plan.${getAccountPlanLabel(subscription, isAuthenticated)}`);
  const modeLabel = t(
    `account.aiUsageMode.${getAiUsageModeLabel({ isAuthenticated, subscription, hasOpenRouterKey })}`,
  );
  const autocompleteUsage = extractAutocompleteUsage(subscription);
  const usageProgress = getUsageProgress(autocompleteUsage);

  const signedOutItems: MenuItem[] = [
    {
      id: "settings",
      label: t("account.settings"),
      icon: <GearSixIcon />,
      onClick: handleOpenSettings,
    },
    {
      id: "docs",
      label: t("account.docs"),
      icon: <BookOpenIcon />,
      onClick: handleOpenDocs,
    },
    {
      id: "settings-separator",
      label: "",
      separator: true,
      onClick: () => {},
    },
    {
      id: "sign-in",
      label: isSigningIn ? t("account.signingIn") : t("account.signIn"),
      icon: <SignInIcon />,
      onClick: handleSignIn,
      disabled: isSigningIn,
    },
  ];

  const signedInItems: MenuItem[] = [
    {
      id: "user-info",
      label: user?.name || user?.email || t("account.account"),
      icon: user?.avatar_url ? (
        <img src={user.avatar_url} alt="" className="size-3 rounded-full" />
      ) : (
        <UserIcon />
      ),
      onClick: () => {},
      disabled: true,
    },
    {
      id: "plan-separator",
      label: "",
      separator: true,
      onClick: () => {},
    },
    {
      id: "subscription",
      label: t("account.planWithName", { plan: planLabel }),
      icon: <CreditCardIcon />,
      onClick: handleOpenBillingDashboard,
    },
    ...(isTeams
      ? [
          {
            id: "collaboration",
            label: t("account.collaboration"),
            icon: <UsersThreeIcon />,
            onClick: handleOpenCollaboration,
          },
        ]
      : []),
    {
      id: "manage-account",
      label: t("account.manageAccount"),
      icon: <OpenExternalIcon />,
      onClick: handleManageAccount,
    },
    {
      id: "settings",
      label: t("account.settings"),
      icon: <GearSixIcon />,
      onClick: handleOpenSettings,
    },
    {
      id: "docs",
      label: t("account.docs"),
      icon: <BookOpenIcon />,
      onClick: handleOpenDocs,
    },
    {
      id: "sign-out-separator",
      label: "",
      separator: true,
      onClick: () => {},
    },
    {
      id: "sign-out",
      label: t("account.signOut"),
      icon: <SignOutIcon />,
      onClick: handleSignOut,
    },
  ];

  const tooltipLabel = isAuthenticated
    ? user?.name || user?.email || t("account.account")
    : t("account.account");

  useEffect(() => {
    if (!isOpen || !hasBlockingModalOpen) return;
    setIsOpen(false);
  }, [hasBlockingModalOpen, isOpen]);

  useEffect(() => {
    void checkAllProviderApiKeys();
  }, [checkAllProviderApiKeys]);

  useEffect(() => {
    if (!isOpen) return;
    void checkAllProviderApiKeys();
  }, [checkAllProviderApiKeys, isOpen]);

  return (
    <>
      <Tooltip content={tooltipLabel} side="bottom">
        <Button
          ref={buttonRef}
          onClick={() => setIsOpen((open) => !open)}
          type="button"
          variant="ghost"
          size="icon-xs"
          active={isOpen}
          className={className}
          aria-expanded={isOpen}
          aria-haspopup="menu"
          aria-label={t("account.account")}
        >
          {isAuthenticated && user?.avatar_url ? (
            <img src={user.avatar_url} alt="" className="size-4 rounded-full object-cover" />
          ) : (
            <UserIcon className="size-4" />
          )}
        </Button>
      </Tooltip>
      <Dropdown
        isOpen={isOpen}
        anchorRef={buttonRef}
        anchorAlign="end"
        onClose={() => setIsOpen(false)}
        className="w-[320px] overflow-hidden rounded-xl p-0"
      >
        <div className="p-1">
          {isAuthenticated ? (
            <Button
              type="button"
              onClick={() => {
                setIsOpen(false);
                void handleOpenBillingDashboard();
              }}
              variant="ghost"
              className="h-auto w-full flex-col items-stretch gap-0 p-2.5 text-left hover:bg-accent/50"
            >
              <div className="mb-2 flex items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <span className="ui-text-sm font-medium text-foreground">{t("account.aiUsage")}</span>
                  <Badge
                    variant="default"
                    size="compact"
                    className={cn(
                      isPro || isEnterprise
                        ? "border-primary/30 bg-primary/10 text-primary"
                        : "border-border/60 bg-background/50 text-subtle-foreground",
                    )}
                  >
                    {planLabel}
                  </Badge>
                </div>
                <span className="ui-text-sm text-subtle-foreground">{modeLabel}</span>
              </div>
              {autocompleteUsage ? (
                <div className="space-y-2">
                  <div className="flex items-center justify-between gap-3">
                    <span className="ui-text-sm text-subtle-foreground">{t("account.hostedAi")}</span>
                    <span className="ui-text-sm font-medium text-foreground">
                      {formatUsdFromCents(autocompleteUsage.spendCents)} /{" "}
                      {formatUsdFromCents(autocompleteUsage.budgetCents)}
                    </span>
                  </div>
                  <Progress
                    value={usageProgress}
                    size="md"
                    aria-label={t("account.hostedAiMonthlyUsage")}
                  />
                  <div className="flex items-center justify-between gap-3">
                    <span className="ui-text-sm text-subtle-foreground/70">
                      {formatUsageDate(autocompleteUsage.periodStart)} -{" "}
                      {formatUsageDate(autocompleteUsage.periodEnd)}
                    </span>
                    <span className="ui-text-sm text-subtle-foreground/70">
                      {t("account.resetsOn", { date: formatUsageDate(autocompleteUsage.periodEnd) })}
                    </span>
                  </div>
                </div>
              ) : (
                <div className="flex items-center gap-1.5 text-subtle-foreground ui-text-sm">
                  <MoneyIcon />
                  <span>{t("account.usageUnavailable")}</span>
                </div>
              )}
            </Button>
          ) : null}

          {isAuthenticated ? <div className="my-0.5 border-border/70 border-t" /> : null}

          <MenuItemsList
            items={isAuthenticated ? signedInItems : signedOutItems}
            onItemSelect={() => setIsOpen(false)}
          />
        </div>
      </Dropdown>
    </>
  );
};
