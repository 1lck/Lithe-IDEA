import { useEffect, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useRunStore } from "@/features/run/stores/run.store";
import { mavenLaunchContextForWorkspace, useMavenStore } from "@/features/maven/stores/maven.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import type { MavenSettings } from "@/features/maven/types/maven.types";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { FolderIcon } from "@/ui/icons";
import {
  loadProjectEnvironment,
  ProjectEnvironmentSaveError,
  saveProjectEnvironmentSettings,
} from "../services/project-environment";

type Environment = Awaited<ReturnType<typeof loadProjectEnvironment>>;

export function ProjectEnvironmentSettings() {
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const workspaceId = useActiveWorkspaceId();
  const { t } = useTranslation();
  if (!root) return <p>{t("settings.project.openProject")}</p>;
  return (
    <ProjectEnvironmentForm key={`${workspaceId}:${root}`} root={root} workspaceId={workspaceId} />
  );
}

function ProjectEnvironmentForm({ root, workspaceId }: { root: string; workspaceId: string }) {
  const { t } = useTranslation();
  const [environment, setEnvironment] = useState<Environment | null>(null);
  const [maven, setMaven] = useState<MavenSettings | null>(null);
  const [busy, setBusy] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const mounted = useRef(true);
  const revision = useRef(0);
  const saveRevision = useRef(0);

  const load = async () => {
    const current = ++revision.current;
    setBusy(true);
    setError(null);
    try {
      const next = await loadProjectEnvironment(root);
      if (!mounted.current || current !== revision.current) return;
      await mavenLaunchContextForWorkspace(root, [], workspaceId);
      if (!mounted.current || current !== revision.current) return;
      const state = useMavenStore.getStore(workspaceId).getState();
      const settings =
        state.root === root && state.project
          ? {
              settingsPath: state.settingsPath,
              localRepositoryPath: state.localRepositoryPath,
              mavenExecutablePath: state.mavenExecutablePath,
              javaHomePath: state.javaHomePath,
            }
          : null;
      setMaven(settings);
      // Maven's existing explicit project selection wins over the Run fallback.
      // Empty automatic paths stay empty instead of becoming saved discoveries.
      setEnvironment({
        ...next,
        toolchain: {
          ...next.toolchain,
          mavenExecutablePath: settings?.mavenExecutablePath || next.toolchain.mavenExecutablePath,
          mavenJavaHomePath: settings?.javaHomePath || next.toolchain.mavenJavaHomePath,
        },
      });
    } catch (cause) {
      if (mounted.current && current === revision.current) setError(String(cause));
    } finally {
      if (mounted.current && current === revision.current) setBusy(false);
    }
  };

  useEffect(() => {
    mounted.current = true;
    void load();
    return () => {
      mounted.current = false;
      revision.current += 1;
    };
  }, [root, workspaceId]);

  const save = async () => {
    if (!environment || busy) return;
    const current = ++saveRevision.current;
    setBusy(true);
    setSaved(false);
    setError(null);
    let runRefresh: Promise<string | null>;
    try {
      ({ runRefresh } = await saveProjectEnvironmentSettings(root, environment.toolchain, {
        maven: maven ? { settings: maven, store: useMavenStore.getStore(workspaceId) } : null,
        run: useRunStore.getStore(workspaceId),
      }));
    } catch (cause) {
      if (mounted.current) {
        const written = cause instanceof ProjectEnvironmentSaveError && cause.defaultsWritten;
        setError(
          `${written ? t("settings.project.savedReloadFailed") : ""}${String(cause instanceof ProjectEnvironmentSaveError ? cause.message : cause)}`,
        );
        setBusy(false);
      }
      return;
    }
    if (mounted.current) {
      setSaved(true);
      setBusy(false);
    }
    // Run may still be identifying the project; report its refresh when it ends
    // unless a newer save has replaced this one.
    const failure = await runRefresh;
    if (failure === null || !mounted.current || current !== saveRevision.current) return;
    setSaved(false);
    setError(
      `${t("settings.project.savedReloadFailed")}${failure || t("settings.project.reloadFailed")}`,
    );
  };

  const fields = environment
    ? [
        {
          key: "javaHomePath" as const,
          label: t("run.jdkHome"),
          automatic: t("run.toolchainAuto"),
          candidates: environment.discovered.java.map((runtime) => ({
            path: runtime.homePath,
            version: runtime.version,
          })),
        },
        {
          key: "mavenExecutablePath" as const,
          label: t("run.mavenExecutable"),
          automatic: t("settings.project.mavenAutomatic"),
          candidates: environment.discovered.maven.map((runtime) => ({
            path: runtime.executablePath,
            version: runtime.version,
          })),
        },
        {
          key: "mavenJavaHomePath" as const,
          label: t("run.mavenJdkHome"),
          automatic: t("settings.project.useProjectJdk"),
          candidates: environment.discovered.java.map((runtime) => ({
            path: runtime.homePath,
            version: runtime.version,
          })),
        },
      ]
    : [];

  const choose = async (directory: boolean, apply: (value: string) => void) => {
    try {
      const selected = await open({ directory, multiple: false });
      if (mounted.current && typeof selected === "string") {
        apply(selected);
        setSaved(false);
      }
    } catch (cause) {
      if (mounted.current) setError(String(cause));
    }
  };

  return (
    <div className="space-y-4">
      <p className="break-all font-mono ui-text-sm">{root}</p>
      <p className="text-subtle-foreground ui-text-sm">{t("settings.project.scope")}</p>
      {environment?.discoveryError && (
        <p role="alert" className="text-destructive ui-text-sm">
          {environment.discoveryError}
        </p>
      )}
      <fieldset disabled={busy} className="space-y-4 disabled:opacity-60">
        {environment &&
          fields.map(({ key, label, automatic, candidates }) => (
            <label key={key} className="block space-y-1.5">
              <span className="font-medium ui-text-sm">{label}</span>
              <div className="flex gap-2">
                <Input
                  value={environment.toolchain[key]}
                  list={`project-${key}`}
                  placeholder={automatic}
                  onChange={(event) => {
                    setEnvironment({
                      ...environment,
                      toolchain: { ...environment.toolchain, [key]: event.target.value },
                    });
                    setSaved(false);
                  }}
                />
                <datalist id={`project-${key}`}>
                  {candidates.map(({ path, version }) => (
                    <option key={path} value={path}>
                      {version || path}
                    </option>
                  ))}
                </datalist>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={`${t("ui.browse")} ${label}`}
                  onClick={() =>
                    void choose(true, (value) =>
                      setEnvironment(
                        (current) =>
                          current && {
                            ...current,
                            toolchain: { ...current.toolchain, [key]: value },
                          },
                      ),
                    )
                  }
                >
                  <FolderIcon />
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setEnvironment({
                      ...environment,
                      toolchain: { ...environment.toolchain, [key]: "" },
                    });
                    setSaved(false);
                  }}
                >
                  {t("ui.clear")}
                </Button>
              </div>
              <p className="text-subtle-foreground ui-text-caption">{automatic}</p>
              {candidates.length > 0 && (
                <p className="break-all text-subtle-foreground ui-text-caption">
                  {t("settings.project.detected")}:{" "}
                  {candidates
                    .map(({ path, version }) => `${path}${version ? ` (${version})` : ""}`)
                    .join("; ")}
                </p>
              )}
            </label>
          ))}
        {maven &&
          (["settingsPath", "localRepositoryPath"] as const).map((key) => (
            <label key={key} className="block space-y-1.5">
              <span>{key === "settingsPath" ? "settings.xml" : t("maven.localRepository")}</span>
              <div className="flex gap-2">
                <Input
                  value={maven[key]}
                  placeholder={t("maven.automatic")}
                  onChange={(event) => {
                    setMaven({ ...maven, [key]: event.target.value });
                    setSaved(false);
                  }}
                />
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={t("ui.browse")}
                  onClick={() =>
                    void choose(key !== "settingsPath", (value) =>
                      setMaven((current) => current && { ...current, [key]: value }),
                    )
                  }
                >
                  <FolderIcon />
                </Button>
              </div>
            </label>
          ))}
      </fieldset>
      {error && (
        <p role="alert" className="text-destructive ui-text-sm">
          {error}
        </p>
      )}
      {saved && <p role="status">{t("settings.project.saved")}</p>}
      <div className="flex justify-end gap-2">
        <Button
          variant="ghost"
          disabled={busy}
          onClick={() => {
            setSaved(false);
            void load();
          }}
        >
          {t("settings.project.refresh")}
        </Button>
        <Button disabled={busy || !environment} onClick={() => void save()}>
          {busy ? t("settings.project.loading") : t("ui.save")}
        </Button>
      </div>
    </div>
  );
}
