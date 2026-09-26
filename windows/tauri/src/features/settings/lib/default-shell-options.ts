import type { Shell } from "@/features/terminal/types/terminal.types";

export const SYSTEM_DEFAULT_SHELL_VALUE = "";

export interface DefaultShellOption {
  value: string;
  // Display name reported by shell discovery; absent for the system default and unknown ids.
  shellName?: string;
  isAvailable: boolean;
}

// Builds the default-shell choices from the same discovery list that feeds the terminal
// "New Terminal" menu, so both surfaces always offer the same shells.
export function getDefaultShellOptions({
  shells,
  selectedShellId,
  hasLoaded,
}: {
  shells: readonly Shell[];
  selectedShellId: string;
  hasLoaded: boolean;
}): DefaultShellOption[] {
  const options: DefaultShellOption[] = [
    { value: SYSTEM_DEFAULT_SHELL_VALUE, isAvailable: true },
    ...shells.map((shell) => ({ value: shell.id, shellName: shell.name, isAvailable: true })),
  ];

  // Keep a saved choice visible even when discovery no longer reports it, so the select
  // never silently shows a different shell than the one that will be launched.
  if (
    selectedShellId !== SYSTEM_DEFAULT_SHELL_VALUE &&
    !options.some((option) => option.value === selectedShellId)
  ) {
    options.push({ value: selectedShellId, isAvailable: !hasLoaded });
  }

  return options;
}
