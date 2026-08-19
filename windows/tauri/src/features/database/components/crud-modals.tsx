import { PlusIcon, XIcon } from "@/ui/icons";
import { useEffect, useState } from "react";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Dialog from "@/ui/dialog";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { useTranslation } from "@/i18n/locale-provider";
import type { ColumnInfo, DatabaseRow } from "../types/common.types";
import {
  getInitialCreateTableColumn,
  normalizeCreateTableColumns,
  type CreateTableColumnDraft,
} from "../utils/create-table-form";
import { buildDatabaseRowValues, databaseRowToFormValues } from "../utils/value-coercion";

interface CreateRowModalProps {
  isOpen: boolean;
  onClose: () => void;
  tableName: string;
  columns: ColumnInfo[];
  onSubmit: (values: DatabaseRow) => void;
}

export const CreateRowModal = ({
  isOpen,
  onClose,
  tableName,
  columns,
  onSubmit,
}: CreateRowModalProps) => {
  const [values, setValues] = useState<Record<string, string>>({});
  const { t } = useTranslation();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onSubmit(buildDatabaseRowValues(values, columns));
    setValues({});
    onClose();
  };

  const handleClose = () => {
    setValues({});
    onClose();
  };

  if (!isOpen) return null;

  return (
    <Dialog
      onClose={handleClose}
      title={t("database.addRowToTable", { table: tableName })}
      icon={PlusIcon}
      size="md"
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        {columns
          .filter((col) => col.name.toLowerCase() !== "rowid")
          .map((column, index) => {
            const fieldId = `create-row-field-${index}`;
            return (
              <div key={column.name} className="space-y-1">
                <label htmlFor={fieldId} className="font-sans block ui-text-sm text-foreground">
                  {column.name}
                  <span className="ml-1 text-subtle-foreground ui-text-sm">({column.type})</span>
                </label>
                <Input
                  id={fieldId}
                  type={
                    column.type.toLowerCase().includes("int") ||
                    column.type.toLowerCase().includes("real")
                      ? "number"
                      : "text"
                  }
                  value={values[column.name] || ""}
                  onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
                    setValues((prev) => ({ ...prev, [column.name]: e.target.value }))
                  }
                  className="w-full"
                  placeholder={column.notnull ? t("database.required") : t("database.optional")}
                />
              </div>
            );
          })}

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={handleClose} size="xs">
            {t("ui.cancel")}
          </Button>
          <Button type="submit" className="gap-1" size="xs">
            <PlusIcon size="14" />
            {t("database.addRow")}
          </Button>
        </div>
      </form>
    </Dialog>
  );
};

interface EditRowModalProps {
  isOpen: boolean;
  onClose: () => void;
  tableName: string;
  columns: ColumnInfo[];
  initialData: DatabaseRow;
  onSubmit: (values: DatabaseRow) => void;
}

export const EditRowModal = ({
  isOpen,
  onClose,
  tableName,
  columns,
  initialData,
  onSubmit,
}: EditRowModalProps) => {
  const [values, setValues] = useState<Record<string, string>>(() =>
    databaseRowToFormValues(initialData),
  );
  const { t } = useTranslation();

  useEffect(() => {
    if (isOpen) {
      setValues(databaseRowToFormValues(initialData));
    }
  }, [initialData, isOpen]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onSubmit(buildDatabaseRowValues(values, columns));
    onClose();
  };

  const handleClose = () => {
    setValues(databaseRowToFormValues(initialData));
    onClose();
  };

  if (!isOpen) return null;

  return (
    <Dialog onClose={handleClose} title={t("database.editRowInTable", { table: tableName })} size="md">
      <form onSubmit={handleSubmit} className="space-y-4">
        {columns
          .filter((col) => col.name.toLowerCase() !== "rowid")
          .map((column, index) => {
            const fieldId = `edit-row-field-${index}`;
            return (
              <div key={column.name} className="space-y-1">
                <label htmlFor={fieldId} className="font-sans block ui-text-sm text-foreground">
                  {column.name}
                  <span className="ml-1 text-subtle-foreground ui-text-sm">({column.type})</span>
                </label>
                <Input
                  id={fieldId}
                  type={
                    column.type.toLowerCase().includes("int") ||
                    column.type.toLowerCase().includes("real")
                      ? "number"
                      : "text"
                  }
                  value={values[column.name] || ""}
                  onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
                    setValues((prev) => ({ ...prev, [column.name]: e.target.value }))
                  }
                  className="w-full"
                  placeholder={column.notnull ? t("database.required") : t("database.optional")}
                />
              </div>
            );
          })}

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={handleClose} size="xs">
            {t("ui.cancel")}
          </Button>
          <Button type="submit" size="xs">
            {t("database.saveChanges")}
          </Button>
        </div>
      </form>
    </Dialog>
  );
};

