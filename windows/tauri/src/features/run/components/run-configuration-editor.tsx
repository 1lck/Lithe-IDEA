import { useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import { FolderIcon, PlayIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type { RunConfiguration, RunOptions, RunSaveScope } from "../types/run.types";
import { environmentFromText, environmentText } from "../utils/run-configuration";

interface RunConfigurationEditorProps {
  configuration: RunConfiguration;
  options: RunOptions;
  saveError: string | null;
  onClose: () => void;
  onSave: (options: RunOptions, scope: RunSaveScope) => Promise<boolean>;
}

export function RunConfigurationEditor({
  configuration,
  options,
  saveError,
  onClose,
  onSave,
}: RunConfigurationEditorProps) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState(options);
  const [scope, setScope] = useState<RunSaveScope>("local");
  const [envText, setEnvText] = useState(environmentText(options.environment));
  const [saving, setSaving] = useState(false);

  const pickDirectory = async (field: "javaHomePath" | "mavenJavaHomePath" | "workingDirectoryPath") => {
    const selected = await open({ directory: true, multiple: false });
    if (typeof selected === "string" && selected) {
      setDraft((current) => ({ ...current, [field]: selected }));
    }
  };

  const pickFile = async () => {
    const selected = await open({ multiple: false });
    if (typeof selected === "string" && selected) {
      setDraft((current) => ({ ...current, mavenExecutablePath: selected }));
    }
  };

  return (
    <Dialog
      title={t("run.editorTitle")}
      icon={PlayIcon}
      onClose={onClose}
      size="lg"
      footer={
        <>
          {saveError ? <span className="min-w-0 flex-1 truncate text-destructive ui-text-sm">{saveError}</span> : <span />}
          <Button variant="ghost" onClick={onClose}>
            {t("run.cancel")}
          </Button>
          <Button
            disabled={saving}
            onClick={() => {
              setSaving(true);
              void onSave(
                { ...draft, environment: environmentFromText(envText) },
                scope,
              ).then((saved) => {
                setSaving(false);
                if (saved) onClose();
              });
            }}
          >
            {t("run.done")}
          </Button>
        </>
      }
    >
      <div className="space-y-5">
        <div>
          <div className="mb-2 font-medium text-subtle-foreground ui-text-sm">{t("run.saveScope")}</div>
          <div className="flex gap-1 rounded-md bg-surface p-0.5">
            <Button
              size="xs"
              variant={scope === "local" ? "accent" : "ghost"}
              onClick={() => setScope("local")}
            >
              {t("run.saveScopeLocal")}
            </Button>
            <Button
              size="xs"
              variant={scope === "project" ? "accent" : "ghost"}
              onClick={() => setScope("project")}
            >
              {t("run.saveScopeProject")}
            </Button>
          </div>
          <p className="mt-2 text-subtle-foreground ui-text-sm">
            {scope === "local" ? t("run.saveScopeLocalHint") : t("run.saveScopeProjectHint")}
          </p>
        </div>

        <div className="space-y-1.5">
          <div className="font-medium text-subtle-foreground ui-text-sm">{t("run.configuration")}</div>
          <div className="grid grid-cols-[7.5rem_1fr] gap-y-1 ui-text-sm">
            <span className="text-subtle-foreground">{t("run.type")}</span>
            <span>{configuration.kindTitle}</span>
            <span className="text-subtle-foreground">{t("run.effectiveSource")}</span>
            <span>{t(`run.source.${configuration.source}`)}</span>
            {configuration.mainClass ? (
              <>
                <span className="text-subtle-foreground">{t("run.mainClass")}</span>
                <span className="truncate font-mono">{configuration.mainClass}</span>
              </>
            ) : null}
          </div>
        </div>

        <Field>
          <FieldLabel htmlFor="run-jdk-home">{t("run.jdkHome")}</FieldLabel>
          <div className="flex gap-1.5">
            <Input
              id="run-jdk-home"
              value={draft.javaHomePath}
              onChange={(event) => setDraft({ ...draft, javaHomePath: event.target.value })}
              className="font-mono"
            />
            <Button type="button" variant="ghost" size="icon-sm" onClick={() => void pickDirectory("javaHomePath")}>
              <FolderIcon />
            </Button>
          </div>
          <FieldDescription>{t("run.jdkHomeHint")}</FieldDescription>
        </Field>

        <Field>
          <FieldLabel htmlFor="run-maven">{t("run.mavenExecutable")}</FieldLabel>
          <div className="flex gap-1.5">
            <Input
              id="run-maven"
              value={draft.mavenExecutablePath}
              onChange={(event) => setDraft({ ...draft, mavenExecutablePath: event.target.value })}
              className="font-mono"
            />
            <Button type="button" variant="ghost" size="icon-sm" onClick={() => void pickFile()}>
              <FolderIcon />
            </Button>
          </div>
          <FieldDescription>{t("run.mavenExecutableHint")}</FieldDescription>
        </Field>

        <Field>
          <FieldLabel htmlFor="run-maven-jdk">{t("run.mavenJdkHome")}</FieldLabel>
          <div className="flex gap-1.5">
            <Input
              id="run-maven-jdk"
              value={draft.mavenJavaHomePath}
              onChange={(event) => setDraft({ ...draft, mavenJavaHomePath: event.target.value })}
              className="font-mono"
            />
            <Button type="button" variant="ghost" size="icon-sm" onClick={() => void pickDirectory("mavenJavaHomePath")}>
              <FolderIcon />
            </Button>
          </div>
          <FieldDescription>{t("run.mavenJdkHomeHint")}</FieldDescription>
        </Field>

        <Field>
          <FieldLabel htmlFor="run-cwd">{t("run.workingDirectory")}</FieldLabel>
          <Input
            id="run-cwd"
            value={draft.workingDirectoryPath}
            onChange={(event) => setDraft({ ...draft, workingDirectoryPath: event.target.value })}
            className="font-mono"
          />
          <FieldDescription>{t("run.workingDirectoryHint")}</FieldDescription>
        </Field>
      </div>
    </Dialog>
  );
}
