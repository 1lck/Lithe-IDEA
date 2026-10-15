import { ProviderIcon } from "@/features/ai/components/icons/provider-icons";
import {
  useAvailableProviders,
  useProviderById,
} from "@/features/ai/hooks/use-available-providers";
import { useTranslation } from "@/i18n/locale-provider";
import Select from "@/ui/select";
import SettingsSelect from "@/ui/settings-select";
import { cn } from "@/utils/cn";

interface ProviderSelectorProps {
  providerId: string;
  onChange: (providerId: string) => void;
  appearance?: "settings" | "composer";
  disabled?: boolean;
  className?: string;
  triggerClassName?: string;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  tooltip?: string;
}

export function ProviderSelector({
  providerId,
  onChange,
  appearance = "settings",
  disabled,
  className,
  triggerClassName,
  open,
  onOpenChange,
  tooltip,
}: ProviderSelectorProps) {
  const { t } = useTranslation();
  const providers = useAvailableProviders();
  const currentProvider = useProviderById(providerId);
  const isComposer = appearance === "composer";
  const iconSize = isComposer ? 12 : 14;
  const SelectControl = isComposer ? Select : SettingsSelect;

  return (
    <SelectControl
      value={providerId}
      onChange={onChange}
      options={providers.map((provider) => ({
        value: provider.id,
        label: provider.name,
        icon: (
          <ProviderIcon
            providerId={provider.id}
            size={iconSize}
            className="shrink-0 text-subtle-foreground"
          />
        ),
      }))}
      placeholder={currentProvider?.name || providerId || t("ai.selectProvider")}
      aria-label={t("ai.selectAiProvider")}
      searchable
      hideChevron={isComposer}
      {...(isComposer
        ? { size: "xs" as const, variant: "ghost" as const, searchableTrigger: "input" as const }
        : {})}
      disabled={disabled}
      open={open}
      onOpenChange={onOpenChange}
      tooltip={tooltip}
      className={cn(!isComposer && "w-56 max-w-full", className)}
      triggerClassName={cn(isComposer && "max-w-32", triggerClassName)}
      menuClassName={isComposer ? "w-fit min-w-0 max-w-(--available-width) p-0" : undefined}
      menuMinWidth={isComposer ? 220 : 0}
      menuAnimated={!isComposer}
    />
  );
}
