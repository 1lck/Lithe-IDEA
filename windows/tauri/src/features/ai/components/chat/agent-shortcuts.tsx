import {
  BookOpenIcon as BookOpen,
  MagnifyingGlassIcon as Search,
  SparkleIcon as Sparkles,
  TerminalWindowIcon as Terminal,
} from "@/ui/icons";
import { useMemo } from "react";
import { dispatchAIChatSkillInsert } from "@/features/ai/lib/skill-events";
import type { AIChatSkill } from "@/features/ai/types/skills.types";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { cn } from "@/utils/cn";

const shortcutIcons = [Sparkles, Search, Terminal, BookOpen];
const shortcutIconClassNames = ["text-primary", "text-success", "text-warning", "text-destructive"];
const builtinShortcuts: AIChatSkill[] = [
  {
    id: "builtin-plan-implementation",
    title: "aiShortcut.planImplementation",
    content: "aiShortcut.planImplementationContent",
    createdAt: "",
    updatedAt: "",
  },
  {
    id: "builtin-find-fix-bug",
    title: "aiShortcut.findFixBug",
    content: "aiShortcut.findFixBugContent",
    createdAt: "",
    updatedAt: "",
  },
  {
    id: "builtin-write-tests",
    title: "aiShortcut.writeTests",
    content: "aiShortcut.writeTestsContent",
    createdAt: "",
    updatedAt: "",
  },
  {
    id: "builtin-review-changes",
    title: "aiShortcut.reviewChanges",
    content: "aiShortcut.reviewChangesContent",
    createdAt: "",
    updatedAt: "",
  },
];

export function AgentShortcuts({
  className,
  surfaceId,
}: {
  className?: string;
  surfaceId: string;
}) {
  const { t } = useTranslation();
  const skills = useSettingsStore((state) => state.settings.aiSkills);
  const visibleSkills = useMemo(
    () =>
      [
        ...[...skills].sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt)),
        ...builtinShortcuts,
      ].slice(0, 4),
    [skills],
  );

  return (
    <section
      className={cn("flex w-full flex-col gap-0.5", className)}
      aria-label={t("ai.suggestions")}
    >
      {visibleSkills.map((skill, index) => {
        const Icon = shortcutIcons[index % shortcutIcons.length];
        const isBuiltinShortcut = skill.id.startsWith("builtin-");
        const localizedSkill = isBuiltinShortcut
          ? { ...skill, title: t(skill.title), content: t(skill.content) }
          : skill;

        return (
          <Button
            key={localizedSkill.id}
            type="button"
            variant="ghost"
            size="lg"
            className="w-full justify-start overflow-hidden"
            onClick={() => dispatchAIChatSkillInsert(localizedSkill, surfaceId)}
          >
            <Icon className={shortcutIconClassNames[index % shortcutIconClassNames.length]} />
            <span className="min-w-0 truncate">{localizedSkill.title}</span>
          </Button>
        );
      })}
    </section>
  );
}
