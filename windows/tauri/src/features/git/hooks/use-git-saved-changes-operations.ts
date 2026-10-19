import { getPathIdentity } from "@/utils/path-helpers";
import { useSavedChangesOperationsStore } from "../stores/git-saved-changes-operations.store";

/** Keep each repository locked until its own pending operation actually settles. */
export function useGitSavedChangesOperations(activeRoot: string | null | undefined) {
  const pending = useSavedChangesOperationsStore((state) => state.pending);
  const startOperation = useSavedChangesOperationsStore((state) => state.startOperation);

  return {
    busy: Boolean(activeRoot && pending.has(getPathIdentity(activeRoot))),
    workspaceBusy: pending.size > 0,
    startOperation,
  };
}
