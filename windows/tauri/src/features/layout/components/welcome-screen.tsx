import { getVersion } from "@tauri-apps/api/app";
import { useEffect, useMemo, useState } from "react";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useRecentFoldersStore } from "@/features/file-system/stores/recent-folders.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  ArrowClockwiseIcon,
  FolderIcon,
  FolderOpenIcon,
  GearIcon,
  GitBranchIcon,
  MagnifyingGlassIcon,
  XIcon,
} from "@/ui/icons";

const projectColors = [
  "bg-emerald-500/80",
  "bg-blue-500/85",
  "bg-orange-500/85",
  "bg-cyan-500/80",
  "bg-violet-500/80",
];

function projectInitials(name: string) {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const initials = words
    .slice(0, 2)
    .map((word) => word[0])
    .join("");
  return (initials || "LI").toUpperCase();
}

function colorForProject(path: string) {
  const hash = Array.from(path).reduce((value, character) => value + character.charCodeAt(0), 0);
  return projectColors[hash % projectColors.length];
}

export function WelcomeScreen() {
  const { t } = useTranslation();
  const [query, setQuery] = useState("");
  const [appVersion, setAppVersion] = useState("");
  const recentFolders = useRecentFoldersStore((state) => state.recentFolders);
  const openRecentFolder = useRecentFoldersStore((state) => state.actions.openRecentFolder);
  const removeFromRecents = useRecentFoldersStore((state) => state.actions.removeFromRecents);
  const handleOpenFolder = useFileSystemStore((state) => state.handleOpenFolder);
  const setIsProjectPickerVisible = useUIState((state) => state.setIsProjectPickerVisible);
  const openSettingsDialog = useUIState((state) => state.openSettingsDialog);

  useEffect(() => {
    void getVersion()
      .then(setAppVersion)
      .catch(() => setAppVersion(""));
  }, []);

  const visibleRecentFolders = useMemo(() => {
    const normalizedQuery = query.trim().toLocaleLowerCase();
    const sortedFolders = [...recentFolders].sort(
      (left, right) => (right.lastOpenedAt ?? 0) - (left.lastOpenedAt ?? 0),
    );

    if (!normalizedQuery) return sortedFolders;
    return sortedFolders.filter(
      (folder) =>
        folder.name.toLocaleLowerCase().includes(normalizedQuery) ||
        folder.path.toLocaleLowerCase().includes(normalizedQuery),
    );
  }, [query, recentFolders]);

  return (
    <main className="flex min-h-0 flex-1 overflow-hidden bg-background">
      <aside className="flex w-60 shrink-0 flex-col border-border border-r bg-surface px-3 pb-3">
        <div className="flex items-center gap-[11px] px-2 pt-7 pb-[30px]">
          <img src="/logo.png" alt="" className="size-[42px] rounded-xl" />
          <div className="min-w-0">
            <div className="truncate text-[18px] leading-tight font-semibold text-foreground">
              Lithe
            </div>
            <div className="mt-0.5 ui-text-caption text-subtle-foreground">
              {appVersion ? `${appVersion} · Windows` : "Windows"}
            </div>
            <button
              type="button"
              className="mt-0.5 inline-flex items-center gap-1.5 whitespace-nowrap ui-text-caption font-medium text-subtle-foreground hover:text-foreground"
              onClick={() => openSettingsDialog("general")}
            >
              <ArrowClockwiseIcon className="size-3" />
              {t("welcome.checkUpdates")}
            </button>
          </div>
        </div>

        <div className="mx-0.5 flex h-9 items-center gap-[9px] rounded-md bg-primary/55 px-3.5 font-medium text-white">
          <FolderIcon className="size-4" />
          <span>{t("welcome.projects")}</span>
        </div>

        <div className="mt-auto">
          <Button
            type="button"
            variant="ghost"
            className="mx-0.5 mb-0.5 h-9 w-auto self-stretch justify-start gap-[9px] px-3.5 text-subtle-foreground"
            onClick={() => openSettingsDialog("general")}
          >
            <GearIcon className="size-4" />
            {t("workbench.settings")}
          </Button>
        </div>
      </aside>

      <section className="flex min-w-0 flex-1 flex-col px-5 pt-10">
        <h1 className="text-center text-[20px] leading-tight font-semibold text-foreground">
          {t("welcome.title")}
        </h1>

        <div className="mt-8 flex h-16 items-center gap-3 border-border border-b px-0">
          <label className="flex h-9 w-full max-w-75 items-center gap-2 rounded-md border border-input bg-background px-2.5 text-subtle-foreground focus-within:border-primary">
            <MagnifyingGlassIcon className="size-4" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-subtle-foreground"
              placeholder={t("welcome.searchProjects")}
              aria-label={t("welcome.searchProjects")}
            />
          </label>
          <div className="ml-auto flex items-center gap-2.5">
            <Button
              type="button"
              variant="default"
              size="sm"
              className="min-w-17"
              onClick={() => setIsProjectPickerVisible(true)}
            >
              <GitBranchIcon className="size-4" />
              {t("welcome.clone")}
            </Button>
            <Button
              type="button"
              variant="accent"
              size="sm"
              className="min-w-17"
              onClick={() => void handleOpenFolder()}
            >
              <FolderOpenIcon className="size-4" />
              {t("welcome.open")}
            </Button>
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto py-2">
          {visibleRecentFolders.length > 0 ? (
            <div className="flex flex-col gap-0.5">
              {visibleRecentFolders.map((folder) => (
                <div
                  key={folder.path}
                  className="group flex h-13 items-center gap-3 rounded-md px-2 hover:bg-accent/65"
                >
                  <div
                    className={`flex size-8.5 shrink-0 items-center justify-center rounded-lg text-xs font-semibold text-white ${
                      folder.missing ? "bg-muted-foreground/25" : colorForProject(folder.path)
                    }`}
                  >
                    {projectInitials(folder.name)}
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
                      <span className="mt-0.5 block truncate ui-text-sm text-subtle-foreground">
                        {folder.path}
                      </span>
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
            <div className="flex h-full min-h-48 flex-col items-center justify-center gap-2 text-center">
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
