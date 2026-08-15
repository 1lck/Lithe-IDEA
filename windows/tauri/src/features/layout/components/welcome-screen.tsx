import { useMemo, useState } from "react";
import { useRecentFoldersStore } from "@/features/file-system/stores/recent-folders.store";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  FolderOpenIcon,
  GitBranchIcon,
  GearIcon,
  MagnifyingGlassIcon,
  XIcon,
} from "@/ui/icons";

export function WelcomeScreen() {
  const { t } = useTranslation();
  const [query, setQuery] = useState("");
  const recentFolders = useRecentFoldersStore((state) => state.recentFolders);
  const openRecentFolder = useRecentFoldersStore((state) => state.actions.openRecentFolder);
  const removeFromRecents = useRecentFoldersStore((state) => state.actions.removeFromRecents);
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);
  const setIsSettingsDialogVisible = useUIState((state) => state.setIsSettingsDialogVisible);

  const visibleRecentFolders = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    const sortedFolders = [...recentFolders].sort(
      (left, right) => (right.lastOpenedAt ?? 0) - (left.lastOpenedAt ?? 0),
    );

    if (!normalizedQuery) return sortedFolders;

    return sortedFolders.filter((folder) => {
      return (
        folder.name.toLowerCase().includes(normalizedQuery) ||
        folder.path.toLowerCase().includes(normalizedQuery)
      );
    });
  }, [query, recentFolders]);

  return (
    <main className="flex min-h-0 flex-1 overflow-hidden bg-background">
      <aside className="flex w-64 shrink-0 flex-col border-border/70 border-r bg-surface/45 px-4 py-6">
        <div className="flex items-center gap-3 px-2">
          <div className="flex size-10 items-center justify-center rounded-xl bg-primary text-primary-foreground">
            <span className="text-lg font-semibold">L</span>
          </div>
          <div>
            <div className="ui-text-base font-semibold text-foreground">Lithe</div>
            <div className="ui-text-sm text-subtle-foreground">Windows</div>
          </div>
        </div>

        <div className="mt-8 rounded-lg bg-selected/70 px-3 py-2 ui-text-sm font-medium text-foreground">
          {t("welcome.projects")}
        </div>

        <div className="mt-auto">
          <Button
            type="button"
            variant="ghost"
            className="w-full justify-start gap-2 px-3"
            onClick={() => setIsSettingsDialogVisible(true)}
          >
            <GearIcon />
            {t("workbench.settings")}
          </Button>
        </div>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col px-8 py-8">
        <h1 className="text-center ui-text-lg font-semibold text-foreground">
          {t("welcome.title")}
        </h1>

        <div className="mx-auto mt-8 flex w-full max-w-4xl items-center gap-3 border-border/70 border-b pb-5">
          <label className="flex h-9 min-w-0 flex-1 items-center gap-2 rounded-lg border border-input bg-surface px-3 text-subtle-foreground focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20">
            <MagnifyingGlassIcon className="size-4" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-subtle-foreground"
              placeholder={t("welcome.searchProjects")}
              aria-label={t("welcome.searchProjects")}
            />
          </label>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => setIsProjectPickerVisible(true)}
          >
            <GitBranchIcon />
            {t("welcome.clone")}
          </Button>
          <Button type="button" size="sm" onClick={() => void handleOpenFolder()}>
            <FolderOpenIcon />
            {t("welcome.open")}
          </Button>
        </div>

        <div className="mx-auto mt-5 w-full max-w-4xl overflow-y-auto">
          {visibleRecentFolders.length > 0 ? (
            <div className="flex flex-col gap-1">
              {visibleRecentFolders.map((folder) => (
                <div
                  key={folder.path}
                  className="group flex items-center gap-3 rounded-lg px-3 py-2.5 hover:bg-accent/65"
                >
                  <div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/15 text-primary">
                    <FolderOpenIcon className="size-4" />
                  </div>
                  <Button
                    type="button"
                    variant="ghost"
                    className="h-auto min-w-0 flex-1 justify-start p-0 text-left hover:bg-transparent"
                    disabled={folder.missing}
                    onClick={() => void openRecentFolder(folder.path)}
                  >
                    <span className="min-w-0">
                      <span className="block truncate ui-text-sm font-medium text-foreground">
                        {folder.name}
                      </span>
                      <span className="block truncate ui-text-sm text-subtle-foreground">{folder.path}</span>
                    </span>
                  </Button>
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon-xs"
                    className="opacity-0 group-hover:opacity-100 focus-visible:opacity-100"
                    onClick={() => removeFromRecents(folder.path)}
                    aria-label={t("welcome.removeRecent", { name: folder.name })}
                  >
                    <XIcon />
                  </Button>
                </div>
              ))}
            </div>
          ) : (
            <div className="flex min-h-48 flex-col items-center justify-center gap-2 text-center">
              <FolderOpenIcon className="size-7 text-subtle-foreground" />
              <div className="ui-text-base font-medium text-foreground">
                {t("welcome.noRecentProjects")}
              </div>
              <p className="ui-text-sm text-subtle-foreground">{t("welcome.openFolderHint")}</p>
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
