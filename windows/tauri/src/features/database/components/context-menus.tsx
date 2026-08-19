import { PencilSimpleIcon as EditIcon, PlusIcon, TrashIcon } from "@/ui/icons";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { useTranslation } from "@/i18n/locale-provider";
import type { DatabaseRow } from "../types/common.types";

export const SqlTableMenu = ({
  onCreateRow,
  onDeleteTable,
}: {
  onCreateRow: (tableName: string) => void;
  onDeleteTable: (tableName: string) => void;
}) => {
  const { databaseTableMenu, setDatabaseTableMenu } = useUIState();
  const { t } = useTranslation();

  const onCloseMenu = () => setDatabaseTableMenu(null);
  const objectKind = databaseTableMenu?.objectKind ?? "table";
  const canCreateRow = objectKind === "table";
  const deleteLabel =
    objectKind === "view"
      ? t("database.deleteView")
      : objectKind === "materialized_view"
        ? t("database.deleteMaterializedView")
        : objectKind === "index"
          ? t("database.deleteIndex")
          : t("database.deleteTable");
  const items: MenuItem[] = databaseTableMenu
    ? [
        ...(canCreateRow
          ? [
              {
                id: "create-row",
                label: t("database.addNewRow"),
                icon: <PlusIcon />,
                onClick: () => onCreateRow(databaseTableMenu.tableName),
              },
              { id: "separator", label: "", separator: true, onClick: () => {} },
            ]
          : []),
        {
          id: "delete-table",
          label: deleteLabel,
          icon: <TrashIcon />,
          onClick: () => onDeleteTable(databaseTableMenu.tableName),
        },
      ]
    : [];

  return (
    <Dropdown
      isOpen={!!databaseTableMenu}
      point={
        databaseTableMenu ? { x: databaseTableMenu.x, y: databaseTableMenu.y } : { x: 0, y: 0 }
      }
      items={items}
      onClose={onCloseMenu}
    />
  );
};

export const SqlRowMenu = ({
  onEditRow,
  onDeleteRow,
}: {
  onEditRow: (tableName: string, rowData: DatabaseRow) => void;
  onDeleteRow: (tableName: string, rowData: DatabaseRow) => void;
}) => {
  const { databaseRowMenu, setDatabaseRowMenu } = useUIState();
  const { t } = useTranslation();

  const onCloseMenu = () => setDatabaseRowMenu(null);
  const items: MenuItem[] = databaseRowMenu
    ? [
        {
          id: "edit-row",
          label: t("database.editRow"),
          icon: <EditIcon />,
          onClick: () => onEditRow(databaseRowMenu.tableName, databaseRowMenu.rowData),
        },
        {
          id: "delete-row",
          label: t("database.deleteRow"),
          icon: <TrashIcon />,
          onClick: () => onDeleteRow(databaseRowMenu.tableName, databaseRowMenu.rowData),
        },
      ]
    : [];

  return (
    <Dropdown
      isOpen={!!databaseRowMenu}
      point={databaseRowMenu ? { x: databaseRowMenu.x, y: databaseRowMenu.y } : { x: 0, y: 0 }}
      items={items}
      onClose={onCloseMenu}
    />
  );
};
