import { useEffect, useState } from "react";
import type { SettingsTab } from "@/features/window/stores/ui-state.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import {
  ArrowClockwiseIcon,
  CodeBlockIcon,
  DatabaseIcon,
  GearIcon,
  GearSixIcon,
  KeyboardIcon,
  MagicWandIcon,
  FileTextIcon,
  TerminalWindowIcon,
  type Icon,
} from "@/ui/icons";
import { MacSettingsPanel, type MacSettingsCategory } from "./macos-settings-panels";
import { showConfirmDialog } from "@/ui/dialog";

interface SettingsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

interface CategoryItem {
  id: MacSettingsCategory;
  labelKey: string;
  icon: Icon;
}

const categories: CategoryItem[] = [
  { id: "general", labelKey: "settings.tabs.general", icon: GearSixIcon },
  { id: "editor", labelKey: "settings.tabs.editor", icon: CodeBlockIcon },
  { id: "keyboard", labelKey: "settings.tabs.keyboard", icon: KeyboardIcon },
  { id: "terminal", labelKey: "settings.tabs.terminal", icon: TerminalWindowIcon },
  { id: "lsp", labelKey: "settings.tabs.lsp", icon: DatabaseIcon },
  { id: "ai", labelKey: "settings.tabs.aiCommit", icon: MagicWandIcon },
  { id: "logs", labelKey: "settings.tabs.logs", icon: FileTextIcon },
  { id: "updates", labelKey: "settings.tabs.updates", icon: ArrowClockwiseIcon },
];

function categoryFromRequestedTab(tab: SettingsTab | null): MacSettingsCategory {
  switch (tab) {
    case "editor":
    case "keyboard":
    case "terminal":
    case "ai":
    case "logs":
      return tab;
    case "language":
      return "lsp";
    default:
      return "general";
  }
}

const SettingsDialog = ({ isOpen, onClose }: SettingsDialogProps) => {
  const { t } = useTranslation();
  const settingsInitialTab = useUIState((state) => state.settingsInitialTab);
  const [activeCategory, setActiveCategory] = useState<MacSettingsCategory>("general");
  const resetToDefaults = useSettingsStore((state) => state.actions.resetToDefaults);

  useEffect(() => {
    if (!isOpen) return;
    setActiveCategory(categoryFromRequestedTab(settingsInitialTab));
  }, [isOpen, settingsInitialTab]);

  if (!isOpen) return null;

  const activeItem = categories.find((category) => category.id === activeCategory) ?? categories[0];

  return (
    <Dialog
      onClose={onClose}
      title={t("workbench.settings")}
      icon={GearIcon}
      footer={
        <div className="flex w-full items-center justify-between">
          <Button
            type="button"
            variant="ghost"
            className="text-subtle-foreground"
            onClick={async () => {
              const confirmed = await showConfirmDialog(
                t("settings.mac.restoreDefaultsConfirm"),
                { title: t("settings.mac.restoreDefaults") }
              );
              if (confirmed) {
                void resetToDefaults();
              }
            }}
          >
            {t("settings.mac.restoreDefaults")}
          </Button>
          <Button type="button" variant="accent" onClick={onClose}>
            {t("settings.mac.done")}
          </Button>
        </div>
      }
      classNames={{
        backdrop: "bg-black/55",
        modal:
          "h-[620px] w-[820px] max-h-[calc(100vh-32px)] max-w-[calc(100vw-32px)] border-border bg-background",
        header: "h-11 border-border border-b bg-surface px-3 py-0",
        content: "flex h-full p-0",
      }}
    >
      <div className="flex size-full min-h-0 min-w-0">
        <nav
          className="flex w-47.5 shrink-0 flex-col gap-0.5 border-border border-r bg-surface p-2"
          aria-label={t("settings.mac.categories")}
        >
          {categories.map((category) => {
            const CategoryIcon = category.icon;
            const selected = category.id === activeCategory;
            return (
              <button
                key={category.id}
                type="button"
                onClick={() => setActiveCategory(category.id)}
                className={`flex h-8 w-full items-center gap-2.5 rounded-sm px-2.5 text-left ui-text-sm transition-colors ${
                  selected
                    ? "bg-primary/65 font-medium text-white"
                    : "text-foreground hover:bg-accent"
                }`}
                aria-current={selected ? "page" : undefined}
              >
                <CategoryIcon className="size-4 shrink-0" />
                <span className="truncate">{t(category.labelKey)}</span>
              </button>
            );
          })}
        </nav>

        <section className="min-w-0 min-h-0 flex-1 overflow-y-auto bg-background p-6">
          <h2 className="mb-5 text-xl font-semibold text-foreground">{t(activeItem.labelKey)}</h2>
          <MacSettingsPanel category={activeCategory} onClose={onClose} />
        </section>
      </div>
    </Dialog>
  );
};

export default SettingsDialog;
