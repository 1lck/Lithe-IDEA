import Select, { type SelectProps } from "@/ui/select";
import { cn } from "@/utils/cn";

type SettingsSelectProps = Omit<SelectProps, "size" | "variant" | "searchableTrigger">;

/** Settings share one trigger density and the existing Select popup and keyboard behavior. */
export default function SettingsSelect({ className, ...props }: SettingsSelectProps) {
  return (
    <Select
      {...props}
      className={cn("w-40 max-w-full", className)}
      size="sm"
      variant="default"
      searchableTrigger="menu"
    />
  );
}
