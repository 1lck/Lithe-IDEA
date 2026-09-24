import { useMemo, useRef, useState } from "react";
import { useQuota } from "../hooks/use-quota";
import { QUOTA_PLATFORM_LABEL_KEYS, selectActiveQuota } from "../services/quota-api";
import { mostUrgentPlatformWindow, quotaTone, type QuotaTone } from "../services/quota-format";
import type { QuotaFailure, QuotaPlatformId } from "../types/quota.types";
import { QuotaPanel } from "./quota-panel";
import { FooterStatusChip } from "@/features/layout/components/footer/footer-status-chip";
import { useTranslation } from "@/i18n/locale-provider";
import { Dropdown } from "@/ui/dropdown";
import { PulseIcon, WarningCircleIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

const RING_RADIUS = 5;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const TONE_TEXT_CLASS: Record<QuotaTone, string> = {
  ok: "text-success",
  warning: "text-warning",
  danger: "text-destructive",
};

// "Unsupported" and "not configured" are facts about this machine, not faults,
// so they do not get a warning colour. Every other failure (timeout,
// throttling, an expired credential) is something the user can act on.
const QUIET_FAILURES: ReadonlySet<QuotaFailure> = new Set<QuotaFailure>([
  "unsupported",
  "unavailable",
]);

function QuotaRing({ percent }: { percent: number }) {
  const clamped = Math.min(100, Math.max(0, percent));
  return (
    <svg viewBox="0 0 14 14" className="size-3.5 shrink-0" aria-hidden="true">
      <circle
        cx="7"
        cy="7"
        r={RING_RADIUS}
        fill="none"
        strokeWidth="2"
        className="stroke-current opacity-25"
      />
      <circle
        cx="7"
        cy="7"
        r={RING_RADIUS}
        fill="none"
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={`${(RING_CIRCUMFERENCE * clamped) / 100} ${RING_CIRCUMFERENCE}`}
        transform="rotate(-90 7 7)"
        className="stroke-current"
      />
    </svg>
  );
}

export function QuotaChip() {
  const { t } = useTranslation();
  const { snapshot, isRefreshing, refresh } = useQuota();
  const [isOpen, setIsOpen] = useState(false);
  const [selectedPlatform, setSelectedPlatform] = useState<QuotaPlatformId | null>(null);
  const anchorRef = useRef<HTMLSpanElement>(null);

  const active = useMemo(
    () => selectActiveQuota(snapshot, selectedPlatform),
    [snapshot, selectedPlatform],
  );

  const queryable = useMemo(() => snapshot.filter((entry) => !entry.failure), [snapshot]);
  // The summary is the tightest window across platforms; the panel's platform
  // switch only affects the panel
  const urgentPlatform = useMemo(() => mostUrgentPlatformWindow(snapshot), [snapshot]);
  const urgent = urgentPlatform?.window ?? null;
  const tone =
    urgent !== null && urgent.usedPercent !== null ? quotaTone(urgent.usedPercent) : null;
  const failure = snapshot.length > 0 && queryable.length === 0 ? (active?.failure ?? null) : null;
  const isQuietFailure = failure !== null && QUIET_FAILURES.has(failure);
  // One readable platform makes the name redundant; two make it mandatory
  const platformPrefix =
    urgentPlatform && queryable.length > 1
      ? `${t(QUOTA_PLATFORM_LABEL_KEYS[urgentPlatform.platform])} `
      : "";

  let summary: string;
  if (snapshot.length === 0) {
    summary = t("usage.chip.loading");
  } else if (failure) {
    // The status bar chip is 200px wide: short label in the chip, full reason in
    // the tooltip and panel
    summary = `${t("usage.chip.label")} · ${t(`usage.failureShort.${failure}`)}`;
  } else if (urgent) {
    summary =
      urgent.usedPercent === null
        ? `${platformPrefix}${urgent.key} —`
        : `${platformPrefix}${urgent.key} ${Math.round(urgent.usedPercent)}%`;
  } else {
    summary = t("usage.chip.label");
  }

  const tooltip = failure
    ? `${t(`usage.failure.${failure}`)} — ${t(`usage.failureHint.${failure}`)}`
    : undefined;

  return (
    <span ref={anchorRef} className="flex items-center">
      <FooterStatusChip
        onClick={() => setIsOpen((open) => !open)}
        aria-haspopup="true"
        aria-expanded={isOpen}
        aria-label={t("usage.chip.ariaLabel")}
        title={tooltip}
        className={cn(
          "gap-1.5",
          tone ? TONE_TEXT_CLASS[tone] : undefined,
          failure && !isQuietFailure ? "text-warning" : undefined,
        )}
      >
        {failure && !isQuietFailure ? (
          <WarningCircleIcon className="size-3.5 shrink-0" />
        ) : urgent && tone ? (
          <QuotaRing percent={urgent.usedPercent ?? 0} />
        ) : (
          <PulseIcon className="size-3.5 shrink-0" />
        )}
        <span className="truncate">{summary}</span>
      </FooterStatusChip>

      <Dropdown
        isOpen={isOpen}
        onClose={() => setIsOpen(false)}
        anchorRef={anchorRef}
        anchorSide="top"
        anchorAlign="end"
        className="w-72"
      >
        <QuotaPanel
          snapshot={snapshot}
          active={active}
          isRefreshing={isRefreshing}
          onRefresh={refresh}
          onSelectPlatform={setSelectedPlatform}
        />
      </Dropdown>
    </span>
  );
}
