import { useEffect } from "react";
import { getPrimaryFontFamily } from "@/features/settings/lib/font-family-resolution";
import { useFontStore } from "@/features/settings/stores/font.store";
import type { FontInfo } from "@/features/settings/types/font.types";
import { useTranslation } from "@/i18n/locale-provider";
import Select from "@/ui/select";

const BUNDLED_FONTS: FontInfo[] = [
  { name: "Geist Sans", family: "Geist Sans", style: "Regular", is_monospace: false },
  { name: "Geist Mono", family: "Geist Mono", style: "Regular", is_monospace: true },
];

interface FontSelectorProps {
  value: string;
  onChange: (fontFamily: string) => void;
  className?: string;
  monospaceOnly?: boolean;
  "aria-label"?: string;
}

/** A catalog is a list of choices, not permission to replace a saved font.
 * Pending, empty, unavailable and failed catalogs never call onChange. */
export const FontSelector = ({
  value,
  onChange,
  className = "",
  monospaceOnly = false,
  "aria-label": ariaLabel,
}: FontSelectorProps) => {
  const availableFonts = useFontStore.use.availableFonts();
  const monospaceFonts = useFontStore.use.monospaceFonts();
  const isLoading = useFontStore.use.isLoading();
  const error = useFontStore.use.error();
  const { loadAvailableFonts, loadMonospaceFonts } = useFontStore.use.actions();
  const { t } = useTranslation();

  useEffect(() => {
    // Ask the native catalog again when opening settings to include newly installed fonts.
    if (monospaceOnly) void loadMonospaceFonts(true);
    else void loadAvailableFonts(true);
  }, [monospaceOnly, loadAvailableFonts, loadMonospaceFonts]);

  const systemFonts = monospaceOnly ? monospaceFonts : availableFonts;
  const bundled = BUNDLED_FONTS.filter((font) => !monospaceOnly || font.is_monospace);
  const seen = new Set<string>();
  const fontOptions = [...systemFonts, ...bundled]
    .flatMap((font) => {
      const key = font.family.toLowerCase();
      if (seen.has(key)) return [];
      seen.add(key);
      const label =
        font.name && font.name !== font.family ? `${font.name} (${font.family})` : font.family;
      return [{ value: font.family, label, keywords: [font.name, font.family] }];
    })
    .sort((left, right) => left.label.localeCompare(right.label));
  const selected = getPrimaryFontFamily(value) || value;
  if (selected && !fontOptions.some((option) => option.value === selected)) {
    fontOptions.unshift({
      value: selected,
      label: t("fontSelector.custom", { font: selected }),
      keywords: [selected],
    });
  }

  return (
    <div className={className}>
      <Select
        value={selected}
        options={fontOptions}
        onChange={onChange}
        placeholder={t("fontSelector.select")}
        aria-label={ariaLabel ?? t("fontSelector.select")}
        className="w-full"
        size="sm"
        variant="default"
        searchable
        searchableTrigger="input"
      />
      {isLoading && (
        <span role="status" className="ui-text-xs text-subtle-foreground">
          {t("fontSelector.loading")}
        </span>
      )}
      {error && (
        <span role="status" className="ui-text-xs text-destructive">
          {t("fontSelector.error", { error })}
        </span>
      )}
    </div>
  );
};
