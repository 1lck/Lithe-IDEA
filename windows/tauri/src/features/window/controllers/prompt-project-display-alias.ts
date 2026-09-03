import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { createTranslator } from "@/i18n/locale";
import { showPromptDialog } from "@/ui/dialog";
import { useProjectStore } from "../stores/project.store";
import type { ProjectTab } from "../stores/workspace-tabs.store";
import { useWorkspaceTabsStore } from "../stores/workspace-tabs.store";
import { getProjectDisplayLabel } from "../utils/project-display-label";

export async function promptProjectDisplayAlias(project: ProjectTab): Promise<void> {
  const t = createTranslator(useSettingsStore.getState().settings.displayLanguage);
  const result = await showPromptDialog(t("titleProject.displayAliasPrompt"), {
    defaultValue: project.displayAlias ?? "",
    placeholder: project.path,
    title: t("titleProject.setDisplayAlias"),
  });

  if (result === null) {
    return;
  }

  const trimmedAlias = result.trim();
  useWorkspaceTabsStore
    .getState()
    .actions.setProjectDisplayAlias(
      project.id,
      trimmedAlias.length > 0 ? trimmedAlias : undefined,
    );

  const activeProject = useWorkspaceTabsStore.getState().actions.getActiveProjectTab();
  if (activeProject?.id !== project.id) {
    return;
  }

  const updatedProject = useWorkspaceTabsStore
    .getState()
    .projectTabs.find((projectTab) => projectTab.id === project.id);
  if (!updatedProject) {
    return;
  }

  useProjectStore.getState().actions.setProjectName(getProjectDisplayLabel(updatedProject));
}
