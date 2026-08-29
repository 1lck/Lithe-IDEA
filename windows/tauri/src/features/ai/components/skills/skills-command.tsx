import {
  CloudArrowDownIcon as CloudArrowDown,
  MagnifyingGlassIcon as Search,
  PencilSimpleIcon as PencilSimple,
  PlusIcon as Plus,
  TrashIcon as Trash,
} from "@/ui/icons";
import {
  useCallback,
  useDeferredValue,
  useEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
} from "react";
import {
  createSkillFromMarketplace,
  hasSkillLocalOverride,
  isMarketplaceSkillInstalled,
  loadMarketplaceSkills,
} from "@/features/ai/lib/skill-library";
import { fuzzyScore } from "@/features/global-search/utils/fuzzy-search";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import type { AIChatSkill, MarketplaceSkill } from "@/features/ai/types/skills.types";
import { Button } from "@/ui/button";
import Command, {
  CommandEmpty,
  CommandFooter,
  CommandFooterAction,
  CommandHeader,
  CommandHeaderAction,
  CommandInput,
  CommandItemBadge,
  CommandItemRow,
  CommandList,
} from "@/ui/command";
import Input from "@/ui/input";
import { ScrollArea } from "@/ui/scroll-area";
import Textarea from "@/ui/textarea";
import { ComposerAttachedPanel } from "../input/composer-attached-panel";

interface SkillsCommandProps {
  anchorRef?: RefObject<HTMLElement | null>;
  isOpen: boolean;
  onClose: () => void;
  onSelectSkill: (skill: AIChatSkill) => void;
  initialView?: SkillsView;
}

type SkillsView = "list" | "browse" | "editor";

