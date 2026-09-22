import { useEffect } from "react";
import { useShallow } from "zustand/react/shallow";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { runOptionsFor, useRunStore } from "@/features/run/stores/run.store";
import { mavenLaunchContextForWorkspace, useMavenStore } from "@/features/maven/stores/maven.store";
import { RunConfigurationEditor } from "@/features/run/components/run-configuration-editor";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ensureRunSettingsProject } from "../services/run-settings-project";

export function RunConfigurationSettings() {
  const { t } = useTranslation();
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const state = useRunStore(
    useShallow((state) => ({
      root: state.root,
      status: state.status,
      isLoading: state.isLoading,
      isGenerating: state.isGenerating,
      configurations: state.configurations,
      editingConfigurationId: state.editingConfigurationId,
      saveError: state.saveError,
      invalidMessage: state.invalidMessage,
      generationNotice: state.generationNotice,
      diagnostics: state.diagnostics,
      discoveredJava: state.discoveredJava,
      discoveredMaven: state.discoveredMaven,
      discoveredRuntimes: state.discoveredRuntimes,
      globalToolchain: state.globalToolchain,
      actions: state.actions,
    })),
  );
  const { actions } = state;
  // A launch falls back to Maven's explicit selection; show the same result.
  const mavenSelection = useMavenStore(
    useShallow((maven) =>
      maven.root === root && maven.project
        ? { mavenExecutablePath: maven.mavenExecutablePath, javaHomePath: maven.javaHomePath }
        : null,
    ),
  );
  useEffect(() => {
    // `actions` changes with the active workspace's Run store.
    if (!root) return;
    void ensureRunSettingsProject(useRunStore, root);
    // Launches load Maven's selection before resolving; do the same for display.
    void mavenLaunchContextForWorkspace(root).catch(() => undefined);
  }, [root, actions]);

  if (!root) return <p>{t("settings.project.openProject")}</p>;
  if (state.root !== root || state.isLoading) return <p>{t("settings.project.loading")}</p>;
  const configuration = state.configurations.find(
    (entry) => entry.id === state.editingConfigurationId,
  );
  if (configuration) {
    return (
      <div className="space-y-4">
        <h3 className="font-medium">{configuration.name}</h3>
        <RunConfigurationEditor
          key={`${root}:${configuration.id}`}
          root={root}
          configuration={configuration}
          diagnostics={state.diagnostics}
          mavenSelection={mavenSelection}
          options={runOptionsFor(configuration)}
          saveError={state.saveError}
          discoveredJava={state.discoveredJava}
          discoveredMaven={state.discoveredMaven}
          discoveredRuntimes={state.discoveredRuntimes}
          globalToolchain={state.globalToolchain}
          onClose={() => actions.editConfiguration(null)}
          onSave={(options, toolchain, scope) =>
            actions.saveEditorChanges(configuration, options, toolchain, scope)
          }
        />
      </div>
    );
  }
  return (
    <div className="space-y-3">
      <p className="text-subtle-foreground ui-text-sm">{t("settings.run.description")}</p>
      {state.invalidMessage && (
        <p role="alert" className="text-destructive">
          {state.invalidMessage}
        </p>
      )}
      {state.saveError && (
        <p role="alert" className="text-destructive">
          {state.saveError}
        </p>
      )}
      {state.generationNotice?.startsWith("generated:") && (
        <p role="status">
          {t("run.generatedEntries", { count: state.generationNotice.slice("generated:".length) })}
        </p>
      )}
      <Button disabled={state.isGenerating} onClick={() => void actions.generate(root)}>
        {t(state.isGenerating ? "settings.project.loading" : "run.identifyAgain")}
      </Button>
      {state.configurations.map((entry) => (
        <Button
          key={entry.id}
          variant="ghost"
          className="flex w-full justify-between"
          disabled={state.status !== "ready" || state.isGenerating}
          onClick={() => actions.editConfiguration(entry.id)}
        >
          <span className="truncate">{entry.name}</span>
          <span>{t("ui.edit")}</span>
        </Button>
      ))}
    </div>
  );
}
