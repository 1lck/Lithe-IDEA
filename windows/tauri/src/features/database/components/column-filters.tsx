import { PlusIcon as Plus, XIcon as X } from "@/ui/icons";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { useTranslation } from "@/i18n/locale-provider";
import { databaseCardClassName } from "./database-surface";
import type { ColumnFilter, ColumnInfo, FilterOperator } from "../types/common.types";

const FILTER_OPERATORS: { value: FilterOperator; labelKey: string; fallback: string }[] = [
  { value: "equals", labelKey: "database.filterEquals", fallback: "=" },
  { value: "notEquals", labelKey: "database.filterNotEquals", fallback: "!=" },
  { value: "contains", labelKey: "database.filterContains", fallback: "contains" },
  { value: "startsWith", labelKey: "database.filterStartsWith", fallback: "starts with" },
  { value: "endsWith", labelKey: "database.filterEndsWith", fallback: "ends with" },
  { value: "gt", labelKey: "database.filterGreaterThan", fallback: ">" },
  { value: "gte", labelKey: "database.filterGreaterThanOrEqual", fallback: ">=" },
  { value: "lt", labelKey: "database.filterLessThan", fallback: "<" },
  { value: "lte", labelKey: "database.filterLessThanOrEqual", fallback: "<=" },
  { value: "between", labelKey: "database.filterBetween", fallback: "between" },
  { value: "isNull", labelKey: "database.filterIsNull", fallback: "is null" },
  { value: "isNotNull", labelKey: "database.filterIsNotNull", fallback: "is not null" },
];

const NO_VALUE_OPERATORS = new Set<FilterOperator>(["isNull", "isNotNull"]);

interface ColumnFiltersProps {
  filters: ColumnFilter[];
  columns: ColumnInfo[];
  onUpdate: (index: number, updates: Partial<ColumnFilter>) => void;
  onRemove: (index: number) => void;
  onClear: () => void;
  onAddFilter: (column: string) => void;
}

export default function ColumnFilters({
  filters,
  columns,
  onUpdate,
  onRemove,
  onClear,
  onAddFilter,
}: ColumnFiltersProps) {
  const { t } = useTranslation();
  if (filters.length === 0) return null;

  return (
    <div className={databaseCardClassName("mx-3 mb-2 bg-surface/60 px-3 py-2")}>
      <div className="mb-2 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="font-sans ui-text-sm text-subtle-foreground">
            {t("database.filtersCount", { count: filters.length })}
          </span>
          {columns.length > 0 && (
            <Button
              onClick={() => onAddFilter(columns[0].name)}
              variant="ghost"
              size="xs"
              className="gap-0.5 text-subtle-foreground"
              aria-label={t("database.addFilter")}
            >
              <Plus />
              {t("database.add")}
            </Button>
          )}
        </div>
        <Button
          onClick={onClear}
          variant="ghost"
          className="text-subtle-foreground"
          aria-label={t("database.clearAllFilters")}
          size="xs"
        >
          {t("database.clearAll")}
        </Button>
      </div>
      <div className="space-y-1">
        {filters.map((filter, index) => (
          <div key={index} className="flex items-center gap-2 font-sans ui-text-sm">
            <Select
              value={filter.column}
              options={columns.map((column) => ({ value: column.name, label: column.name }))}
              onChange={(value) => onUpdate(index, { column: value })}
              size="xs"
              className="min-w-20"
            />
            <Select
              value={filter.operator}
              options={FILTER_OPERATORS.map((operator) => ({
                value: operator.value,
                label: t(operator.labelKey) || operator.fallback,
              }))}
              onChange={(value) => onUpdate(index, { operator: value as FilterOperator })}
              size="xs"
              className="min-w-20"
            />
            {!NO_VALUE_OPERATORS.has(filter.operator) && (
              <Input
                value={filter.value}
                onChange={(e) => onUpdate(index, { value: e.target.value })}
                placeholder={t("database.value")}
                size="xs"
                className="flex-1"
              />
            )}
            {filter.operator === "between" && (
              <Input
                value={filter.value2 || ""}
                onChange={(e) => onUpdate(index, { value2: e.target.value })}
                placeholder={t("database.to")}
                size="xs"
                className="flex-1"
              />
            )}
            <Button
              onClick={() => onRemove(index)}
              variant="ghost"
              size="icon-xs"
              className="text-subtle-foreground hover:text-destructive"
              aria-label={t("database.removeFilter")}
            >
              <X />
            </Button>
          </div>
        ))}
      </div>
    </div>
  );
}
