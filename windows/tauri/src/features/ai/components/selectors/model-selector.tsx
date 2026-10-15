import { WarningCircleIcon as WarningCircle } from "@/ui/icons";
import { useAIModelOptions } from "@/features/ai/hooks/use-ai-model-options";
import { Alert, AlertDescription } from "@/ui/alert";
import { useTranslation } from "@/i18n/locale-provider";
import Select from "@/ui/select";
import SettingsSelect from "@/ui/settings-select";
import { cn } from "@/utils/cn";

interface ModelSelectorProps {
  providerId: string;
  modelId: string;
  onChange: (modelId: string) => void;
  appearance?: "settings" | "composer";
  disabled?: boolean;
  className?: string;
  triggerClassName?: string;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  tooltip?: string;
}

export function ModelSelector({
  providerId,
  modelId,
  onChange,
  appearance = "settings",
  disabled,
  className,
  triggerClassName,
  open,
  onOpenChange,
  tooltip,
}: ModelSelectorProps) {
  const { t } = useTranslation();
  const isComposer = appearance === "composer";
  const SelectControl = isComposer ? Select : SettingsSelect;
  const { availableModels, currentModelName, isCustomProvider, modelFetchError } =
    useAIModelOptions(providerId, modelId, onChange);

  return (
    <SelectControl
      value={modelId}
      onChange={onChange}
      options={availableModels.map((model) => ({
        value: model.id,
        label: model.name,
        keywords: [model.id],
      }))}
      placeholder={currentModelName}
      aria-label={t("ai.selectAiModel")}
      searchable
      openDirection={isComposer ? "up" : "down"}
      allowCustomValue={isCustomProvider}
      customValueLabel={(customValue) => t("ai.useCustomValue", { value: customValue })}
      emptyLabel={isCustomProvider ? t("ai.typeModelName") : t("ai.noModelsFound")}
      hideChevron={isComposer}
      {...(isComposer
        ? { size: "xs" as const, variant: "ghost" as const, searchableTrigger: "input" as const }
        : {})}
      disabled={disabled}
      open={open}
      onOpenChange={onOpenChange}
      tooltip={tooltip}
      className={cn(!isComposer && "w-56 max-w-full", className)}
      triggerClassName={cn(isComposer && "max-w-44", triggerClassName)}
      menuClassName={isComposer ? "w-fit min-w-0 max-w-(--available-width) p-0" : undefined}
      menuMinWidth={isComposer ? 260 : 0}
      menuAnimated={!isComposer}
      menuHeader={
        modelFetchError ? (
          <Alert tone="warning" role="status" className="m-1 w-auto">
            <WarningCircle />
            <AlertDescription>{modelFetchError}</AlertDescription>
          </Alert>
        ) : undefined
      }
    />
  );
}
