import { useEffect, useMemo, useState } from "react";
import { useAuthStore } from "@/features/window/stores/auth.store";
import { toast } from "sonner";
import { Button } from "@/ui/button";
import Section, { SettingsView, SettingRow } from "../settings-section";
import Switch from "@/ui/switch";
import Textarea from "@/ui/textarea";
import { updateEnterprisePolicy } from "@/features/window/services/auth-api";
import { useTranslation } from "@/i18n/locale-provider";

const parseAllowlistInput = (value: string): string[] =>
  Array.from(
    new Set(
      value
        .split(/[\n,]/)
        .map((item) => item.trim().toLowerCase())
        .filter(Boolean),
    ),
  );

export const EnterpriseSettings = () => {
  const { t } = useTranslation();
  const subscription = useAuthStore((state) => state.subscription);
  const refreshSubscription = useAuthStore((state) => state.actions.refreshSubscription);

  const enterprise = subscription?.enterprise;
  const policy = enterprise?.policy;
  const isAdmin = Boolean(enterprise?.is_admin);
  const hasAccess = Boolean(enterprise?.has_access);

  const [isSaving, setIsSaving] = useState(false);
  const [allowlistInput, setAllowlistInput] = useState(
    policy?.allowedExtensionIds.join("\n") || "",
  );

  useEffect(() => {
    setAllowlistInput(policy?.allowedExtensionIds.join("\n") || "");
  }, [policy?.allowedExtensionIds]);

  const parsedAllowlist = useMemo(() => parseAllowlistInput(allowlistInput), [allowlistInput]);

  const savePolicyPatch = async (
    patch: Partial<{
      managedMode: boolean;
      requireExtensionAllowlist: boolean;
      allowByok: boolean;
      aiCompletionEnabled: boolean;
      aiChatEnabled: boolean;
      allowedExtensionIds: string[];
    }>,
    successMessage: string,
  ) => {
    if (!isAdmin) return;

    setIsSaving(true);
    try {
      await updateEnterprisePolicy(patch);
      await refreshSubscription();
      toast.success(successMessage);
    } catch (error) {
      const message = error instanceof Error ? error.message : t("enterprise.updateFailed");
      toast.error(message);
    } finally {
      setIsSaving(false);
    }
  };

  if (!hasAccess) {
    return (
      <SettingsView>
        <Section title={t("enterprise.controls")} description={t("enterprise.accessRestricted")}>
          <div className="font-sans ui-text-base px-1 py-2 text-subtle-foreground">
            {t("enterprise.enterpriseOnly")}
          </div>
        </Section>
      </SettingsView>
    );
  }

  if (!policy) {
    return (
      <SettingsView>
        <Section title={t("enterprise.controls")} description={t("enterprise.policyUnavailable")}>
          <div className="font-sans ui-text-base px-1 py-2 text-subtle-foreground">
            {t("enterprise.policyLoadFailed")}
          </div>
        </Section>
      </SettingsView>
    );
  }

  return (
    <SettingsView>
      <Section
        title={t("enterprise.controls")}
        description={isAdmin ? t("enterprise.manageControls") : t("enterprise.readOnlyView")}
      >
        <SettingRow
          label={t("enterprise.managedMode")}
          description={t("enterprise.managedModeDescription")}
        >
          <Switch
            checked={policy.managedMode}
            onChange={(checked) =>
              savePolicyPatch({ managedMode: checked }, t("enterprise.managedModeUpdated"))
            }
            size="sm"
            disabled={!isAdmin || isSaving}
          />
        </SettingRow>

        <SettingRow
          label={t("enterprise.requireExtensionAllowlist")}
          description={t("enterprise.requireExtensionAllowlistDescription")}
        >
          <Switch
            checked={policy.requireExtensionAllowlist}
            onChange={(checked) =>
              savePolicyPatch(
                { requireExtensionAllowlist: checked },
                t("enterprise.allowlistEnforcementUpdated"),
              )
            }
            size="sm"
            disabled={!isAdmin || isSaving || !policy.managedMode}
          />
        </SettingRow>

        <SettingRow
          label={t("enterprise.allowByokAutocomplete")}
          description={t("enterprise.allowByokAutocompleteDescription")}
        >
          <Switch
            checked={policy.allowByok}
            onChange={(checked) =>
              savePolicyPatch({ allowByok: checked }, t("enterprise.byokPolicyUpdated"))
            }
            size="sm"
            disabled={!isAdmin || isSaving || !policy.managedMode}
          />
        </SettingRow>

        <SettingRow
          label={t("enterprise.enableAiAutocomplete")}
          description={t("enterprise.enableAiAutocompleteDescription")}
        >
          <Switch
            checked={policy.aiCompletionEnabled}
            onChange={(checked) =>
              savePolicyPatch(
                { aiCompletionEnabled: checked },
                t("enterprise.aiAutocompletePolicyUpdated"),
              )
            }
            size="sm"
            disabled={!isAdmin || isSaving || !policy.managedMode}
          />
        </SettingRow>

        <SettingRow
          label={t("enterprise.enableAgent")}
          description={t("enterprise.enableAgentDescription")}
        >
          <Switch
            checked={policy.aiChatEnabled}
            onChange={(checked) =>
              savePolicyPatch({ aiChatEnabled: checked }, t("enterprise.agentPolicyUpdated"))
            }
            size="sm"
            disabled={!isAdmin || isSaving || !policy.managedMode}
          />
        </SettingRow>
      </Section>

      <Section
        title={t("enterprise.extensionAllowlist")}
        description={t("enterprise.extensionAllowlistDescription")}
      >
        <div className="space-y-3 px-1 py-1">
          <Textarea
            value={allowlistInput}
            onChange={(event) => setAllowlistInput(event.target.value)}
            rows={8}
            size="md"
            className="font-mono ui-text-base"
            placeholder="lithe.typescript&#10;lithe.python&#10;lithe.go"
            disabled={!isAdmin || isSaving || !policy.managedMode}
          />
          <div className="flex items-center justify-between gap-2">
            <p className="font-sans ui-text-base text-subtle-foreground">
              {t("enterprise.parsedEntries")}{" "}
              <span className="text-foreground">{parsedAllowlist.length}</span>
            </p>
            <div className="flex gap-2">
              <Button
                variant="default"
                onClick={() => setAllowlistInput("")}
                disabled={!isAdmin || isSaving || !policy.managedMode}
                size="sm"
              >
                {t("ui.clear")}
              </Button>
              <Button
                onClick={() =>
                  savePolicyPatch(
                    { allowedExtensionIds: parsedAllowlist },
                    t("enterprise.extensionAllowlistUpdated"),
                  )
                }
                disabled={!isAdmin || isSaving || !policy.managedMode}
                size="sm"
              >
                {isSaving ? t("ui.saving") : t("enterprise.applyAllowlist")}
              </Button>
            </div>
          </div>
        </div>
      </Section>
    </SettingsView>
  );
};
