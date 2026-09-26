import { useCallback, useEffect, useRef, useState } from "react";
import { QuotaPoller } from "../services/quota-api";
import type { PlatformQuota } from "../types/quota.types";

const QUOTA_POLL_INTERVAL_MS = 60_000;

export interface QuotaController {
  snapshot: PlatformQuota[];
  isRefreshing: boolean;
  refresh: () => void;
}

export function useQuota(): QuotaController {
  const [snapshot, setSnapshot] = useState<PlatformQuota[]>([]);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const pollerRef = useRef<QuotaPoller | null>(null);

  useEffect(() => {
    const poller = new QuotaPoller(setSnapshot);
    pollerRef.current = poller;
    poller.start();

    setIsRefreshing(true);
    void poller.poll().finally(() => setIsRefreshing(false));

    const intervalId = window.setInterval(() => {
      if (document.visibilityState === "hidden") return;
      void poller.poll();
    }, QUOTA_POLL_INTERVAL_MS);

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void poller.poll();
      }
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.clearInterval(intervalId);
      poller.stop();
      pollerRef.current = null;
    };
  }, []);

  const refresh = useCallback(() => {
    const poller = pollerRef.current;
    if (!poller) return;
    setIsRefreshing(true);
    void poller.poll().finally(() => setIsRefreshing(false));
  }, []);

  return { snapshot, isRefreshing, refresh };
}
