import { useEffect } from "react";
import { useUpdateStore } from "../stores/update.store";

const UPDATE_CHECK_DELAY = 5000;
const UPDATE_CHECK_INTERVAL = 4 * 60 * 60 * 1000;

export const useAutoUpdate = () => {
  const checkForUpdates = useUpdateStore((state) => state.actions.checkForUpdates);

  useEffect(() => {
    const timeoutId = window.setTimeout(() => {
      void checkForUpdates();
    }, UPDATE_CHECK_DELAY);
    const intervalId = window.setInterval(() => {
      void checkForUpdates();
    }, UPDATE_CHECK_INTERVAL);

    return () => {
      window.clearTimeout(timeoutId);
      window.clearInterval(intervalId);
    };
  }, [checkForUpdates]);
};