interface CreateTableModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (tableName: string, columns: CreateTableColumnDraft[]) => void;
}

export const CreateTableModal = ({ isOpen, onClose, onSubmit }: CreateTableModalProps) => {
  const [tableName, setTableName] = useState("");
  const [columns, setColumns] = useState<CreateTableColumnDraft[]>([getInitialCreateTableColumn()]);
  const normalizedColumns = normalizeCreateTableColumns(columns);
  const canSubmit = tableName.trim().length > 0 && normalizedColumns.length > 0;
  const { t } = useTranslation();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (canSubmit) {
      onSubmit(tableName.trim(), normalizedColumns);
      handleClose();
    }
  };

  const handleClose = () => {
    setTableName("");
    setColumns([getInitialCreateTableColumn()]);
    onClose();
  };

  const addColumn = () => {
    setColumns((prev) => [...prev, getInitialCreateTableColumn()]);
  };

  const removeColumn = (index: number) => {
    if (columns.length > 1) {
      setColumns((prev) => prev.filter((_, i) => i !== index));
    }
  };

  const updateColumn = (
    index: number,
    field: keyof CreateTableColumnDraft,
    value: string | boolean,
  ) => {
    setColumns((prev) => prev.map((col, i) => (i === index ? { ...col, [field]: value } : col)));
  };

  if (!isOpen) return null;

  return (
    <Dialog onClose={handleClose} title={t("database.createNewTable")} icon={PlusIcon} size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-1">
          <label htmlFor="table-name" className="font-sans block ui-text-sm text-foreground">
            {t("database.tableName")}
          </label>
          <Input
            id="table-name"
            value={tableName}
            onChange={(e: React.ChangeEvent<HTMLInputElement>) => setTableName(e.target.value)}
            placeholder={t("database.enterTableName")}
            required
          />
        </div>

        <div className="space-y-2">
          <div className="font-sans block ui-text-sm text-foreground">
            {t("database.columns")}
          </div>
          {columns.map((column, index) => (
            <div key={index} className="flex items-center gap-2">
              <Input
                value={column.name}
                onChange={(e: React.ChangeEvent<HTMLInputElement>) =>
                  updateColumn(index, "name", e.target.value)
                }
                placeholder={t("database.columnName")}
                className="flex-1"
                required
              />
              <Select
                value={column.type}
                onChange={(value) => updateColumn(index, "type", value)}
                options={[
                  { value: "TEXT", label: "TEXT" },
                  { value: "INTEGER", label: "INTEGER" },
                  { value: "REAL", label: "REAL" },
                  { value: "BLOB", label: "BLOB" },
                ]}
                size="md"
                className="bg-surface"
              />
              <label
                htmlFor={`column-not-null-${index}`}
                className="font-sans flex items-center gap-1 text-foreground ui-text-sm"
              >
                <Checkbox
                  id={`column-not-null-${index}`}
                  checked={column.notnull}
                  onCheckedChange={(checked) => updateColumn(index, "notnull", checked)}
                  aria-label={t("database.setColumnNotNull", {
                    column: column.name || t("database.columnNumber", { number: index + 1 }),
                  })}
                />
                NOT NULL
              </label>
              {columns.length > 1 && (
                <Button
                  type="button"
                  onClick={() => removeColumn(index)}
                  variant="danger"
                  size="icon-xs"
                  aria-label={t("database.removeColumn", {
                    column: column.name || t("database.columnNumber", { number: index + 1 }),
                  })}
                >
                  <XIcon size="14" />
                </Button>
              )}
            </div>
          ))}
          <Button type="button" onClick={addColumn} variant="ghost" size="xs">
            <PlusIcon size="12" />
            {t("database.addColumn")}
          </Button>
        </div>

        <div className="flex justify-end gap-2 pt-2">
          <Button type="button" variant="ghost" onClick={handleClose} size="xs">
            {t("ui.cancel")}
          </Button>
          <Button type="submit" disabled={!canSubmit}>
            {t("database.createTable")}
          </Button>
        </div>
      </form>
    </Dialog>
  );
};
