import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { DotsThreeIcon } from "@/ui/icons";
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/ui/dropdown";
import type { RunConfiguration } from "../types/run.types";

interface RunServicesMenuProps {
  services: RunConfiguration[];
  selectedServiceIDs: string[];
  disabled: boolean;
  onSelectionChange: (ids: string[]) => void;
  onRunSelected: () => void;
  onRunAll: () => void;
}

export function RunServicesMenu({
  services,
  selectedServiceIDs,
  disabled,
  onSelectionChange,
  onRunSelected,
  onRunAll,
}: RunServicesMenuProps) {
  const { t } = useTranslation();
  if (services.length === 0) return null;
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            variant="ghost"
            size="icon-xs"
            disabled={disabled}
            aria-label={t("run.chooseServices")}
          />
        }
      >
        <DotsThreeIcon />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuGroup>
          <DropdownMenuLabel>{t("run.services")}</DropdownMenuLabel>
          {services.map((service) => (
            <DropdownMenuCheckboxItem
              key={service.id}
              checked={selectedServiceIDs.includes(service.id)}
              onCheckedChange={(checked) =>
                onSelectionChange(
                  checked
                    ? [...selectedServiceIDs, service.id]
                    : selectedServiceIDs.filter((id) => id !== service.id),
                )
              }
            >
              {service.name}
            </DropdownMenuCheckboxItem>
          ))}
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          disabled={disabled || selectedServiceIDs.length === 0}
          onClick={onRunSelected}
        >
          {t("run.runSelectedServices")}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={disabled} onClick={onRunAll}>
          {t("run.runAllServices")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
