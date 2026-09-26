import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useState, type ReactNode } from "react";
import { MavenDetectedValue } from "@/features/maven/components/maven-detected-value";
import type { MavenSettings } from "@/features/maven/types/maven.types";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { FolderIcon, TrashIcon } from "@/ui/icons";

const controlClassName =
  "h-8 rounded-md border border-input bg-background px-2.5 text-foreground outline-none focus:border-primary";

// The settings dialog renders each category from a self-contained panel; this
// group mirrors the container the sibling panels define.
function SettingsGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="overflow-clip rounded-md border border-border bg-surface/35">
      <h3 className="border-border border-b px-3 py-2 ui-text-sm font-medium text-subtle-foreground">
        {title}
      </h3>
      <div className="flex flex-col gap-3 p-3">{children}</div>
    </section>
  );
}

interface MavenField {
  field: keyof MavenSettings;
  label: string;
  /** Directories are picked as folders; settings.xml is picked as a file. */
  directory: boolean;
}

/**
 * The Maven page of the application settings. It edits the same project-scoped
 * configuration as the Maven tool window, so both surfaces always agree, and it
 * shows what automatic detection found on this machine.
 *
 * The settings dialog sits outside the workbench's workspace provider, so this
 * wrapper pins it to the active project tab — the same store the Maven tool
 * window uses.
 */
export function MavenSettingsPanel() {
  const projectTabId = useWorkspaceTabsStore(
    (state) => state.projectTabs.find((tab) => tab.isActive)?.id ?? null,
  );
  if (!projectTabId) return <MavenSettingsForm />;
  return (
    <WorkspaceStoreScopeContext.Provider value={projectTabId}>
      <MavenSettingsForm />
    </WorkspaceStoreScopeContext.Provider>
  );
}

function MavenSettingsForm() {
  const { t } = useTranslation();
  const project = useMavenStore((state) => state.project);
  const projectStatus = useMavenStore((state) => state.projectStatus);
  const settingsPath = useMavenStore((state) => state.settingsPath);
  const localRepositoryPath = useMavenStore((state) => state.localRepositoryPath);
  const mavenExecutablePath = useMavenStore((state) => state.mavenExecutablePath);
  const javaHomePath = useMavenStore((state) => state.javaHomePath);
  const configurationSaveError = useMavenStore((state) => state.configurationSaveError);
  const effectiveConfiguration = useMavenStore((state) => state.effectiveConfiguration);
  const effectiveConfigurationStatus = useMavenStore(
    (state) => state.effectiveConfigurationStatus,
  );
  const saveLocalConfiguration = useMavenStore((state) => state.actions.saveLocalConfiguration);
  const resolveEffectiveConfiguration = useMavenStore(
    (state) => state.actions.resolveEffectiveConfiguration,
  );

  useEffect(() => {
    void resolveEffectiveConfiguration();
  }, [project, resolveEffectiveConfiguration]);

  const saved: MavenSettings = {
    settingsPath,
    localRepositoryPath,
    mavenExecutablePath,
    javaHomePath,
  };
  const [draft, setDraft] = useState<MavenSettings>(saved);

  // The project scan finishes after this page can already be open, and the Maven
  // tool window edits the same values, so keep the draft on the saved state.
  useEffect(() => {
    setDraft({ settingsPath, localRepositoryPath, mavenExecutablePath, javaHomePath });
  }, [settingsPath, localRepositoryPath, mavenExecutablePath, javaHomePath]);

  const dirty = (Object.keys(saved) as Array<keyof MavenSettings>).some(
    (field) => draft[field] !== saved[field],
  );

  const fields: MavenField[] = [
    { field: "settingsPath", label: "settings.xml", directory: false },
    { field: "localRepositoryPath", label: t("maven.localRepository"), directory: true },
    { field: "mavenExecutablePath", label: t("maven.mavenExecutable"), directory: true },
    { field: "javaHomePath", label: t("maven.javaHome"), directory: true },
  ];

  const browse = async (field: keyof MavenSettings, directory: boolean) => {
    const selected = await open({
      directory,
      multiple: false,
      ...(directory ? {} : { filters: [{ name: "Maven settings", extensions: ["xml"] }] }),
    });
    if (typeof selected === "string") setDraft((current) => ({ ...current, [field]: selected }));
  };

  return (
    <SettingsGroup title={t("maven.settings")}>
      <p className="ui-text-caption leading-relaxed text-subtle-foreground">
        {t("maven.settingsDescription")}
      </p>
      {project ? null : (
        <p className="ui-text-sm text-subtle-foreground" role="status">
          {projectStatus === "loading" ? t("maven.scanning") : t("maven.notDetected")}
        </p>
      )}
      {fields.map(({ field, label, directory }) => (
        <label key={field} className="flex flex-col gap-1.5 ui-text-sm text-foreground">
          {label}
          <div className="flex gap-2">
            <input
              className={`${controlClassName} min-w-0 flex-1 font-mono`}
              value={draft[field]}
              placeholder={t("maven.automatic")}
              disabled={!project}
              onChange={(event) =>
                setDraft((current) => ({ ...current, [field]: event.target.value }))
              }
            />
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              disabled={!project}
              title={t("ui.clear")}
              aria-label={t("ui.clear")}
              onClick={() => setDraft((current) => ({ ...current, [field]: "" }))}
            >
              <TrashIcon />
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="icon-sm"
              disabled={!project}
              title={t("ui.browse")}
              aria-label={t("ui.browse")}
              onClick={() => void browse(field, directory)}
            >
              <FolderIcon />
            </Button>
          </div>
          <MavenDetectedValue
            field={field}
            value={draft[field]}
            effective={effectiveConfiguration}
            status={effectiveConfigurationStatus}
          />
        </label>
      ))}
      {configurationSaveError ? (
        <p className="ui-text-sm text-destructive" role="alert">
          {configurationSaveError}
        </p>
      ) : null}
      <div className="flex justify-end">
        <Button
          variant="accent"
          size="sm"
          disabled={!project || (!dirty && !configurationSaveError)}
          onClick={() => void saveLocalConfiguration(draft).catch(() => undefined)}
        >
          {t("settings.mac.apply")}
        </Button>
      </div>
    </SettingsGroup>
  );
}
