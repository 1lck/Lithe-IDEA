import { MagnifyingGlassIcon as Search } from "@/ui/icons";
import { useMemo, useState } from "react";
import { Button } from "@/ui/button";
import { Empty, EmptyDescription } from "@/ui/empty";
import { useTranslation } from "@/i18n/locale-provider";
import Input from "@/ui/input";
import { Toggle } from "@/ui/toggle";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";

const RECENT_EMOJI_STORAGE_KEY = "lithe.ui.emoji-picker.recent";
const MAX_RECENT_EMOJIS = 8;

const defaultEmojiPickerOptions = [
  "💬",
  "🛠️",
  "🚀",
  "🧪",
  "📣",
  "🔒",
  "📌",
  "⚡",
  "✅",
  "🔥",
  "🎯",
  "🧠",
  "👀",
  "🙌",
  "🙏",
  "❤️",
  "✨",
  "⭐",
  "💡",
  "📎",
  "📁",
  "📝",
  "🐛",
  "🚨",
  "⏳",
  "🔍",
  "🎨",
  "⚙️",
  "🧩",
  "🧵",
  "📦",
  "🧹",
];

const emojiLabels: Record<string, { labelKey: string; keywords: string[] }> = {
  "💬": { labelKey: "collaboration.message", keywords: ["chat", "comment", "thread"] },
  "🛠️": { labelKey: "collaboration.tools", keywords: ["fix", "build", "work"] },
  "🚀": { labelKey: "collaboration.launch", keywords: ["ship", "release", "deploy"] },
  "🧪": { labelKey: "collaboration.test", keywords: ["lab", "qa", "experiment"] },
  "📣": { labelKey: "collaboration.announcement", keywords: ["news", "broadcast"] },
  "🔒": { labelKey: "collaboration.private", keywords: ["lock", "secure"] },
  "📌": { labelKey: "collaboration.pinned", keywords: ["pin", "important"] },
  "⚡": { labelKey: "collaboration.fast", keywords: ["bolt", "performance"] },
  "✅": { labelKey: "collaboration.done", keywords: ["check", "complete"] },
  "🔥": { labelKey: "collaboration.hot", keywords: ["fire", "urgent"] },
  "🎯": { labelKey: "collaboration.goal", keywords: ["target", "focus"] },
  "🧠": { labelKey: "collaboration.ideas", keywords: ["brain", "think"] },
  "👀": { labelKey: "collaboration.review", keywords: ["eyes", "look"] },
  "🙌": { labelKey: "collaboration.celebrate", keywords: ["hands", "thanks"] },
  "🙏": { labelKey: "collaboration.request", keywords: ["please", "pray"] },
  "❤️": { labelKey: "collaboration.love", keywords: ["heart", "like"] },
  "✨": { labelKey: "collaboration.polish", keywords: ["sparkles", "clean"] },
  "⭐": { labelKey: "collaboration.star", keywords: ["favorite", "important"] },
  "💡": { labelKey: "collaboration.idea", keywords: ["light", "bulb"] },
  "📎": { labelKey: "collaboration.attachment", keywords: ["clip", "file"] },
  "📁": { labelKey: "collaboration.files", keywords: ["folder", "project"] },
  "📝": { labelKey: "collaboration.notes", keywords: ["memo", "write"] },
  "🐛": { labelKey: "collaboration.bug", keywords: ["issue", "debug"] },
  "🚨": { labelKey: "collaboration.alert", keywords: ["warning", "incident"] },
  "⏳": { labelKey: "collaboration.waiting", keywords: ["hourglass", "pending"] },
  "🔍": { labelKey: "collaboration.search", keywords: ["find", "inspect"] },
  "🎨": { labelKey: "collaboration.design", keywords: ["paint", "style"] },
  "⚙️": { labelKey: "collaboration.settings", keywords: ["gear", "config"] },
  "🧩": { labelKey: "collaboration.integration", keywords: ["plugin", "piece"] },
  "🧵": { labelKey: "collaboration.thread", keywords: ["conversation", "topic"] },
  "📦": { labelKey: "collaboration.package", keywords: ["box", "bundle"] },
  "🧹": { labelKey: "collaboration.cleanup", keywords: ["sweep", "refactor"] },
};

