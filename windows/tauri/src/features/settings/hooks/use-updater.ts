import { useEffect } from "react";
import { useUpdateStore } from "../stores/update.store";

export type {
  UpdateCheckResult,
  UpdateErrorCode,
  UpdateInfo,
  UpdateState,
  UpdateStatus,
} from "../stores/update.store";

export const useUpdater = (checkOnMount = true) => {
  const state = useUpdateStore((store) => store);
  const actions = useUpdateStore((store) => store.actions);

  useEffect(() => {
    if (checkOnMount) {
      void actions.checkForUpdates();
    }
  }, [actions, checkOnMount]);

  return {
    ...state,
    available: state.status === "available",
    checking: state.status === "checking",
    downloading: state.status === "downloading",
    installing: state.status === "installing",
    checkForUpdates: actions.checkForUpdates,
    downloadAndInstall: actions.downloadAndInstall,
    dismissUpdate: actions.dismissUpdate,
    downloadLater: actions.downloadLater,
    remindLater: actions.remindLater,
    skipVersion: actions.skipVersion,
    viewReleaseNotes: actions.viewReleaseNotes,
  };
};
