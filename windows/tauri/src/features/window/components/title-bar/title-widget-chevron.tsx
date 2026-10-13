import { ChevronDownIcon } from "@/ui/icons";

/**
 * Dropdown arrow of an IntelliJ main toolbar widget (ToolbarComboButton): General.ChevronDown at
 * its native 16px, 2px after the text (BEFORE_CHEVRON_GAP). The -ml-1 trims the trigger's 6px
 * icon-text gap down to those 2px.
 */
export function TitleWidgetChevron() {
  return <ChevronDownIcon aria-hidden className="-ml-1 size-4 shrink-0" />;
}
