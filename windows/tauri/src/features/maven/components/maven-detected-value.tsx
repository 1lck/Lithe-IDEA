import { useTranslation } from "@/i18n/locale-provider";
import type { MavenEffectiveConfiguration, MavenSettings } from "../types/maven.types";

/**
 * The gray line shown under a blank Maven path field: what the launch would use
 * instead, or that nothing was detected. Renders nothing once the field holds a
 * custom value (the input is then the effective value) and nothing before the
 * detection has resolved.
 */
export function MavenDetectedValue({
  field,
  value,
  effective,
}: {
  field: keyof MavenSettings;
  value: string;
  effective: MavenEffectiveConfiguration | null;
}) {
  const { t } = useTranslation();
  if (value || !effective) return null;
  const detected = effective[field];
  return (
    <p
      className="truncate font-mono text-subtle-foreground ui-text-xs"
      title={detected ?? undefined}
      data-maven-detected={field}
    >
      {detected ? t("maven.detectedValue", { value: detected }) : t("maven.detectedMissing")}
    </p>
  );
}
