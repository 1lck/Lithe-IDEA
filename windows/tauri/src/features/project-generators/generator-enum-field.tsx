import Select from "@/ui/select";
import { ToggleGroup } from "@/ui/toggle-group";
import { enumPresentation, type DeclarationField } from "./generator-form-session";

export function GeneratorEnumField({
  field,
  value,
  onChange,
}: {
  field: DeclarationField;
  value: string;
  onChange(value: string): void;
}) {
  const options = (field.options ?? []).map((option) => ({
    value: option.value,
    label: option.title,
  }));
  return enumPresentation(field) === "segmented" ? (
    <ToggleGroup
      variant="segmented"
      ariaLabel={field.title}
      value={value}
      options={options}
      onValueChange={onChange}
    />
  ) : (
    <Select
      id={`generator-field-${field.id}`}
      value={value}
      options={options}
      onChange={onChange}
    />
  );
}
