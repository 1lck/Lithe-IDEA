import { useEffect, useRef } from "react";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import { TerminalIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type { RunActionDraft } from "../types/run-action.types";

interface RunActionDialogProps {
  draft: RunActionDraft;
  workspaceLabel: string;
  onChange: (draft: RunActionDraft) => void;
  onClose: () => void;
  onSave: () => void;
}

export default function RunActionDialog({
  draft,
  workspaceLabel,
  onChange,
  onClose,
  onSave,
}: RunActionDialogProps) {
  const { t } = useTranslation();
  const nameInputRef = useRef<HTMLInputElement>(null);
  const canSave = Boolean(draft.name.trim() && draft.command.trim());

  useEffect(() => {
    const timeoutId = window.setTimeout(() => nameInputRef.current?.focus(), 20);
    return () => window.clearTimeout(timeoutId);
  }, []);

  return (
    <Dialog
      title={draft.id ? t("runActions.editRunAction") : t("runActions.newRunAction")}
      icon={TerminalIcon}
      onClose={onClose}
      size="sm"
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            {t("ui.cancel")}
          </Button>
          <Button onClick={onSave} disabled={!canSave} size="xs">
            {draft.id ? t("runActions.saveChanges") : t("runActions.addAction")}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <div className="rounded-lg bg-surface/60 px-3 py-2 text-subtle-foreground ui-text-sm">
          {t("runActions.savedForPrefix")}{" "}
          <span className="font-medium text-foreground">{workspaceLabel}</span>{" "}
          {t("runActions.savedForSuffix")}
        </div>

        <Field>
          <FieldLabel htmlFor="run-action-name">{t("runActions.name")}</FieldLabel>
          <Input
            id="run-action-name"
            ref={nameInputRef}
            value={draft.name}
            onChange={(event) => onChange({ ...draft, name: event.target.value })}
            placeholder={t("runActions.namePlaceholder")}
          />
        </Field>

        <Field>
          <FieldLabel htmlFor="run-action-command">{t("run.command")}</FieldLabel>
          <Input
            id="run-action-command"
            value={draft.command}
            onChange={(event) => onChange({ ...draft, command: event.target.value })}
            placeholder="bun run dev"
            className="font-mono"
            onKeyDown={(event) => {
              if (event.key === "Enter" && canSave) {
                event.preventDefault();
                onSave();
              }
            }}
          />
        </Field>

        <Field>
          <FieldLabel htmlFor="run-action-directory">{t("run.workingDirectory")}</FieldLabel>
          <Input
            id="run-action-directory"
            value={draft.workingDirectory}
            onChange={(event) => onChange({ ...draft, workingDirectory: event.target.value })}
            placeholder="."
            className="font-mono"
          />
          <FieldDescription>
            {t("runActions.workingDirectoryDescription")}{" "}
            <code className="font-mono text-muted-foreground">apps/web</code>.
          </FieldDescription>
        </Field>
      </div>
    </Dialog>
  );
}