function createSkillId() {
  return `skill-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
}

export function SkillsCommand({
  anchorRef,
  isOpen,
  onClose,
  onSelectSkill,
  initialView = "list",
}: SkillsCommandProps) {
  const { t } = useTranslation();
  const inputRef = useRef<HTMLInputElement>(null);
  const titleInputRef = useRef<HTMLInputElement>(null);
  const resultsRef = useRef<HTMLDivElement>(null);
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [view, setView] = useState<SkillsView>("list");
  const [editingSkillId, setEditingSkillId] = useState<string | null>(null);
  const [title, setTitle] = useState("");
  const [content, setContent] = useState("");
  const [marketplaceSkills, setMarketplaceSkills] = useState<MarketplaceSkill[]>([]);
  const [isLoadingMarketplace, setIsLoadingMarketplace] = useState(false);

  const skills = useSettingsStore((state) => state.settings.aiSkills);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  const filteredSkills = useMemo(() => {
    const normalizedQuery = deferredQuery.trim();
    const sortedSkills = [...skills].sort(
      (a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt),
    );

    if (!normalizedQuery) {
      return sortedSkills;
    }

    return sortedSkills
      .map((skill) => ({
        skill,
        score:
          fuzzyScore(skill.title, normalizedQuery) * 2 + fuzzyScore(skill.content, normalizedQuery),
      }))
      .filter((result) => result.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((result) => result.skill);
  }, [deferredQuery, skills]);

  const filteredMarketplaceSkills = useMemo(() => {
    const normalizedQuery = deferredQuery.trim();
    const sortedSkills = [...marketplaceSkills].sort((a, b) => a.title.localeCompare(b.title));

    if (!normalizedQuery) {
      return sortedSkills;
    }

    return sortedSkills
      .map((skill) => ({
        skill,
        score:
          fuzzyScore(skill.title, normalizedQuery) * 2 +
          fuzzyScore(skill.description, normalizedQuery) +
          fuzzyScore(skill.tags.join(" "), normalizedQuery),
      }))
      .filter((result) => result.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((result) => result.skill);
  }, [deferredQuery, marketplaceSkills]);

  const resetEditor = useCallback(() => {
    setEditingSkillId(null);
    setTitle("");
    setContent("");
  }, []);

  const openNewSkill = useCallback(() => {
    resetEditor();
    setView("editor");
    requestAnimationFrame(() => titleInputRef.current?.focus());
  }, [resetEditor]);

  const openBrowseSkills = useCallback(() => {
    setView("browse");
    requestAnimationFrame(() => inputRef.current?.focus());
  }, []);

  const openSkillEditor = useCallback((skill: AIChatSkill) => {
    setEditingSkillId(skill.id);
    setTitle(skill.title);
    setContent(skill.content);
    setView("editor");
    requestAnimationFrame(() => titleInputRef.current?.focus());
  }, []);

  const closeEditor = useCallback(() => {
    resetEditor();
    setView("list");
    requestAnimationFrame(() => inputRef.current?.focus());
  }, [resetEditor]);

  const handleClose = useCallback(() => {
    setView("list");
    resetEditor();
    onClose();
  }, [onClose, resetEditor]);

  const handleInstallMarketplaceSkill = useCallback(
    async (skill: MarketplaceSkill) => {
      if (isMarketplaceSkillInstalled(skills, skill.id)) return;
      await updateSetting("aiSkills", [createSkillFromMarketplace(skill), ...skills]);
    },
    [skills, updateSetting],
  );

  const handleSave = useCallback(async () => {
    const trimmedTitle = title.trim();
    if (!trimmedTitle) return;

    const now = new Date().toISOString();
    const nextSkills = editingSkillId
      ? skills.map((skill) =>
          skill.id === editingSkillId
            ? (() => {
                if (skill.source !== "marketplace") {
                  return { ...skill, title: trimmedTitle, content, updatedAt: now };
                }

                const upstreamTitle = skill.upstreamTitle ?? skill.title;
                const upstreamContent = skill.upstreamContent ?? skill.content;
                const upstreamDescription = skill.upstreamDescription ?? skill.description;

                return {
                  ...skill,
                  title: trimmedTitle,
                  content,
                  localOverride: trimmedTitle !== upstreamTitle || content !== upstreamContent,
                  upstreamTitle,
                  upstreamContent,
                  upstreamDescription,
                  updatedAt: now,
                };
              })()
            : skill,
        )
      : [
          {
            id: createSkillId(),
            title: trimmedTitle,
            content,
            source: "local" as const,
            createdAt: now,
            updatedAt: now,
          },
          ...skills,
        ];

    await updateSetting("aiSkills", nextSkills);
    closeEditor();
  }, [closeEditor, content, editingSkillId, skills, title, updateSetting]);

  const handleDelete = useCallback(
    async (skillId: string) => {
      await updateSetting(
        "aiSkills",
        skills.filter((skill) => skill.id !== skillId),
      );
      setSelectedIndex(0);
    },
    [skills, updateSetting],
  );

  const handleSelectSkill = useCallback(
    (skill: AIChatSkill) => {
      onSelectSkill(skill);
      handleClose();
    },
    [handleClose, onSelectSkill],
  );

  useEffect(() => {
    if (!isOpen) return;
    setQuery("");
    setSelectedIndex(0);
    resetEditor();
    setView(initialView);
    requestAnimationFrame(() => {
      if (initialView === "editor") {
        titleInputRef.current?.focus();
        return;
      }
      inputRef.current?.focus();
    });
  }, [initialView, isOpen, resetEditor]);

  useEffect(() => {
    setSelectedIndex(0);
  }, [deferredQuery, view]);

  useEffect(() => {
    if (!isOpen || (view !== "list" && view !== "browse")) return;

    const handleKeyDown = (event: KeyboardEvent) => {
      const activeItems = view === "browse" ? filteredMarketplaceSkills : filteredSkills;

      switch (event.key) {
        case "Escape":
          event.preventDefault();
          handleClose();
          break;
        case "ArrowDown":
          event.preventDefault();
          setSelectedIndex((current) =>
            activeItems.length === 0 ? 0 : Math.min(current + 1, activeItems.length - 1),
          );
          break;
        case "ArrowUp":
          event.preventDefault();
          setSelectedIndex((current) => Math.max(current - 1, 0));
          break;
        case "Enter":
          if (view === "list" && filteredSkills[selectedIndex]) {
            event.preventDefault();
            handleSelectSkill(filteredSkills[selectedIndex]);
          } else if (view === "browse" && filteredMarketplaceSkills[selectedIndex]) {
            event.preventDefault();
            void handleInstallMarketplaceSkill(filteredMarketplaceSkills[selectedIndex]);
          }
          break;
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [
    filteredMarketplaceSkills,
    filteredSkills,
    handleClose,
    handleInstallMarketplaceSkill,
    handleSelectSkill,
    isOpen,
    selectedIndex,
    view,
  ]);

  useEffect(() => {
    if (!isOpen || view !== "browse" || marketplaceSkills.length > 0 || isLoadingMarketplace) {
      return;
    }

    setIsLoadingMarketplace(true);
    void loadMarketplaceSkills()
      .then(setMarketplaceSkills)
      .finally(() => setIsLoadingMarketplace(false));
  }, [isLoadingMarketplace, isOpen, marketplaceSkills.length, view]);

  useEffect(() => {
    const activeLength =
      view === "browse" ? filteredMarketplaceSkills.length : filteredSkills.length;
    if (!resultsRef.current || activeLength === 0) return;
    const selectedElement = resultsRef.current.children[selectedIndex] as HTMLElement | undefined;
    selectedElement?.scrollIntoView({ block: "nearest" });
  }, [filteredMarketplaceSkills.length, filteredSkills.length, selectedIndex, view]);

  const canSave = title.trim().length > 0;
  const isComposerAttached = Boolean(anchorRef);

  const panelContent =
    view === "list" || view === "browse" ? (
      <>
        <CommandHeader onClose={handleClose}>
          <Search className="shrink-0 text-subtle-foreground" size={14} />
          <CommandInput
            ref={inputRef}
            value={query}
            onChange={setQuery}
            placeholder={view === "browse" ? t("ai.searchAvailableSkills") : t("ai.searchSkills")}
          />
          {view === "list" ? (
            <CommandHeaderAction type="button" onClick={openNewSkill}>
              <Plus />
              <span>{t("ai.new")}</span>
            </CommandHeaderAction>
          ) : (
            <CommandHeaderAction type="button" onClick={() => setView("list")}>
              <span>{t("ai.mySkills")}</span>
            </CommandHeaderAction>
          )}
          <CommandHeaderAction type="button" onClick={openBrowseSkills} active={view === "browse"}>
            <CloudArrowDown weight="fill" />
            <span>{t("ai.browse")}</span>
          </CommandHeaderAction>
        </CommandHeader>

        <CommandList ref={resultsRef} contentClassName={isComposerAttached ? "p-1.5" : undefined}>
          {view === "browse" ? (
            isLoadingMarketplace ? (
              <CommandEmpty>{t("ai.loadingAvailableSkills")}</CommandEmpty>
            ) : marketplaceSkills.length === 0 ? (
              <CommandEmpty>
                <div className="flex flex-col items-center gap-2 px-4 py-5">
                  <div>{t("ai.noPublishedSkillsYet")}</div>
                  <div className="max-w-70 text-subtle-foreground">
                    {t("ai.publishedSkillsWillAppear")}
                  </div>
                </div>
              </CommandEmpty>
            ) : filteredMarketplaceSkills.length === 0 ? (
              <CommandEmpty>{t("ai.noAvailableSkillsMatch", { query })}</CommandEmpty>
            ) : (
              filteredMarketplaceSkills.map((skill, index) => {
                const isSelected = selectedIndex === index;
                const isInstalled = isMarketplaceSkillInstalled(skills, skill.id);

                return (
                  <CommandItemRow
                    key={skill.id}
                    as="div"
                    isSelected={isSelected}
                    onClick={() =>
                      isInstalled ? undefined : void handleInstallMarketplaceSkill(skill)
                    }
                    onMouseEnter={() => setSelectedIndex(index)}
                    className="group"
                    density={isComposerAttached ? "compact" : "default"}
                    title={skill.title}
                    description={
                      <>
                        <span>{skill.description}</span>
                        {skill.author ? <span>by {skill.author}</span> : null}
                      </>
                    }
                    contentLayout={isComposerAttached ? "inline" : "stacked"}
                    accessory={
                      <>
                        {skill.version ? (
                          <CommandItemBadge>v{skill.version}</CommandItemBadge>
                        ) : null}
                        {skill.tags.slice(0, isComposerAttached ? 1 : 3).map((tag) => (
                          <CommandItemBadge key={tag}>{tag}</CommandItemBadge>
                        ))}
                      </>
                    }
                    action={
                      <Button
                        type="button"
                        variant={isInstalled ? "default" : "default"}
                        disabled={isInstalled}
                        size={isComposerAttached ? "xs" : undefined}
                        onClick={(event) => {
                          event.stopPropagation();
                          if (!isInstalled) {
                            void handleInstallMarketplaceSkill(skill);
                          }
                        }}
                      >
                        {isInstalled ? t("ai.added") : t("ai.add")}
                      </Button>
                    }
                  />
                );
              })
            )
          ) : skills.length === 0 ? (
            <CommandEmpty>{t("ai.noSkillsYet")}</CommandEmpty>
          ) : filteredSkills.length === 0 ? (
            <CommandEmpty>{t("ai.noSkillsMatch", { query })}</CommandEmpty>
          ) : (
            filteredSkills.map((skill, index) => {
              const isSelected = selectedIndex === index;
              const preview = skill.content.trim().replace(/\s+/g, " ");
              const hasLocalOverride = hasSkillLocalOverride(skill);

              return (
                <CommandItemRow
                  key={skill.id}
                  as="div"
                  isSelected={isSelected}
                  onClick={() => handleSelectSkill(skill)}
                  onMouseEnter={() => setSelectedIndex(index)}
                  className="group"
                  density={isComposerAttached ? "compact" : "default"}
                  title={skill.title}
                  description={preview}
                  contentLayout={isComposerAttached ? "inline" : "stacked"}
                  accessory={
                    <>
                      {skill.source === "marketplace" ? (
                        <CommandItemBadge>{t("ai.marketplace")}</CommandItemBadge>
                      ) : null}
                      {hasLocalOverride ? (
                        <CommandItemBadge>{t("ai.localOverride")}</CommandItemBadge>
                      ) : null}
                    </>
                  }
                  action={
                    <>
                      <Button
                        type="button"
                        variant="ghost"
                        onClick={(event) => {
                          event.stopPropagation();
                          openSkillEditor(skill);
                        }}
                        className="opacity-0 focus:opacity-100 group-hover:opacity-100"
                        tooltip={t("ai.editSkill")}
                        aria-label={t("ai.editNamedSkill", { title: skill.title })}
                        size={isComposerAttached ? "icon-xs" : "icon"}
                      >
                        <PencilSimple size={13} />
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        onClick={(event) => {
                          event.stopPropagation();
                          void handleDelete(skill.id);
                        }}
                        className="opacity-0 hover:bg-destructive/10 hover:text-destructive focus:opacity-100 group-hover:opacity-100"
                        tooltip={t("ai.deleteSkill")}
                        aria-label={t("ai.deleteNamedSkill", { title: skill.title })}
                        size={isComposerAttached ? "icon-xs" : "icon"}
                      >
                        <Trash size={13} />
                      </Button>
                    </>
                  }
                />
              );
            })
          )}
        </CommandList>

      </>
    ) : (
      <>
        <CommandHeader onClose={handleClose}>
          <div className="min-w-0 flex-1">
            <div className="font-sans ui-text-base truncate text-foreground">
              {editingSkillId ? t("ai.editSkill") : t("ai.newSkill")}
            </div>
            {(() => {
              const editingSkill = skills.find((skill) => skill.id === editingSkillId);
              if (!editingSkill || editingSkill.source !== "marketplace") return null;

              return (
                <div className="ui-text-base mt-0.5 text-subtle-foreground">
                  {hasSkillLocalOverride(editingSkill)
                    ? t("ai.marketplaceSkillWithLocalOverride")
                    : t("ai.marketplaceSkill")}
                </div>
              );
            })()}
          </div>
        </CommandHeader>

        <ScrollArea className="flex-1" contentClassName="space-y-3 p-3">
          <div className="space-y-1.5">
            <label
              className="font-sans ui-text-base text-subtle-foreground"
              htmlFor="ai-skill-title"
            >
              {t("ai.title")}
            </label>
            <Input
              id="ai-skill-title"
              ref={titleInputRef}
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder={t("ai.skillTitlePlaceholder")}
              maxLength={120}
              size="sm"
            />
          </div>

          <div className="space-y-1.5">
            <label
              className="font-sans ui-text-base text-subtle-foreground"
              htmlFor="ai-skill-content"
            >
              {t("ai.markdown")}
            </label>
            <Textarea
              id="ai-skill-content"
              value={content}
              onChange={(event) => setContent(event.target.value)}
              placeholder={t("ai.skillContentPlaceholder")}
              className="min-h-36 resize-none"
              size="sm"
            />
          </div>
        </ScrollArea>

        <CommandFooter>
          <CommandFooterAction type="button" onClick={closeEditor}>
            {t("ai.cancel")}
          </CommandFooterAction>
          <CommandFooterAction type="button" onClick={() => void handleSave()} disabled={!canSave}>
            {t("ai.save")}
          </CommandFooterAction>
        </CommandFooter>
      </>
    );

  if (anchorRef) {
    return (
      <ComposerAttachedPanel
        open={isOpen}
        anchorRef={anchorRef}
        onClose={handleClose}
        ariaLabel={t("ai.skills")}
        maxHeight={view === "editor" ? 440 : 320}
      >
        {panelContent}
      </ComposerAttachedPanel>
    );
  }

  return (
    <Command isVisible={isOpen} onClose={handleClose} title={t("ai.skills")}>
      {panelContent}
    </Command>
  );
}
