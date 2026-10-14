import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
} from "@/ui/combobox";
import { useTranslation } from "@/i18n/locale-provider";
import { useState } from "react";
import { matchesSearchQuery } from "@/utils/search-match";

interface SettingsPathInputProps {
  value: string;
  onChange: (value: string) => void;
  candidates: Array<{ path: string; version: string }>;
  label: string;
  placeholder: string;
  disabled?: boolean;
}

/** Path suggestions update the draft on every edit, including paths outside the catalog. */
export default function SettingsPathInput({
  value,
  onChange,
  candidates,
  label,
  placeholder,
  disabled,
}: SettingsPathInputProps) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const hasSuggestions = candidates.some(({ path }) => matchesSearchQuery(value, [path]));
  return (
    <Combobox
      items={candidates.map(({ path }) => path)}
      value={value}
      inputValue={value}
      open={open && hasSuggestions}
      onOpenChange={setOpen}
      filter={(path, query) => matchesSearchQuery(query, [path])}
      onInputValueChange={(nextValue, eventDetails) => {
        // Base UI clears a closed combobox on Esc; a toolchain draft must survive dismissal.
        if (eventDetails.reason === "escape-key") {
          eventDetails.cancel();
          return;
        }
        onChange(nextValue);
      }}
      onValueChange={(path) => {
        if (path !== null) onChange(path);
      }}
      disabled={disabled}
      modal={false}
    >
      <ComboboxInput
        aria-label={label}
        placeholder={placeholder}
        size="sm"
        className="min-w-0 flex-1"
      />
      <ComboboxContent data-prevent-dialog-escape="true">
        <ComboboxEmpty>{t("ui.noMatchingOptions")}</ComboboxEmpty>
        <ComboboxList>
          {(path: string) => (
            <ComboboxItem key={path} value={path}>
              <span className="min-w-0 flex-1 truncate">{path}</span>
              <span className="shrink-0 text-subtle-foreground">
                {candidates.find((candidate) => candidate.path === path)?.version}
              </span>
            </ComboboxItem>
          )}
        </ComboboxList>
      </ComboboxContent>
    </Combobox>
  );
}
