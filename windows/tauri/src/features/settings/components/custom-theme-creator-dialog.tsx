import { save } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";
import { useMemo, useState } from "react";
import {
  createThemeFileFromBase,
  formatThemeFile,
  parseThemeFileJson,
  ThemeFileValidationError,
} from "@/extensions/themes/theme-file";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import type { ThemeDefinition } from "@/extensions/themes/theme.types";
import { installThemeJson } from "@/features/settings/utils/theme-upload";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Field, FieldError, FieldGroup, FieldLabel } from "@/ui/field";
import { BracketsCurlyIcon } from "@/ui/icons";
import Input from "@/ui/input";
import Select from "@/ui/select";
import Textarea from "@/ui/textarea";
import { toast } from "sonner";

interface CustomThemeCreatorDialogProps {
  baseThemeId: string;
  themes: ThemeDefinition[];
  onClose: () => void;
  onInstalled: (themeId: string) => void;
}

function themeIdFromName(name: string): string {
  return name
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function formatIssues(error: unknown, fallback: string): string[] {
  if (error instanceof ThemeFileValidationError) return error.issues;
  return [error instanceof Error ? error.message : fallback];
}

export function CustomThemeCreatorDialog({
  baseThemeId,
  themes,
  onClose,
  onInstalled,
}: CustomThemeCreatorDialogProps) {
  const { t } = useTranslation();
  const fallbackTheme = themes[0];
  const initialBaseTheme = themeRegistry.getTheme(baseThemeId) ?? fallbackTheme;
  const [name, setName] = useState(t("customTheme.defaultName"));
  const [id, setId] = useState("my-lithe-theme");
  const [idEdited, setIdEdited] = useState(false);
  const [selectedBaseThemeId, setSelectedBaseThemeId] = useState(
    initialBaseTheme?.id ?? baseThemeId,
  );
  const [manualJson, setManualJson] = useState<string | null>(null);
  const [issues, setIssues] = useState<string[]>([]);
  const [isInstalling, setIsInstalling] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const selectedBaseTheme =
    themeRegistry.getTheme(selectedBaseThemeId) ?? initialBaseTheme ?? fallbackTheme;
  const generatedJson = useMemo(() => {
    if (!selectedBaseTheme) return "";
    return formatThemeFile(
      createThemeFileFromBase({
        id,
        name,
        baseTheme: selectedBaseTheme,
      }),
    );
  }, [id, name, selectedBaseTheme]);
  const json = manualJson ?? generatedJson;
  const themeOptions = themes.map((theme) => ({ value: theme.id, label: theme.name }));

  const validateJson = () => {
    try {
      const themeFile = parseThemeFileJson(json);
      setIssues([]);
      return themeFile;
    } catch (error) {
      setIssues(formatIssues(error, t("customTheme.generateFailed")));
      return null;
    }
  };

  const handleInstall = async () => {
    if (!validateJson()) return;
    setIsInstalling(true);
    const result = await installThemeJson(json);
    setIsInstalling(false);

    if (!result.success || !result.theme) {
      setIssues(result.details ?? [result.error ?? t("customTheme.installFailed")]);
      return;
    }

    toast.success(
      result.themes?.length === 1
        ? t("customTheme.installed", { theme: result.theme.name })
        : t("customTheme.installedVariants", { count: result.themes?.length ?? 0 }),
    );
    onInstalled(result.theme.id);
    onClose();
  };

  const handleSave = async () => {
    const themeFile = validateJson();
    if (!themeFile) return;

    setIsSaving(true);
    try {
      const targetPath = await save({
        defaultPath: `${themeFile.themes[0]?.id || "lithe-theme"}.json`,
        filters: [
          { name: t("customTheme.filterLitheTheme"), extensions: ["json"] },
          { name: t("customTheme.filterAllFiles"), extensions: ["*"] },
        ],
      });
      if (!targetPath) return;

      await writeTextFile(targetPath, formatThemeFile(themeFile));
      toast.success(t("customTheme.jsonSaved"));
    } catch (error) {
      toast.error(t("customTheme.saveJsonFailed"), {
        description: formatIssues(error, t("customTheme.generateFailed"))[0],
      });
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <Dialog
      title={t("customTheme.createTitle")}
      icon={BracketsCurlyIcon}
      onClose={onClose}
      size="lg"
      footer={
        <>
          <Button type="button" variant="ghost" onClick={onClose} size="sm">
            {t("ui.cancel")}
          </Button>
          <Button
            type="button"
            variant="default"
            size="sm"
            onClick={() => void handleSave()}
            disabled={isSaving}
          >
            {isSaving ? t("ui.saving") : t("customTheme.saveJson")}
          </Button>
          <Button
            type="button"
            variant="accent"
            size="sm"
            onClick={() => void handleInstall()}
            disabled={isInstalling}
          >
            {isInstalling ? t("customTheme.installing") : t("customTheme.install")}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <p className="font-sans ui-text-sm text-subtle-foreground">
          {t("customTheme.description")}
        </p>

        <FieldGroup className="grid grid-cols-2 gap-3">
          <Field>
            <FieldLabel htmlFor="custom-theme-name">{t("customTheme.name")}</FieldLabel>
            <Input
              id="custom-theme-name"
              value={name}
              onChange={(event) => {
                const nextName = event.target.value;
                setName(nextName);
                if (!idEdited) setId(themeIdFromName(nextName));
                setManualJson(null);
              }}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="custom-theme-id">{t("customTheme.id")}</FieldLabel>
            <Input
              id="custom-theme-id"
              value={id}
              onChange={(event) => {
                setId(event.target.value);
                setIdEdited(true);
                setManualJson(null);
              }}
            />
          </Field>
        </FieldGroup>

        <Field>
          <FieldLabel htmlFor="custom-theme-base">{t("customTheme.baseTheme")}</FieldLabel>
          <Select
            id="custom-theme-base"
            value={selectedBaseThemeId}
            options={themeOptions}
            onChange={(value) => {
              setSelectedBaseThemeId(value);
              setManualJson(null);
            }}
            searchable
            searchableTrigger="input"
          />
        </Field>

        <Field data-invalid={issues.length > 0}>
          <FieldLabel htmlFor="custom-theme-json">{t("customTheme.themeJson")}</FieldLabel>
          <Textarea
            id="custom-theme-json"
            value={json}
            onChange={(event) => {
              setManualJson(event.target.value);
              setIssues([]);
            }}
            className="min-h-72 resize-y font-mono"
          />
          <FieldError errors={issues.slice(0, 8).map((message) => ({ message }))} />
        </Field>
      </div>
    </Dialog>
  );
}
