import { invoke } from "@/platform/tauri-core";
import {
  WarningCircleIcon as AlertCircle,
  CheckCircleIcon as CheckCircle,
  CloudIcon as Cloud,
  ArrowSquareOutIcon as ExternalLink,
  GlobeHemisphereWestIcon as Globe,
  KeyIcon as Key,
  LaptopIcon as Laptop,
  PaletteIcon as Palette,
  SparkleIcon as Sparkles,
  ArrowClockwiseIcon as RefreshCw,
  ArrowCounterClockwiseIcon as RotateCcw,
  TrashIcon as Trash2,
} from "@/ui/icons";
import { useCallback, useEffect, useRef, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { ProviderApiKeyCommand } from "@/features/ai/components/provider-api-key-command";
import { ModelSelector } from "@/features/ai/components/selectors/model-selector";
import { ProviderSelector } from "@/features/ai/components/selectors/provider-selector";
import { useAvailableProviders } from "@/features/ai/hooks/use-available-providers";
import { useAIProviderSettingsActions } from "@/features/ai/services/providers/ai-provider-settings-registry";
import { useAIChatStore } from "@/features/ai/stores/ai-chat.store";
import type { AgentConfig, SessionConfigOption } from "@/features/ai/types/acp.types";
import { useToast } from "@/features/layout/contexts/toast-context";
import { TypedConfirmAction } from "@/features/settings/components/typed-confirm-action";
import { Spinner } from "@/ui/spinner";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Select from "@/ui/select";
import Switch from "@/ui/switch";
import { ToggleGroup } from "@/ui/toggle-group";
import { fetchAutocompleteModels } from "@/features/editor/services/editor-autocomplete-service";
import {
  CUSTOM_AUTOCOMPLETE_PROVIDER_ID,
  CUSTOM_CHAT_PROVIDER_ID,
} from "@/features/ai/lib/custom-provider-config";
import { cn } from "@/utils/cn";
import {
  setCustomProviderBaseUrl,
  setOllamaApiKey,
  setOllamaBaseUrl,
} from "@/features/ai/services/providers/ai-provider-registry";
import {
  DEFAULT_OLLAMA_BASE_URL,
  OLLAMA_CLOUD_BASE_URL,
  checkOllamaConnection,
  isOllamaCloudUrl,
} from "@/features/ai/services/providers/ollama-provider";
import { resolveOllamaBaseUrl } from "@/features/ai/lib/ollama-endpoint";
import {
  getProviderApiToken,
  removeProviderApiToken,
  storeProviderApiToken,
} from "@/features/ai/services/ai-token-service";
import { CodexSettings } from "@/features/ai/integrations/codex/codex-settings";
import { useTranslation } from "@/i18n/locale-provider";
const DEFAULT_AUTOCOMPLETE_MODEL_ID = "mistralai/devstral-small";

function resolveAutocompleteDefaultModelId(models: Array<{ id: string; name: string }>): string {
  if (models.some((model) => model.id === DEFAULT_AUTOCOMPLETE_MODEL_ID)) {
    return DEFAULT_AUTOCOMPLETE_MODEL_ID;
  }
  return models[0]?.id || DEFAULT_AUTOCOMPLETE_MODEL_ID;
}

export const AISettings = () => {
  const settings = useSettingsStore(
    useShallow((state) => ({
      aiAutocompleteCustomBaseUrl: state.settings.aiAutocompleteCustomBaseUrl,
      aiAutocompleteCustomModelId: state.settings.aiAutocompleteCustomModelId,
      aiAutocompleteModelId: state.settings.aiAutocompleteModelId,
      aiAutocompleteProvider: state.settings.aiAutocompleteProvider,
      aiCompletion: state.settings.aiCompletion,
      aiCustomBaseUrl: state.settings.aiCustomBaseUrl,
      aiCustomModelId: state.settings.aiCustomModelId,
      aiModelId: state.settings.aiModelId,
      aiProviderId: state.settings.aiProviderId,
      ollamaBaseUrl: state.settings.ollamaBaseUrl,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const openCommandPaletteView = useUIState((state) => state.openCommandPaletteView);
  const { showToast } = useToast();

  const [sessionConfigOptions, setSessionConfigOptions] = useState<SessionConfigOption[]>([]);
  const [isClearingChats, setIsClearingChats] = useState(false);
  const [autocompleteModels, setAutocompleteModels] = useState<Array<{ id: string; name: string }>>(
    [],
  );
  const [isLoadingAutocompleteModels, setIsLoadingAutocompleteModels] = useState(false);
  const [autocompleteModelError, setAutocompleteModelError] = useState<string | null>(null);
  const [customAutocompleteModelInput, setCustomAutocompleteModelInput] = useState(
    settings.aiAutocompleteCustomModelId,
  );
  const [customAutocompleteBaseUrlInput, setCustomAutocompleteBaseUrlInput] = useState(
    settings.aiAutocompleteCustomBaseUrl,
  );
  const [customAutocompleteApiKeyInput, setCustomAutocompleteApiKeyInput] = useState("");
  const [hasCustomAutocompleteApiKey, setHasCustomAutocompleteApiKey] = useState(false);
  const [isSavingCustomAutocompleteApiKey, setIsSavingCustomAutocompleteApiKey] = useState(false);
  const [customChatBaseUrlInput, setCustomChatBaseUrlInput] = useState(settings.aiCustomBaseUrl);
  const [customChatApiKeyInput, setCustomChatApiKeyInput] = useState("");
  const [hasCustomChatApiKey, setHasCustomChatApiKey] = useState(false);
  const [isSavingCustomChatApiKey, setIsSavingCustomChatApiKey] = useState(false);
  const [isApiKeyManagerOpen, setIsApiKeyManagerOpen] = useState(false);

  // Ollama URL state
  const [ollamaUrl, setOllamaUrl] = useState(settings.ollamaBaseUrl || DEFAULT_OLLAMA_BASE_URL);
  const [ollamaStatus, setOllamaStatus] = useState<"idle" | "checking" | "ok" | "error">("idle");
  const ollamaDebounceRef = useRef<ReturnType<typeof setTimeout>>(undefined);
  const ollamaDraftDirtyRef = useRef(false);
  const ollamaValidationIdRef = useRef(0);
  const lastSelfHostedOllamaUrlRef = useRef(
    isOllamaCloudUrl(settings.ollamaBaseUrl)
      ? DEFAULT_OLLAMA_BASE_URL
      : resolveOllamaBaseUrl(settings.ollamaBaseUrl) || DEFAULT_OLLAMA_BASE_URL,
  );

  // Ollama API key state (used for Ollama Cloud; optional for local)
  const [ollamaApiKeyInput, setOllamaApiKeyInput] = useState("");
  const [hasStoredOllamaKey, setHasStoredOllamaKey] = useState(false);
  const [isSavingOllamaKey, setIsSavingOllamaKey] = useState(false);

  const isOllamaCloud = isOllamaCloudUrl(ollamaUrl);
  const needsApiKey = isOllamaCloud;
  const providers = useAvailableProviders();
  const providerSettingsActions = useAIProviderSettingsActions(settings.aiProviderId);
  const { t } = useTranslation();

  useEffect(() => {
    const detectAgents = async () => {
      try {
        await invoke<AgentConfig[]>("get_available_agents");
      } catch {
        // Failed to detect agents
      }
    };
    detectAgents();
  }, []);

  useEffect(() => {
    const unsubscribe = useAIChatStore.subscribe((state) => {
      setSessionConfigOptions(state.sessionConfigOptions);
    });
    setSessionConfigOptions(useAIChatStore.getState().sessionConfigOptions);
    return unsubscribe;
  }, []);

  // Keep the draft aligned with settings loaded after the dialog mounted.
  useEffect(() => {
    const url = resolveOllamaBaseUrl(settings.ollamaBaseUrl) || DEFAULT_OLLAMA_BASE_URL;
    setOllamaBaseUrl(url);

    if (!isOllamaCloudUrl(url)) {
      lastSelfHostedOllamaUrlRef.current = url;
    }

    if (!ollamaDraftDirtyRef.current) {
      if (ollamaDebounceRef.current) clearTimeout(ollamaDebounceRef.current);
      setOllamaUrl(url);
    }
  }, [settings.ollamaBaseUrl]);

  useEffect(() => {
    void (async () => {
      const token = await getProviderApiToken("ollama");
      setHasStoredOllamaKey(!!token);
      setOllamaApiKey(token);
    })();
  }, []);

  useEffect(
    () => () => {
      if (ollamaDebounceRef.current) clearTimeout(ollamaDebounceRef.current);
      ollamaValidationIdRef.current += 1;
    },
    [],
  );

  const validateOllamaConnection = useCallback(
    async (url: string, apiKey?: string | null) => {
      const normalizedUrl = resolveOllamaBaseUrl(url);
      const validationId = ++ollamaValidationIdRef.current;
      if (!normalizedUrl) {
        setOllamaStatus("error");
        return;
      }

      setOllamaStatus("checking");
      const keyToUse =
        apiKey !== undefined
          ? apiKey
          : hasStoredOllamaKey
            ? await getProviderApiToken("ollama")
            : null;
      const ok = await checkOllamaConnection(normalizedUrl, keyToUse);
      if (validationId === ollamaValidationIdRef.current) {
        setOllamaStatus(ok ? "ok" : "error");
      }
    },
    [hasStoredOllamaKey],
  );

  const commitOllamaUrl = useCallback(
    (value: string) => {
      if (ollamaDebounceRef.current) {
        clearTimeout(ollamaDebounceRef.current);
        ollamaDebounceRef.current = undefined;
      }

      const normalizedUrl = resolveOllamaBaseUrl(value);
      if (!normalizedUrl) {
        setOllamaStatus("error");
        return;
      }

      ollamaDraftDirtyRef.current = false;
      setOllamaUrl(normalizedUrl);
      void updateSetting("ollamaBaseUrl", normalizedUrl);
      setOllamaBaseUrl(normalizedUrl);
      if (!isOllamaCloudUrl(normalizedUrl)) {
        lastSelfHostedOllamaUrlRef.current = normalizedUrl;
      }
      void validateOllamaConnection(normalizedUrl);
    },
    [updateSetting, validateOllamaConnection],
  );

  const handleOllamaUrlChange = (value: string) => {
    ollamaDraftDirtyRef.current = true;
    setOllamaUrl(value);
    setOllamaStatus("idle");

    if (ollamaDebounceRef.current) clearTimeout(ollamaDebounceRef.current);
    ollamaDebounceRef.current = setTimeout(() => {
      ollamaDebounceRef.current = undefined;
      void commitOllamaUrl(value);
    }, 600);
  };

  const handleResetOllamaUrl = () => {
    lastSelfHostedOllamaUrlRef.current = DEFAULT_OLLAMA_BASE_URL;
    commitOllamaUrl(DEFAULT_OLLAMA_BASE_URL);
  };

  const handleUseSelfHostedOllama = () => {
    commitOllamaUrl(lastSelfHostedOllamaUrlRef.current);
  };

  const handleUseOllamaCloud = () => {
    const currentUrl = resolveOllamaBaseUrl(ollamaUrl);
    if (currentUrl && !isOllamaCloudUrl(currentUrl)) {
      lastSelfHostedOllamaUrlRef.current = currentUrl;
    }
    commitOllamaUrl(OLLAMA_CLOUD_BASE_URL);
  };

  const handleSaveOllamaApiKey = async () => {
    const trimmed = ollamaApiKeyInput.trim();
    if (!trimmed) return;
    setIsSavingOllamaKey(true);
    try {
      await storeProviderApiToken("ollama", trimmed);
      setOllamaApiKey(trimmed);
      setHasStoredOllamaKey(true);
      setOllamaApiKeyInput("");
      showToast({ message: t("aiSettings.ollamaApiKeySaved"), type: "success" });
      void validateOllamaConnection(ollamaUrl, trimmed);
    } catch {
      showToast({ message: t("aiSettings.ollamaApiKeySaveFailed"), type: "error" });
    } finally {
      setIsSavingOllamaKey(false);
    }
  };

  const handleRemoveOllamaApiKey = async () => {
    try {
      await removeProviderApiToken("ollama");
      setOllamaApiKey(null);
      setHasStoredOllamaKey(false);
      setOllamaApiKeyInput("");
      showToast({ message: t("aiSettings.ollamaApiKeyRemoved"), type: "success" });
      void validateOllamaConnection(ollamaUrl, null);
    } catch {
      showToast({ message: t("aiSettings.ollamaApiKeyRemoveFailed"), type: "error" });
    }
  };

  const handleProviderChange = (newProviderId: string) => {
    const provider = providers.find((p) => p.id === newProviderId);
    updateSetting("aiProviderId", newProviderId);
    if (newProviderId === CUSTOM_CHAT_PROVIDER_ID) {
      updateSetting("aiModelId", settings.aiCustomModelId || settings.aiAutocompleteCustomModelId);
      return;
    }
    if (provider && provider.models.length > 0) {
      updateSetting("aiModelId", provider.models[0].id);
    }
  };

  const loadAutocompleteModels = async () => {
    setIsLoadingAutocompleteModels(true);
    setAutocompleteModelError(null);
    try {
      const models = await fetchAutocompleteModels();
      if (models.length > 0) {
        setAutocompleteModels(models);
        setAutocompleteModelError(null);
        if (!models.some((model) => model.id === settings.aiAutocompleteModelId)) {
          updateSetting("aiAutocompleteModelId", resolveAutocompleteDefaultModelId(models));
        }
      } else {
        setAutocompleteModels([]);
        setAutocompleteModelError(t("aiSettings.modelListEmpty"));
      }
    } catch {
      setAutocompleteModels([]);
      setAutocompleteModelError(t("aiSettings.modelListLoadFailed"));
    } finally {
      setIsLoadingAutocompleteModels(false);
    }
  };

  useEffect(() => {
    void loadAutocompleteModels();
  }, []);

  useEffect(() => {
    setCustomAutocompleteModelInput(settings.aiAutocompleteCustomModelId);
  }, [settings.aiAutocompleteCustomModelId]);

  useEffect(() => {
    setCustomAutocompleteBaseUrlInput(settings.aiAutocompleteCustomBaseUrl);
  }, [settings.aiAutocompleteCustomBaseUrl]);

  useEffect(() => {
    setCustomChatBaseUrlInput(settings.aiCustomBaseUrl);
  }, [settings.aiCustomBaseUrl]);

  useEffect(() => {
    void (async () => {
      const token = await getProviderApiToken(CUSTOM_AUTOCOMPLETE_PROVIDER_ID);
      setHasCustomAutocompleteApiKey(Boolean(token));
      const customChatToken = await getProviderApiToken(CUSTOM_CHAT_PROVIDER_ID);
      setHasCustomChatApiKey(Boolean(customChatToken));
    })();
  }, []);

  const handleSaveCustomAutocompleteApiKey = async () => {
    const token = customAutocompleteApiKeyInput.trim();
    if (!token) return;

    setIsSavingCustomAutocompleteApiKey(true);
    try {
      await storeProviderApiToken(CUSTOM_AUTOCOMPLETE_PROVIDER_ID, token);
      setHasCustomAutocompleteApiKey(true);
      setCustomAutocompleteApiKeyInput("");
      showToast({ message: t("aiSettings.customAutocompleteApiKeySaved"), type: "success" });
    } catch {
      showToast({ message: t("aiSettings.customAutocompleteApiKeySaveFailed"), type: "error" });
    } finally {
      setIsSavingCustomAutocompleteApiKey(false);
    }
  };

  const handleRemoveCustomAutocompleteApiKey = async () => {
    setIsSavingCustomAutocompleteApiKey(true);
    try {
      await removeProviderApiToken(CUSTOM_AUTOCOMPLETE_PROVIDER_ID);
      setHasCustomAutocompleteApiKey(false);
      setCustomAutocompleteApiKeyInput("");
      showToast({ message: t("aiSettings.customAutocompleteApiKeyRemoved"), type: "success" });
    } catch {
      showToast({ message: t("aiSettings.customAutocompleteApiKeyRemoveFailed"), type: "error" });
    } finally {
      setIsSavingCustomAutocompleteApiKey(false);
    }
  };

  const handleSaveCustomChatApiKey = async () => {
    const token = customChatApiKeyInput.trim();
    if (!token) return;

    setIsSavingCustomChatApiKey(true);
    try {
      await storeProviderApiToken(CUSTOM_CHAT_PROVIDER_ID, token);
      setHasCustomChatApiKey(true);
      setCustomChatApiKeyInput("");
      showToast({ message: t("aiSettings.customProviderApiKeySaved"), type: "success" });
    } catch {
      showToast({ message: t("aiSettings.customProviderApiKeySaveFailed"), type: "error" });
    } finally {
      setIsSavingCustomChatApiKey(false);
    }
  };

  const handleRemoveCustomChatApiKey = async () => {
    setIsSavingCustomChatApiKey(true);
    try {
      await removeProviderApiToken(CUSTOM_CHAT_PROVIDER_ID);
      setHasCustomChatApiKey(false);
      setCustomChatApiKeyInput("");
      showToast({ message: t("aiSettings.customProviderApiKeyRemoved"), type: "success" });
    } catch {
      showToast({ message: t("aiSettings.customProviderApiKeyRemoveFailed"), type: "error" });
    } finally {
      setIsSavingCustomChatApiKey(false);
    }
  };

  const commitCustomChatBaseUrl = () => {
    updateSetting("aiCustomBaseUrl", customChatBaseUrlInput);
    setCustomProviderBaseUrl(customChatBaseUrlInput);
  };

  const commitCustomAutocompleteModel = () => {
    updateSetting("aiAutocompleteCustomModelId", customAutocompleteModelInput);
  };

  const commitCustomAutocompleteBaseUrl = () => {
    updateSetting("aiAutocompleteCustomBaseUrl", customAutocompleteBaseUrlInput);
  };

  const providersNeedingAuth = providers.filter((p) => p.requiresAuth && !p.requiresApiKey);

  const isOllamaSelected = settings.aiProviderId === "ollama";
  const isCustomProviderSelected = settings.aiProviderId === CUSTOM_CHAT_PROVIDER_ID;
  const showCustomProviderSettings =
    isCustomProviderSelected || Boolean(settings.aiCustomBaseUrl || settings.aiCustomModelId);
  const hasAutocompleteModels = autocompleteModels.length > 0;

  return (
    <SettingsView>
      <CodexSettings />
      <Section title="Lithe Agent">
        <SettingRow
          label={t("aiSettings.provider")}
          description={t("aiSettings.providerDescription")}
          onReset={() => {
            updateSetting("aiProviderId", getDefaultSetting("aiProviderId"));
            updateSetting("aiModelId", getDefaultSetting("aiModelId"));
          }}
          canReset={
            settings.aiProviderId !== getDefaultSetting("aiProviderId") ||
            settings.aiModelId !== getDefaultSetting("aiModelId")
          }
        >
          <ProviderSelector
            providerId={settings.aiProviderId}
            onChange={(id) => handleProviderChange(id)}
          />
        </SettingRow>

        <SettingRow
          label={t("aiSettings.model")}
          description={
            isCustomProviderSelected
              ? t("aiSettings.customModelDescription")
              : t("aiSettings.modelDescription")
          }
          onReset={() => {
            if (isCustomProviderSelected) {
              updateSetting("aiCustomModelId", getDefaultSetting("aiCustomModelId"));
              updateSetting("aiModelId", getDefaultSetting("aiCustomModelId"));
              return;
            }
            updateSetting("aiModelId", getDefaultSetting("aiModelId"));
          }}
          canReset={
            isCustomProviderSelected
              ? settings.aiCustomModelId !== getDefaultSetting("aiCustomModelId")
              : settings.aiModelId !== getDefaultSetting("aiModelId")
          }
        >
          {isCustomProviderSelected ? (
            <ModelSelector
              providerId={settings.aiProviderId}
              modelId={settings.aiModelId || settings.aiCustomModelId}
              onChange={(id) => {
                updateSetting("aiCustomModelId", id);
                updateSetting("aiModelId", id);
              }}
            />
          ) : (
            <ModelSelector
              providerId={settings.aiProviderId}
              modelId={settings.aiModelId}
              onChange={(id) => updateSetting("aiModelId", id)}
            />
          )}
        </SettingRow>

        <SettingRow
          label={t("aiSettings.apiKeys")}
          description={t("aiSettings.apiKeysDescription")}
        >
          <Button
            type="button"
            variant="default"
            onClick={() => setIsApiKeyManagerOpen(true)}
            className="w-fit"
            size="sm"
          >
            <Key />
            <span>{t("aiSettings.manageKeys")}</span>
          </Button>
        </SettingRow>

        {providerSettingsActions.map((action) => {
          const Icon = action.icon === "sparkles" ? Sparkles : Palette;

          return (
            <SettingRow
              key={action.id}
              label={action.label}
              description={action.getDescription?.() || t("aiSettings.configureProviderExtension")}
            >
              <Button
                type="button"
                variant="default"
                onClick={() => openCommandPaletteView(action.commandPaletteViewId)}
                className="w-fit"
                size="sm"
              >
                <Icon />
                <span>{action.buttonLabel}</span>
              </Button>
            </SettingRow>
          );
        })}
      </Section>

      {showCustomProviderSettings && (
        <Section title={t("aiSettings.customProvider")}>
          <SettingRow
            label={t("aiSettings.baseUrl")}
            description={t("aiSettings.customProviderBaseUrlDescription")}
            onReset={() => {
              updateSetting("aiCustomBaseUrl", getDefaultSetting("aiCustomBaseUrl"));
              setCustomProviderBaseUrl(getDefaultSetting("aiCustomBaseUrl"));
            }}
            canReset={settings.aiCustomBaseUrl !== getDefaultSetting("aiCustomBaseUrl")}
          >
            <Input
              value={customChatBaseUrlInput}
              onChange={(event) => setCustomChatBaseUrlInput(event.currentTarget.value)}
              onBlur={commitCustomChatBaseUrl}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.currentTarget.blur();
                }
              }}
              placeholder="http://localhost:11434/v1"
              size="md"
              className={SETTINGS_CONTROL_WIDTHS.xwide}
              spellCheck={false}
              leftIcon={Globe}
            />
          </SettingRow>
          <SettingRow
            label={t("aiSettings.apiKey")}
            description={
              hasCustomChatApiKey
                ? t("aiSettings.savedKeyDescription")
                : t("aiSettings.optionalBearerDescription")
            }
          >
            <div className="flex items-center gap-2">
              <Input
                type="password"
                value={customChatApiKeyInput}
                onChange={(event) => setCustomChatApiKeyInput(event.currentTarget.value)}
                placeholder={hasCustomChatApiKey ? t("aiSettings.saved") : t("aiSettings.apiKey")}
                size="md"
                className={SETTINGS_CONTROL_WIDTHS.wide}
                spellCheck={false}
                autoComplete="off"
                disabled={isSavingCustomChatApiKey}
              />
              <Button
                type="button"
                variant="default"
                onClick={handleSaveCustomChatApiKey}
                disabled={!customChatApiKeyInput.trim() || isSavingCustomChatApiKey}
                size="sm"
              >
                {t("ui.save")}
              </Button>
              {hasCustomChatApiKey && (
                <Button
                  type="button"
                  variant="default"
                  onClick={handleRemoveCustomChatApiKey}
                  disabled={isSavingCustomChatApiKey}
                  size="sm"
                >
                  {t("ui.remove")}
                </Button>
              )}
            </div>
          </SettingRow>
        </Section>
      )}

      {(isOllamaSelected || settings.ollamaBaseUrl !== DEFAULT_OLLAMA_BASE_URL) && (
        <Section title="Ollama">
          <SettingRow label={t("aiSettings.mode")} description={t("aiSettings.ollamaModeDescription")}>
            <ToggleGroup
              value={isOllamaCloud ? "cloud" : "local"}
              onValueChange={(nextValue) => {
                if (nextValue === "local") {
                  handleUseSelfHostedOllama();
                  return;
                }
                handleUseOllamaCloud();
              }}
              ariaLabel={t("aiSettings.ollamaMode")}
              options={[
                { value: "local", label: t("aiSettings.local"), icon: <Laptop /> },
                { value: "cloud", label: t("aiSettings.cloud"), icon: <Cloud /> },
              ]}
            />
          </SettingRow>
          <SettingRow
            label={t("aiSettings.endpoint")}
            description={t("aiSettings.ollamaEndpointDescription")}
            onReset={handleResetOllamaUrl}
            canReset={settings.ollamaBaseUrl !== getDefaultSetting("ollamaBaseUrl")}
          >
            <div className="flex min-w-0 flex-wrap items-center gap-1.5">
              <Input
                type="text"
                value={ollamaUrl}
                onChange={(e) => handleOllamaUrlChange(e.target.value)}
                onBlur={(e) => {
                  void commitOllamaUrl(e.target.value);
                }}
                onKeyDown={(e) => {
                  if (e.key !== "Enter") return;
                  e.preventDefault();
                  e.currentTarget.blur();
                }}
                placeholder={DEFAULT_OLLAMA_BASE_URL}
                spellCheck={false}
                leftIcon={Globe}
                className={cn(
                  "w-56 max-w-full",
                  ollamaStatus === "error" && "border-destructive/60",
                )}
              />
              {ollamaStatus === "checking" && <Spinner label={t("aiSettings.checking")} compact />}
              {ollamaStatus === "ok" && <CheckCircle className="text-success" />}
              {ollamaStatus === "error" && <AlertCircle className="text-destructive" />}
              {ollamaUrl !== DEFAULT_OLLAMA_BASE_URL && (
                <Button
                  type="button"
                  variant="default"
                  onClick={handleResetOllamaUrl}
                  title={t("aiSettings.resetToDefault")}
                  aria-label={t("aiSettings.resetOllamaUrl")}
                  size="icon-xs"
                >
                  <RotateCcw />
                </Button>
              )}
            </div>
          </SettingRow>
          <SettingRow
            label={t("aiSettings.apiKey")}
            description={t("aiSettings.ollamaApiKeyDescription")}
          >
            <div className="flex min-w-0 flex-wrap items-center gap-1.5">
              <Input
                type="password"
                value={ollamaApiKeyInput}
                onChange={(e) => setOllamaApiKeyInput(e.target.value)}
                placeholder={hasStoredOllamaKey ? t("aiSettings.savedKeyPlaceholder") : "ollama-…"}
                spellCheck={false}
                leftIcon={Key}
                className={cn(
                  "w-56 max-w-full",
                  needsApiKey && !hasStoredOllamaKey && "border-warning/60",
                )}
                autoComplete="off"
                disabled={isSavingOllamaKey}
              />
              <Button
                type="button"
                variant="default"
                onClick={handleSaveOllamaApiKey}
                disabled={!ollamaApiKeyInput.trim() || isSavingOllamaKey}
                size="sm"
              >
                {isSavingOllamaKey ? t("ui.saving") : t("ui.save")}
              </Button>
              {hasStoredOllamaKey && (
                <Button
                  type="button"
                  variant="default"
                  onClick={handleRemoveOllamaApiKey}
                  title={t("aiSettings.removeSavedApiKey")}
                  aria-label={t("aiSettings.removeOllamaApiKey")}
                  className="text-destructive hover:bg-destructive/10"
                  size="icon-xs"
                >
                  <Trash2 />
                </Button>
              )}
            </div>
          </SettingRow>
          {needsApiKey && !hasStoredOllamaKey && (
            <SettingRow
              label={t("aiSettings.ollamaCloudKey")}
              description={t("aiSettings.ollamaCloudKeyDescription")}
            >
              <div className="flex items-center gap-1.5">
                <AlertCircle className="shrink-0 text-warning" />
                <a
                  href="https://ollama.com/settings/keys"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-primary hover:underline"
                >
                  {t("aiSettings.getKey")} <ExternalLink className="size-3" />
                </a>
              </div>
            </SettingRow>
          )}
          {ollamaStatus === "error" && (
            <SettingRow
              label={t("aiSettings.connectionStatus")}
              description={
                isOllamaCloud
                  ? t("aiSettings.ollamaCloudConnectionFailed")
                  : t("aiSettings.ollamaLocalConnectionFailed")
              }
            >
              <Badge variant="default">{t("aiSettings.error")}</Badge>
            </SettingRow>
          )}
        </Section>
      )}

      <ProviderApiKeyCommand
        isOpen={isApiKeyManagerOpen}
        onClose={() => setIsApiKeyManagerOpen(false)}
        initialProviderId={settings.aiProviderId}
      />

      {providersNeedingAuth.length > 0 && (
        <Section title={t("aiSettings.authentication")}>
          {providersNeedingAuth.map((provider) => (
            <SettingRow
              key={provider.id}
              label={provider.name}
              description={t("aiSettings.requiresOAuth")}
            >
              <Badge variant="default">{t("aiSettings.comingSoon")}</Badge>
            </SettingRow>
          ))}
        </Section>
      )}

      {sessionConfigOptions.length > 0 && (
        <Section title={t("aiSettings.acpSession")}>
          {sessionConfigOptions.map((option) => {
            if (option.kind.type !== "select") {
              return null;
            }

            return (
              <SettingRow
                key={option.id}
                label={option.name}
                description={option.description || t("aiSettings.acpSessionOptionDescription")}
              >
                <Select
                  value={option.kind.currentValue}
                  options={option.kind.options.map((value) => ({
                    value: value.id,
                    label: value.name,
                  }))}
                  onChange={(value) =>
                    useAIChatStore.getState().actions.changeSessionConfigOption(option.id, value)
                  }
                  size="md"
                  variant="default"
                  searchable
                  searchableTrigger="input"
                />
              </SettingRow>
            );
          })}
        </Section>
      )}

      <Section title={t("aiSettings.autocomplete")}>
        <SettingRow
          label={t("aiSettings.aiAutocomplete")}
          description={t("aiSettings.aiAutocompleteDescription")}
          onReset={() => updateSetting("aiCompletion", getDefaultSetting("aiCompletion"))}
          canReset={settings.aiCompletion !== getDefaultSetting("aiCompletion")}
        >
          <Switch
            checked={settings.aiCompletion}
            onChange={(checked) => updateSetting("aiCompletion", checked)}
            size="sm"
          />
        </SettingRow>
        {settings.aiCompletion && (
          <>
            <SettingRow
              label={t("aiSettings.autocompleteProvider")}
              description={t("aiSettings.autocompleteProviderDescription")}
              onReset={() =>
                updateSetting("aiAutocompleteProvider", getDefaultSetting("aiAutocompleteProvider"))
              }
              canReset={
                settings.aiAutocompleteProvider !== getDefaultSetting("aiAutocompleteProvider")
              }
            >
              <ToggleGroup
                value={settings.aiAutocompleteProvider}
                options={[
                  { value: "openrouter", label: "OpenRouter" },
                  { value: "custom", label: t("aiSettings.custom") },
                ]}
                onValueChange={(value) =>
                  updateSetting(
                    "aiAutocompleteProvider",
                    value === "custom" ? "custom" : "openrouter",
                  )
                }
                ariaLabel={t("aiSettings.autocompleteProvider")}
                size="xs"
                wrap={false}
              />
            </SettingRow>
            <SettingRow
              label={
                settings.aiAutocompleteProvider === "custom"
                  ? t("aiSettings.customModel")
                  : t("aiSettings.autocompleteModel")
              }
              description={
                settings.aiAutocompleteProvider === "custom"
                  ? t("aiSettings.customModelDescription")
                  : t("aiSettings.autocompleteModelDescription")
              }
              onReset={() =>
                settings.aiAutocompleteProvider === "custom"
                  ? updateSetting(
                      "aiAutocompleteCustomModelId",
                      getDefaultSetting("aiAutocompleteCustomModelId"),
                    )
                  : updateSetting(
                      "aiAutocompleteModelId",
                      getDefaultSetting("aiAutocompleteModelId"),
                    )
              }
              canReset={
                settings.aiAutocompleteProvider === "custom"
                  ? settings.aiAutocompleteCustomModelId !==
                    getDefaultSetting("aiAutocompleteCustomModelId")
                  : settings.aiAutocompleteModelId !== getDefaultSetting("aiAutocompleteModelId")
              }
            >
              {settings.aiAutocompleteProvider === "custom" ? (
                <Input
                  value={customAutocompleteModelInput}
                  onChange={(event) => setCustomAutocompleteModelInput(event.currentTarget.value)}
                  onBlur={commitCustomAutocompleteModel}
                  onKeyDown={(event) => {
                    if (event.key === "Enter") {
                      event.currentTarget.blur();
                    }
                  }}
                  placeholder="qwen2.5-coder:7b"
                  size="md"
                  className={SETTINGS_CONTROL_WIDTHS.xwide}
                />
              ) : (
                <div className="flex items-center gap-2">
                  <Button
                    variant="default"
                    onClick={loadAutocompleteModels}
                    disabled={isLoadingAutocompleteModels}
                    title={t("aiSettings.refreshModelList")}
                    size="icon-xs"
                  >
                    {isLoadingAutocompleteModels ? (
                      <Spinner label={t("aiSettings.loadingModels")} compact />
                    ) : (
                      <RefreshCw />
                    )}
                  </Button>
                  <Select
                    value={hasAutocompleteModels ? settings.aiAutocompleteModelId : ""}
                    options={autocompleteModels.map((model) => ({
                      value: model.id,
                      label: model.name,
                    }))}
                    onChange={(value) => updateSetting("aiAutocompleteModelId", value)}
                    size="md"
                    variant="default"
                    searchable
                    searchableTrigger="input"
                    className={SETTINGS_CONTROL_WIDTHS.xwide}
                    disabled={isLoadingAutocompleteModels || !hasAutocompleteModels}
                    placeholder={
                      isLoadingAutocompleteModels
                        ? t("aiSettings.loadingModelsEllipsis")
                        : t("aiSettings.noModelsLoaded")
                    }
                  />
                </div>
              )}
            </SettingRow>
            {settings.aiAutocompleteProvider === "custom" && (
              <>
                <SettingRow
                  label={t("aiSettings.customBaseUrl")}
                  description={t("aiSettings.openAiCompatibleBaseUrlDescription")}
                  onReset={() =>
                    updateSetting(
                      "aiAutocompleteCustomBaseUrl",
                      getDefaultSetting("aiAutocompleteCustomBaseUrl"),
                    )
                  }
                  canReset={
                    settings.aiAutocompleteCustomBaseUrl !==
                    getDefaultSetting("aiAutocompleteCustomBaseUrl")
                  }
                >
                  <Input
                    value={customAutocompleteBaseUrlInput}
                    onChange={(event) =>
                      setCustomAutocompleteBaseUrlInput(event.currentTarget.value)
                    }
                    onBlur={commitCustomAutocompleteBaseUrl}
                    onKeyDown={(event) => {
                      if (event.key === "Enter") {
                        event.currentTarget.blur();
                      }
                    }}
                    placeholder="http://localhost:11434/v1"
                    size="md"
                    className={SETTINGS_CONTROL_WIDTHS.xwide}
                  />
                </SettingRow>
                <SettingRow
                  label={t("aiSettings.customApiKey")}
                  description={
                    hasCustomAutocompleteApiKey
                      ? t("aiSettings.savedKeyDescription")
                      : t("aiSettings.optionalBearerDescription")
                  }
                >
                  <div className="flex items-center gap-2">
                    <Input
                      type="password"
                      value={customAutocompleteApiKeyInput}
                      onChange={(event) =>
                        setCustomAutocompleteApiKeyInput(event.currentTarget.value)
                      }
                      placeholder={
                        hasCustomAutocompleteApiKey ? t("aiSettings.saved") : t("aiSettings.apiKey")
                      }
                      size="md"
                      className={SETTINGS_CONTROL_WIDTHS.wide}
                      disabled={isSavingCustomAutocompleteApiKey}
                    />
                    <Button
                      variant="default"
                      onClick={handleSaveCustomAutocompleteApiKey}
                      disabled={
                        !customAutocompleteApiKeyInput.trim() ||
                        isSavingCustomAutocompleteApiKey
                      }
                      size="sm"
                    >
                      {t("ui.save")}
                    </Button>
                    {hasCustomAutocompleteApiKey && (
                      <Button
                        variant="default"
                        onClick={handleRemoveCustomAutocompleteApiKey}
                        disabled={isSavingCustomAutocompleteApiKey}
                        size="sm"
                      >
                        {t("ui.remove")}
                      </Button>
                    )}
                  </div>
                </SettingRow>
              </>
            )}
            {autocompleteModelError && (
              <SettingRow label={t("aiSettings.modelList")} description={autocompleteModelError}>
                <Badge variant="default">{t("aiSettings.error")}</Badge>
              </SettingRow>
            )}
          </>
        )}
      </Section>

      <Section title={t("aiSettings.agentHistory")}>
        <SettingRow
          label={t("aiSettings.clearAgentHistory")}
          description={t("aiSettings.clearAgentHistoryDescription")}
        >
          <TypedConfirmAction
            actionLabel={t("aiSettings.clearAll")}
            busyLabel={t("aiSettings.clearing")}
            isBusy={isClearingChats}
            onConfirm={async () => {
              setIsClearingChats(true);
              try {
                await useAIChatStore.getState().actions.clearAllChats();
                showToast({ message: t("aiSettings.agentHistoryCleared"), type: "success" });
              } finally {
                setIsClearingChats(false);
              }
            }}
          />
        </SettingRow>
      </Section>
    </SettingsView>
  );
};