interface EmojiPickerProps {
  selected?: string;
  options?: string[];
  columns?: number;
  onSelect: (emoji: string) => void;
  onClear?: () => void;
  clearLabel?: string;
  className?: string;
}

function getEmojiLabel(emoji: string, t: (key: string) => string) {
  const labelKey = emojiLabels[emoji]?.labelKey;
  return labelKey ? t(labelKey) : emoji;
}

function getRecentEmojis(options: string[]) {
  if (typeof window === "undefined") return [];

  try {
    const parsed = JSON.parse(window.localStorage.getItem(RECENT_EMOJI_STORAGE_KEY) ?? "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (value): value is string => typeof value === "string" && options.includes(value),
    );
  } catch {
    return [];
  }
}

function rememberEmoji(emoji: string, options: string[]) {
  if (typeof window === "undefined") return;

  const recent = getRecentEmojis(options);
  const next = [emoji, ...recent.filter((value) => value !== emoji)].slice(0, MAX_RECENT_EMOJIS);
  window.localStorage.setItem(RECENT_EMOJI_STORAGE_KEY, JSON.stringify(next));
}

export function EmojiPicker({
  selected,
  options = defaultEmojiPickerOptions,
  columns = 6,
  onSelect,
  onClear,
  clearLabel = "Reset to default",
  className,
}: EmojiPickerProps) {
  const { t } = useTranslation();
  const [query, setQuery] = useState("");
  const [recentEmojis, setRecentEmojis] = useState(() => getRecentEmojis(options));

  const normalizedQuery = query.trim().toLowerCase();
  const filteredOptions = useMemo(() => {
    if (!normalizedQuery) return options;

    return options.filter((emoji) => {
      const metadata = emojiLabels[emoji];
      const haystack = [
        emoji,
        metadata?.labelKey ? t(metadata.labelKey) : undefined,
        ...(metadata?.keywords ?? []),
      ]
        .filter(Boolean)
        .join(" ")
        .toLowerCase();
      return haystack.includes(normalizedQuery);
    });
  }, [normalizedQuery, options, t]);

  const visibleRecentEmojis = useMemo(() => {
    if (normalizedQuery) return [];
    return recentEmojis.filter((emoji) => options.includes(emoji));
  }, [normalizedQuery, options, recentEmojis]);

  const primaryOptions = useMemo(
    () => filteredOptions.filter((emoji) => !visibleRecentEmojis.includes(emoji)),
    [filteredOptions, visibleRecentEmojis],
  );

  const handleSelect = (emoji: string) => {
    rememberEmoji(emoji, options);
    setRecentEmojis(getRecentEmojis(options));
    onSelect(emoji);
  };

  const renderEmojiButton = (emoji: string) => (
    <Tooltip key={emoji} content={getEmojiLabel(emoji, t)} side="top">
      <Toggle
        type="button"
        size="md"
        pressed={selected === emoji}
        onPressedChange={(pressed) => pressed && handleSelect(emoji)}
        aria-label={t("collaboration.selectEmoji", { label: getEmojiLabel(emoji, t) })}
      >
        {emoji}
      </Toggle>
    </Tooltip>
  );

  return (
    <div className={cn("w-full", className)}>
      <Input
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        placeholder={t("collaboration.searchEmoji")}
        aria-label={t("collaboration.searchEmoji")}
        size="xs"
        leftIcon={Search}
      />

      {visibleRecentEmojis.length > 0 ? (
        <div className="mt-2">
          <div className="mb-1 px-1 ui-text-sm text-subtle-foreground uppercase">
            {t("collaboration.recent")}
          </div>
          <div
            className="grid gap-1"
            style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
          >
            {visibleRecentEmojis.map(renderEmojiButton)}
          </div>
        </div>
      ) : null}

      <div
        className="mt-2 grid gap-1"
        style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}
      >
        {primaryOptions.map(renderEmojiButton)}
      </div>

      {filteredOptions.length === 0 ? (
        <Empty className="mt-2">
          <EmptyDescription>{t("collaboration.noMatchingEmoji")}</EmptyDescription>
        </Empty>
      ) : null}

      {onClear ? (
        <Button type="button" variant="ghost" size="sm" className="mt-2 w-full" onClick={onClear}>
          {clearLabel}
        </Button>
      ) : null}
    </div>
  );
}
