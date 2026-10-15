import { useEffect, useState } from "react";
import { useDefaultLayout } from "react-resizable-panels";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Dialog, { showConfirmDialog } from "@/ui/dialog";
import Input from "@/ui/input";
import { CaretDownIcon, CaretRightIcon, GearIcon, MagnifyingGlassIcon } from "@/ui/icons";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/ui/resizable";
import { cn } from "@/utils/cn";
import {
  categoryFromRequestedTab,
  filterSettingsCategories,
  settingsCategories,
  settingsGroupForCategory,
  settingsGroups,
} from "../lib/settings-navigation";
import { SettingsPanel, type SettingsCategory } from "./settings-panels";

interface SettingsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

// 234px sidebar + 500px content + separator, modal border and viewport gutters.
const COMPACT_SETTINGS_QUERY = "(max-width: 768px)";

// Note: 分层与即时保存边界见 .agents/notes/implemented/feature/2026-10-08-windows-settings-hierarchy.md
const SettingsDialog = ({ isOpen, onClose }: SettingsDialogProps) => {
  const { t } = useTranslation();
  const settingsInitialTab = useUIState((state) => state.settingsInitialTab);
  const settingsTabRequest = useUIState((state) => state.settingsTabRequest);
  const [activeCategory, setActiveCategory] = useState<SettingsCategory>("general");
  const [visitedCategories, setVisitedCategories] = useState<SettingsCategory[]>([]);
  const [compact, setCompact] = useState(() => window.matchMedia(COMPACT_SETTINGS_QUERY).matches);
  const [query, setQuery] = useState("");
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set(["appearance"]));
  const resetToDefaults = useSettingsStore((state) => state.actions.resetToDefaults);
  const { defaultLayout, onLayoutChanged } = useDefaultLayout({
    id: "lithe.settings.categorySidebar",
    panelIds: ["categories", "content"],
    onlySaveAfterUserInteractions: true,
    storage: window.localStorage,
  });

  const selectCategory = (category: SettingsCategory) => {
    setActiveCategory(category);
    setVisitedCategories((previous) =>
      previous.includes(category) ? previous : [...previous, category],
    );
    const group = settingsGroupForCategory(category);
    if (group) setExpandedGroups((previous) => new Set(previous).add(group.id));
  };

  useEffect(() => {
    if (!isOpen) {
      setVisitedCategories([]);
      return;
    }
    setQuery("");
    selectCategory(categoryFromRequestedTab(settingsInitialTab));
  }, [isOpen, settingsInitialTab, settingsTabRequest]);

  useEffect(() => {
    if (!isOpen) return;
    const media = window.matchMedia(COMPACT_SETTINGS_QUERY);
    const update = () => setCompact(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, [isOpen]);

  const filteredCategories = filterSettingsCategories(query, t);
  const visibleCategoryIds = filteredCategories.map(({ id }) => id).join(",");
  useEffect(() => {
    if (
      isOpen &&
      query.trim() &&
      filteredCategories.length &&
      !filteredCategories.some(({ id }) => id === activeCategory)
    ) {
      selectCategory(filteredCategories[0].id);
    }
  }, [isOpen, query, activeCategory, visibleCategoryIds]);

  if (!isOpen) return null;
  const activeItem = settingsCategories.find(({ id }) => id === activeCategory)!;
  const activeGroup = settingsGroupForCategory(activeCategory);
  const searching = query.trim().length > 0;
  const categoryButton = (id: SettingsCategory, nested = false) => {
    const item = filteredCategories.find((category) => category.id === id);
    if (!item) return null;
    return (
      <li key={id}>
        <button
          type="button"
          data-settings-category={id}
          aria-current={id === activeCategory ? "page" : undefined}
          onClick={() => selectCategory(id)}
          className={cn(
            "flex h-6 w-full items-center truncate pr-2 text-left ui-text-sm outline-none hover:bg-accent/40 focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring",
            nested ? "pl-10 font-normal" : "pl-6 font-semibold",
            id === activeCategory && "bg-primary/15 text-foreground hover:bg-primary/15",
          )}
        >
          <span className="truncate">{t(item.labelKey)}</span>
        </button>
      </li>
    );
  };
  const groupNode = (group: (typeof settingsGroups)[number]) => {
    const children = group.categories.filter((id) =>
      filteredCategories.some((category) => category.id === id),
    );
    if (!children.length) return null;
    const expanded = searching || expandedGroups.has(group.id);
    return (
      <li key={group.id}>
        <button
          type="button"
          aria-expanded={expanded}
          aria-controls={`settings-group-${group.id}`}
          onClick={() =>
            setExpandedGroups((previous) => {
              const next = new Set(previous);
              if (next.has(group.id)) next.delete(group.id);
              else next.add(group.id);
              return next;
            })
          }
          className="flex h-6 w-full items-center gap-1 px-2 text-left font-semibold ui-text-sm outline-none hover:bg-accent/40 focus-visible:ring-1 focus-visible:ring-inset focus-visible:ring-ring"
        >
          {expanded ? (
            <CaretDownIcon className="size-3 shrink-0" />
          ) : (
            <CaretRightIcon className="size-3 shrink-0" />
          )}
          <span className="truncate">{t(group.labelKey)}</span>
        </button>
        <ul id={`settings-group-${group.id}`} hidden={!expanded}>
          {children.map((id) => categoryButton(id, true))}
        </ul>
      </li>
    );
  };

  return (
    <Dialog
      onClose={onClose}
      title={t("workbench.settings")}
      icon={GearIcon}
      footer={
        <div className="flex w-full items-center justify-between">
          <Button
            size="sm"
            onClick={async () => {
              if (
                await showConfirmDialog(t("settings.mac.restoreDefaultsConfirm"), {
                  title: t("settings.mac.restoreDefaults"),
                })
              ) {
                await resetToDefaults();
              }
            }}
          >
            {t("settings.mac.restoreDefaults")}
          </Button>
          <Button size="sm" className="min-w-18" onClick={onClose}>
            {t("ui.close")}
          </Button>
        </div>
      }
      classNames={{
        backdrop: "bg-black/55",
        modal:
          "h-[700px] w-[900px] max-h-[calc(100vh-32px)] max-w-[calc(100vw-32px)] border-border bg-background",
        header: "h-8 border-border bg-background px-3 py-0",
        content: "flex h-full p-0",
        footer: "h-13 border-t border-border bg-background px-4 py-0",
      }}
    >
      <ResizablePanelGroup
        orientation="horizontal"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
      >
        <ResizablePanel id="categories" defaultSize="234px" minSize={compact ? "180px" : "234px"}>
          <div className="flex h-full min-h-0 flex-col bg-background pt-3">
            <div className="mb-3 px-2">
              <Input
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                aria-label={t("settings.search")}
                placeholder={t("settings.search")}
                leftIcon={MagnifyingGlassIcon}
                onKeyDown={(event) => {
                  if (event.key === "Escape" && query) {
                    event.preventDefault();
                    event.stopPropagation();
                    setQuery("");
                  }
                }}
              />
            </div>
            <nav
              className="min-h-0 flex-1 overflow-y-auto pb-3"
              aria-label={t("settings.mac.categories")}
            >
              <ul>
                {groupNode(settingsGroups[0])}
                {(["keyboard", "editor", "plugins", "mcp"] as const).map((id) =>
                  categoryButton(id),
                )}
                {settingsGroups.slice(1).map(groupNode)}
              </ul>
              {!filteredCategories.length && (
                <p role="status" className="px-3 py-2 ui-text-sm text-subtle-foreground">
                  {t("settings.noResults")}
                </p>
              )}
            </nav>
          </div>
        </ResizablePanel>
        <ResizableHandle aria-label={t("settings.resizeCategories")} />
        <ResizablePanel id="content" minSize="500px">
          <div className="flex h-full min-h-0 min-w-0 flex-col bg-background">
            {activeCategory !== "plugins" && (
              <div
                data-settings-breadcrumb=""
                className="flex h-12 shrink-0 items-center gap-2 px-4 font-semibold ui-text-sm"
              >
                {activeGroup && (
                  <>
                    <span>{t(activeGroup.labelKey)}</span>
                    <CaretRightIcon className="size-3 text-subtle-foreground" />
                  </>
                )}
                <h2>{t(activeItem.labelKey)}</h2>
              </div>
            )}
            {!filteredCategories.length && (
              <p role="status" className="m-auto p-4 ui-text-sm text-subtle-foreground">
                {t("settings.noResults")}
              </p>
            )}
            {/* Mount pages on first visit; retain drafts until the dialog closes. */}
            {visitedCategories.map((category) => (
              <div
                key={category}
                hidden={category !== activeCategory || !filteredCategories.length}
                data-settings-content={category}
                className={cn(
                  "@container/settings min-h-0 min-w-0 flex-1",
                  category === "plugins" ? "overflow-hidden" : "overflow-y-auto px-4 pt-4 pb-5",
                )}
              >
                <SettingsPanel category={category} onClose={onClose} />
              </div>
            ))}
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </Dialog>
  );
};

export default SettingsDialog;
