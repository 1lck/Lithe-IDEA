import { openUrl } from "@tauri-apps/plugin-opener";
import { getServiceUrls } from "@/config/services";
import { useToast } from "@/features/layout/contexts/toast-context";
import {
  disableSettingsSync,
  enableSettingsSync,
  restoreSettingsFromCloud,
  syncSettingsNow,
} from "@/features/settings/lib/settings-sync";
import { useSettingsSyncStore } from "@/features/settings/stores/settings-sync.store";
import { useProFeature } from "@/extensions/ui/hooks/use-pro-feature";
import { useDesktopSignIn } from "@/features/window/hooks/use-desktop-sign-in";
import {
  extractAutocompleteUsage,
  formatUsageDate,
  formatUsdFromCents,
  getAccountPlanLabel,
  getUsageProgress,
} from "@/features/window/lib/account-usage";
import { useAuthStore } from "@/features/window/stores/auth.store";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { Progress } from "@/ui/progress";
import Switch from "@/ui/switch";
import { useTranslation } from "@/i18n/locale-provider";
import Section, { SettingsView, SettingRow } from "../settings-section";

export const AccountSettings = () => {
  const { t } = useTranslation();
  const services = getServiceUrls();
  const user = useAuthStore((state) => state.user);
  const subscription = useAuthStore((state) => state.subscription);
  const isAuthenticated = useAuthStore((state) => state.isAuthenticated);
  const logout = useAuthStore((state) => state.actions.logout);
  const { isPro, hasSettingsSync } = useProFeature();
  const { isSigningIn, signIn } = useDesktopSignIn();
  const { showToast } = useToast();
  const settingsSyncEnabled = useSettingsSyncStore((state) => state.enabled);
  const settingsSyncHydrated = useSettingsSyncStore((state) => state.isHydrated);
  const settingsSyncStatus = useSettingsSyncStore((state) => state.status);
  const settingsSyncError = useSettingsSyncStore((state) => state.error);
  const settingsSyncIsSyncing = useSettingsSyncStore((state) => state.isSyncing);
  const settingsSyncLastSyncedAt = useSettingsSyncStore((state) => state.lastSyncedAt);
  const settingsSyncLastSource = useSettingsSyncStore((state) => state.lastSyncSource);

  const isEnterprise = subscription?.subscription?.plan === "enterprise";
  const isTeams = Boolean(subscription?.collaboration?.enabled);
  const isPaidPlan = isPro || isEnterprise || isTeams;
  const planLabel = t(`account.plan.${getAccountPlanLabel(subscription, isAuthenticated)}`);
  const autocompleteUsage = extractAutocompleteUsage(subscription);
  const usageProgress = getUsageProgress(autocompleteUsage);

  const handleManageAccount = async () => {
    await openUrl(services.dashboardUrl);
  };

  const handleManagePlan = async () => {
    await openUrl(isPaidPlan ? services.dashboardBillingUrl : services.pricingUrl);
  };

  const handleToggleSettingsSync = async (checked: boolean) => {
    try {
      if (checked) {
        await enableSettingsSync();
        showToast({ message: t("account.cloudSyncEnabled"), type: "success" });
      } else {
        disableSettingsSync();
        showToast({ message: t("account.cloudSyncDisabled"), type: "success" });
      }
    } catch (error) {
      const message =
        error instanceof Error ? error.message : t("account.cloudSyncUpdateFailed");
      showToast({ message, type: "error" });
    }
  };

  const handleSyncNow = async () => {
    try {
      await syncSettingsNow();
      showToast({ message: t("account.settingsSyncedToCloud"), type: "success" });
    } catch (error) {
      const message = error instanceof Error ? error.message : t("account.settingsSyncFailed");
      showToast({ message, type: "error" });
    }
  };

  const handleRestoreFromCloud = async () => {
    try {
      await restoreSettingsFromCloud();
      showToast({ message: t("account.settingsRestoredFromCloud"), type: "success" });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : t("account.settingsRestoreFromCloudFailed");
      showToast({ message, type: "error" });
    }
  };

  const settingsSyncDescription = !isAuthenticated
    ? t("account.syncSignInDescription")
    : !hasSettingsSync
      ? t("account.syncProDescription")
      : settingsSyncLastSyncedAt
        ? t("account.lastSynced", {
            date: new Date(settingsSyncLastSyncedAt).toLocaleString(),
            source: settingsSyncLastSource ? t("account.syncedFrom", { source: settingsSyncLastSource }) : "",
          })
        : t("account.syncDescription");

  return (
    <SettingsView>
      <Section title={t("account.account")}>
        <SettingRow
          label={t("account.account")}
          description={t("account.signInDescription")}
        >
          {isAuthenticated ? (
            <span className="font-sans ui-text-base text-subtle-foreground">{user?.email}</span>
          ) : (
            <Button
              variant="default"
              onClick={signIn}
              disabled={isSigningIn}
              className="ui-text-base"
              size="sm"
            >
              {isSigningIn ? t("account.signingIn") : t("account.signIn")}
            </Button>
          )}
        </SettingRow>

        {isAuthenticated && (
          <div
            role="group"
            aria-labelledby="account-ai-usage-label"
            aria-describedby="account-ai-usage-description"
            className="rounded-lg px-1 py-2"
          >
            <div className="mb-3">
              <div className="min-w-0">
                <div id="account-ai-usage-label" className="font-sans ui-text-base text-foreground">
                  {t("account.aiUsage")}
                </div>
                <div
                  id="account-ai-usage-description"
                  className="font-sans ui-text-base text-subtle-foreground"
                >
                  {t("account.hostedAiMonthlyUsageDescription")}
                </div>
              </div>
            </div>
            {autocompleteUsage ? (
              <div className="space-y-2">
                <div className="flex items-center justify-between gap-4">
                  <span className="font-sans ui-text-base text-subtle-foreground">
                    {t("account.monthlyUsage")}
                  </span>
                  <span className="font-sans ui-text-base font-medium text-foreground">
                    {formatUsdFromCents(autocompleteUsage.spendCents)} /{" "}
                    {formatUsdFromCents(autocompleteUsage.budgetCents)}
                  </span>
                </div>
                <Progress
                  value={usageProgress}
                  size="md"
                  aria-label={t("account.hostedAiMonthlyUsage")}
                />
                <div className="flex items-center justify-between gap-4">
                  <span className="font-sans ui-text-base text-subtle-foreground/70">
                    {formatUsageDate(autocompleteUsage.periodStart)} -{" "}
                    {formatUsageDate(autocompleteUsage.periodEnd)}
                  </span>
                  <span className="font-sans ui-text-base text-subtle-foreground/70">
                    {t("account.resetsOn", { date: formatUsageDate(autocompleteUsage.periodEnd) })}
                  </span>
                </div>
              </div>
            ) : (
              <div className="font-sans ui-text-base text-subtle-foreground">
                {t("account.usageUnavailable")}
              </div>
            )}
          </div>
        )}

        {isAuthenticated && (
          <SettingRow label={t("account.plan")} description={t("account.planDescription")}>
            <div className="flex items-center gap-2">
              {isPaidPlan ? (
                <Badge
                  variant="default"
                  size="compact"
                  className="bg-primary/10 font-normal text-primary"
                >
                  {planLabel}
                </Badge>
              ) : null}
              <Button
                variant="default"
                onClick={handleManagePlan}
                className="ui-text-base"
                size="sm"
              >
                {isPaidPlan ? t("account.managePlan") : t("account.upgradePlan")}
              </Button>
            </div>
          </SettingRow>
        )}

        {isAuthenticated && (
          <SettingRow
            label={t("account.cloudSettingsSync")}
            description={
              settingsSyncError && settingsSyncStatus === "error"
                ? settingsSyncError
                : settingsSyncDescription
            }
          >
            {hasSettingsSync ? (
              <Switch
                checked={settingsSyncHydrated ? settingsSyncEnabled : false}
                onChange={(checked) => void handleToggleSettingsSync(checked)}
                size="sm"
                disabled={!settingsSyncHydrated}
              />
            ) : (
              <Switch checked={false} onChange={() => undefined} size="sm" disabled />
            )}
          </SettingRow>
        )}

        {hasSettingsSync && settingsSyncEnabled ? (
          <>
            <SettingRow
              label={t("account.syncNow")}
              description={t("account.syncNowDescription")}
            >
              <Button
                variant="default"
                onClick={() => void handleSyncNow()}
                className="ui-text-base"
                disabled={settingsSyncIsSyncing}
                size="sm"
              >
                {settingsSyncIsSyncing ? t("account.syncing") : t("account.syncNow")}
              </Button>
            </SettingRow>

            <SettingRow
              label={t("account.restoreFromCloud")}
              description={t("account.restoreFromCloudDescription")}
            >
              <Button
                variant="default"
                onClick={() => void handleRestoreFromCloud()}
                className="ui-text-base"
                disabled={settingsSyncIsSyncing}
                size="sm"
              >
                {t("account.restore")}
              </Button>
            </SettingRow>
          </>
        ) : null}

        {isAuthenticated && (
          <SettingRow
            label={t("account.manageAccount")}
            description={t("account.manageAccountDescription")}
          >
            <Button
              variant="default"
              onClick={handleManageAccount}
              className="ui-text-base"
              size="sm"
            >
              {t("account.openDashboard")}
            </Button>
          </SettingRow>
        )}

        {isAuthenticated && (
          <SettingRow
            label={t("account.signOut")}
            description={t("account.signOutDescription")}
          >
            <Button
              variant="default"
              onClick={() => void logout()}
              className="ui-text-base"
              size="sm"
            >
              {t("account.signOut")}
            </Button>
          </SettingRow>
        )}
      </Section>
    </SettingsView>
  );
};
