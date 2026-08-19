import { useState } from "react";
import { WarningCircleIcon as WarningCircle } from "@/ui/icons";
import { cva } from "class-variance-authority";
import { Alert, AlertDescription } from "@/ui/alert";
import Badge from "@/ui/badge";
import { Button } from "@/ui/button";
import { useTranslation } from "@/i18n/locale-provider";
import { TableCell, TableRow } from "@/ui/table";
import KeybindingDisplay from "./keybinding";
import { cn } from "@/utils/cn";
import { useKeybindingConflicts } from "../hooks/use-keybinding-conflicts";
import { useKeymapStore } from "../stores/keymaps.store";
import type { Command, Keybinding } from "../types/keymaps.types";
import { localizeKeymapCommand } from "../utils/command-localization";
import { KeybindingInput } from "./keybinding-input";

export const keybindingTableMinWidth = cva("min-w-175");

interface KeybindingRowProps {
  command: Command;
  keybinding?: Keybinding;
}

export function KeybindingRow({ command, keybinding }: KeybindingRowProps) {
  const { t } = useTranslation();
  const [isEditing, setIsEditing] = useState(false);
  const { addKeybinding, updateKeybinding, removeKeybinding } = useKeymapStore.use.actions();
  const { hasConflict, conflictingCommands } = useKeybindingConflicts(
    keybinding?.key || "",
    command.id,
    keybinding?.when,
  );

  const handleSave = (newKey: string) => {
    if (keybinding?.source === "user") {
      // Update existing user keybinding
      updateKeybinding(command.id, { key: newKey });
    } else {
      // Remove any existing user override first, then add new one
      // This handles both "no keybinding" and "default/extension keybinding" cases
      removeKeybinding(command.id);
      addKeybinding({
        key: newKey,
        command: command.id,
        source: "user",
        enabled: true,
        when: keybinding?.when,
      });
    }
    setIsEditing(false);
  };

  const handleRemove = () => {
    removeKeybinding(command.id);
  };

  const handleReset = () => {
    // Remove user override - the default keybinding will be used automatically
    removeKeybinding(command.id);
  };

  const source = keybinding?.source || "default";
  const localizedCommand = localizeKeymapCommand(command, t);
  const isUserOverride = source === "user";
  const sourceLabel =
    source === "preset"
      ? t("keybindings.preset")
      : source === "default"
        ? t("keybindings.default")
        : source === "extension"
          ? t("keybindings.extension")
          : t("keybindings.user");

  return (
    <>
      <TableRow className={cn(hasConflict && "bg-destructive/5 hover:bg-destructive/10")}>
        <TableCell className="min-w-0">
          <div className="font-sans ui-text-sm truncate text-foreground">{localizedCommand.title}</div>
          <div className="font-sans ui-text-sm mt-0.5 truncate text-subtle-foreground">
            {localizedCommand.category} • {command.id}
          </div>
        </TableCell>

        <TableCell>
          {isEditing ? (
            <KeybindingInput
              commandId={command.id}
              value={keybinding?.key}
              onSave={handleSave}
              onCancel={() => setIsEditing(false)}
            />
          ) : (
            <Button
              type="button"
              onClick={() => setIsEditing(true)}
              variant="default"
              size="xs"
              className="ui-text-sm flex h-7 w-full items-center justify-start px-1.5 hover:border hover:border-primary"
              aria-label={t("keybindings.editForCommand", { title: localizedCommand.title })}
            >
              {keybinding?.key ? (
                <KeybindingDisplay binding={keybinding.key} />
              ) : (
                <span className="text-subtle-foreground">{t("keybindings.notAssigned")}</span>
              )}
            </Button>
          )}
        </TableCell>

        <TableCell className="truncate text-subtle-foreground">
          {keybinding?.when || command.keybinding ? keybinding?.when || "-" : "-"}
        </TableCell>

        <TableCell>
          <Badge
            variant={isUserOverride ? "accent" : "default"}
            size="compact"
            className="h-6 min-w-17 px-2"
          >
            {sourceLabel}
          </Badge>
        </TableCell>

        <TableCell>
          <div className="flex items-center gap-1">
            {isUserOverride && (
              <Button
                type="button"
                onClick={handleReset}
                variant="ghost"
                className="ui-text-sm text-subtle-foreground hover:text-foreground"
                tooltip={t("keybindings.resetToDefault")}
                aria-label={t("keybindings.resetToDefaultAria")}
                size="xs"
              >
                {t("keybindings.reset")}
              </Button>
            )}
            {keybinding && (
              <Button
                type="button"
                onClick={handleRemove}
                variant="ghost"
                className="ui-text-sm text-subtle-foreground hover:text-destructive"
                tooltip={t("keybindings.removeKeybinding")}
                aria-label={t("keybindings.removeKeybinding")}
                size="xs"
              >
                {t("keybindings.remove")}
              </Button>
            )}
          </div>
        </TableCell>
      </TableRow>

      {hasConflict && (
        <TableRow className="bg-destructive/5 hover:bg-destructive/5">
          <TableCell colSpan={5} className="pt-0">
            <Alert tone="error" className="py-1.5">
              <WarningCircle />
              <AlertDescription>
                {t("keybindings.conflictsWith", {
                  commands: conflictingCommands
                    .map((conflict) => localizeKeymapCommand(conflict, t).title)
                    .join(", "),
                })}
              </AlertDescription>
            </Alert>
          </TableCell>
        </TableRow>
      )}
    </>
  );
}
