import { useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { CheckIcon, XIcon } from "@/ui/icons";
import { Dropdown, type DropdownSection } from "@/ui/dropdown";
import type { GitReference } from "../../types/git.types";
import { groupGitLogBranchFilterReferences } from "../../utils/git-log-branch-filter";
import { TitleWidgetChevron } from "@/features/window/components/title-bar/title-widget-chevron";

/**
 * Branch filter of the Git Log toolbar, after IDEA's BranchFilterPopupComponent: it shows the
 * applied branch and picks one from a searchable popup, or "All" to clear the filter.
 */
export function GitLogBranchFilter({
  references,
  selectedReference,
  onSelect,
}: {
  references: readonly GitReference[];
  selectedReference: GitReference | null;
  onSelect: (reference: GitReference | null) => void;
}) {
  const { t } = useTranslation();
  const anchorRef = useRef<HTMLButtonElement>(null);
  const [isOpen, setIsOpen] = useState(false);
  const label = t("git.log.branchFilter", { name: selectedReference?.shortName ?? t("git.log.all") });

  const sections = useMemo<DropdownSection[]>(() => {
    const item = (id: string, label: string, reference: GitReference | null) => ({
      id,
      label,
      icon:
        (selectedReference?.fullName ?? null) === (reference?.fullName ?? null) ? (
          <CheckIcon />
        ) : (
          <span className="size-4" />
        ),
      onClick: () => onSelect(reference),
    });
    return [
      { id: "all", items: [item("all", t("git.log.all"), null)] },
      ...groupGitLogBranchFilterReferences(references).map((group) => ({
        id: group.id,
        label: group.remoteName ? `${group.remoteName}/…` : t("git.log.local"),
        items: group.references.map((reference) =>
          item(reference.fullName, reference.shortName, reference),
        ),
      })),
    ];
  }, [onSelect, references, selectedReference, t]);

  return (
    <>
      <div className="flex h-6 max-w-56 shrink-0 items-center rounded hover:bg-accent">
        <button
          ref={anchorRef}
          type="button"
          onClick={() => setIsOpen((open) => !open)}
          className="flex h-6 min-w-0 items-center gap-1 rounded px-1.5 text-foreground"
          aria-haspopup="menu"
          aria-expanded={isOpen}
          aria-label={label}
        >
          <span className="min-w-0 truncate">{label}</span>
          <TitleWidgetChevron />
        </button>
        {selectedReference ? (
          // Back to "All", like IDEA's clearable filter chips.
          <button
            type="button"
            onClick={() => onSelect(null)}
            className="mr-1 flex size-4 shrink-0 items-center justify-center rounded text-subtle-foreground hover:text-foreground"
            aria-label={t("git.log.clearBranchFilter")}
            title={t("git.log.clearBranchFilter")}
          >
            <XIcon className="size-3" />
          </button>
        ) : null}
      </div>
      <Dropdown
        isOpen={isOpen}
        onClose={() => setIsOpen(false)}
        anchorRef={anchorRef}
        sections={sections}
        searchable
        searchPlaceholder={t("git.searchBranches")}
        style={{ maxHeight: 320 }}
      />
    </>
  );
}
