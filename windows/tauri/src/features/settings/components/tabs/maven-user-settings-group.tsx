import { open } from "@tauri-apps/plugin-dialog";
import { useCallback, useEffect, useState } from "react";
import {
  MAVEN_USER_SETTINGS_ERRORS,
  readMavenUserSettings,
  writeMavenUserLocalRepository,
} from "@/features/maven/api/maven-host-api";
import type { MavenUserSettings } from "@/features/maven/types/maven.types";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { FolderIcon } from "@/ui/icons";

type LoadState =
  | { status: "loading" }
  | { status: "loaded"; settings: MavenUserSettings }
  | { status: "failed"; error: string };

export interface MavenUserSettingsDependencies {
  read: () => Promise<MavenUserSettings>;
  write: (localRepository: string, expectedRevision: string | null) => Promise<MavenUserSettings>;
  browse: () => Promise<string | null>;
}

const defaultDependencies: MavenUserSettingsDependencies = {
  read: readMavenUserSettings,
  write: writeMavenUserLocalRepository,
  browse: async () => {
    const selected = await open({ directory: true, multiple: false });
    return typeof selected === "string" ? selected : null;
  },
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** The message key for a host error code, or null for an OS diagnostic. */
function errorKey(message: string): string | null {
  for (const [code, key] of Object.entries(MAVEN_USER_SETTINGS_ERRORS)) {
    if (message === code || message.startsWith(`${code}:`)) return key;
  }
  return null;
}

/** The value the field starts from: what the file says, else Maven's default. */
function baselineOf(settings: MavenUserSettings): string {
  return settings.localRepository ?? settings.defaultLocalRepository;
}

/**
 * Edits `<localRepository>` in the user's own `~/.m2/settings.xml`, which every
 * project and command-line build reads, so it works without a project open.
 * Opening the page only reads; the file is written when the user saves, based
 * on the revision that was read, and the page shows what was read back.
 */
export function MavenUserSettingsGroup({
  projectOpen,
  onSaved,
  dependencies = defaultDependencies,
}: {
  projectOpen: boolean;
  onSaved?: () => void;
  dependencies?: MavenUserSettingsDependencies;
}) {
  const { t } = useTranslation();
  const [state, setState] = useState<LoadState>({ status: "loading" });
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  const load = useCallback(
    async (keepDraft: boolean) => {
      try {
        const settings = await dependencies.read();
        setState({ status: "loaded", settings });
        if (!keepDraft) setDraft(baselineOf(settings));
      } catch (error) {
        setState({ status: "failed", error: errorMessage(error) });
      }
    },
    [dependencies],
  );

  useEffect(() => {
    void load(false);
  }, [load]);

  if (state.status === "loading") {
    return (
      <p className="ui-text-sm text-subtle-foreground" role="status">
        {t("maven.userSettings.loading")}
      </p>
    );
  }
  if (state.status === "failed") {
    const key = errorKey(state.error);
    return (
      <p className="ui-text-sm text-destructive" role="alert">
        {key ? t(key) : t("maven.userSettings.readFailed", { error: state.error })}
      </p>
    );
  }

  const { settings } = state;
  const invalid = settings.status === "invalid";
  const dirty = draft.trim() !== baselineOf(settings);
  const saveErrorKey = saveError ? errorKey(saveError) : null;
  const conflict = saveErrorKey === MAVEN_USER_SETTINGS_ERRORS.mavenUserSettingsChanged;

  const save = async () => {
    setSaving(true);
    setSaveError(null);
    setSaved(false);
    try {
      const written = await dependencies.write(draft.trim(), settings.revision);
      setState({ status: "loaded", settings: written });
      setDraft(baselineOf(written));
      setSaved(true);
      onSaved?.();
    } catch (error) {
      setSaveError(errorMessage(error));
    } finally {
      setSaving(false);
    }
  };

  const reload = async () => {
    setSaveError(null);
    await load(true);
  };

  return (
    <>
      <p className="ui-text-caption leading-relaxed text-subtle-foreground">
        {t("maven.userSettings.description")}
      </p>
      <p className="break-all font-mono ui-text-caption text-subtle-foreground">
        {settings.path}
        {" · "}
        {settings.status === "missing"
          ? t("maven.userSettings.missing")
          : invalid
            ? t("maven.userSettings.invalid")
            : settings.localRepository === null
              ? t("maven.userSettings.notDeclared")
              : t("maven.userSettings.declared")}
      </p>
      <label className="flex flex-col gap-1.5 ui-text-sm text-foreground">
        {t("maven.localRepository")}
        <div className="flex gap-2">
          <Input
            className="min-w-0 flex-1 font-mono"
            value={draft}
            disabled={invalid || saving}
            onChange={(event) => {
              setDraft(event.target.value);
              setSaved(false);
            }}
          />
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            disabled={invalid || saving}
            title={t("ui.browse")}
            aria-label={t("ui.browse")}
            onClick={() =>
              void dependencies.browse().then((selected) => {
                if (selected) setDraft(selected);
              })
            }
          >
            <FolderIcon />
          </Button>
        </div>
        {settings.localRepository === null && !dirty ? (
          <span className="ui-text-caption text-subtle-foreground">
            {t("maven.userSettings.defaultValue")}
          </span>
        ) : null}
      </label>
      {saveError ? (
        <div className="flex flex-col gap-1 ui-text-sm text-destructive" role="alert">
          <p>
            {saveErrorKey
              ? t(saveErrorKey)
              : t("maven.userSettings.saveFailed", { error: saveError })}
          </p>
          {conflict ? (
            <Button variant="ghost" size="sm" className="self-start" onClick={() => void reload()}>
              {t("maven.userSettings.reload")}
            </Button>
          ) : null}
        </div>
      ) : null}
      {saved && projectOpen ? (
        <p className="ui-text-sm text-subtle-foreground" role="status">
          {t("maven.userSettings.reloadProject")}
        </p>
      ) : null}
      <div className="flex justify-end">
        <Button
          variant="accent"
          size="sm"
          disabled={invalid || saving || !dirty || !draft.trim()}
          onClick={() => void save()}
        >
          {t("maven.userSettings.save")}
        </Button>
      </div>
    </>
  );
}
