import { useCallback, useEffect, useRef, useState } from "react";
import { UsageScanner } from "../services/usage-collector";
import { UsageLedger, type UsageLedgerSnapshot } from "../services/usage-ledger";
import { loadPersistedUsageLedger, persistUsageLedger } from "../services/usage-persistence";

/**
 * A scan only reads the bytes appended since the last one, so it can run often.
 * The first scan of the very first run digests the whole log history, which is
 * why the panel says so while it happens.
 */
const USAGE_SCAN_INTERVAL_MS = 30_000;

export interface UsageController {
  snapshot: UsageLedgerSnapshot;
  /** True while a scan started by the user is running. */
  isScanning: boolean;
  /** True until the first scan of this session has produced a snapshot. */
  isFirstScan: boolean;
  scan: () => void;
}

const EMPTY_SNAPSHOT: UsageLedgerSnapshot = {
  records: [],
  roots: [],
  lastScanAt: null,
  trackedFiles: 0,
};

export function useUsage(): UsageController {
  const [snapshot, setSnapshot] = useState<UsageLedgerSnapshot>(EMPTY_SNAPSHOT);
  const [isScanning, setIsScanning] = useState(false);
  const [isFirstScan, setIsFirstScan] = useState(true);
  const scannerRef = useRef<UsageScanner | null>(null);

  useEffect(() => {
    let isMounted = true;
    const ledger = new UsageLedger();
    const scanner = new UsageScanner(ledger, setSnapshot);
    scannerRef.current = scanner;
    scanner.start();

    void loadPersistedUsageLedger().then((stored) => {
      if (!isMounted) return;
      // Showing the previous run first means the panel is useful immediately
      // instead of empty while a scan runs.
      ledger.restore(stored);
      setSnapshot(ledger.snapshot());
      void scanner.scan().finally(() => {
        if (isMounted) setIsFirstScan(false);
      });
    });

    const intervalId = window.setInterval(() => {
      if (document.visibilityState === "hidden") return;
      void scanner.scan();
    }, USAGE_SCAN_INTERVAL_MS);

    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        void scanner.scan();
        return;
      }
      // The window is going away, so the throttled write cannot wait.
      void persistUsageLedger(ledger, { force: true });
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);

    return () => {
      isMounted = false;
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.clearInterval(intervalId);
      scanner.stop();
      scannerRef.current = null;
      void persistUsageLedger(ledger, { force: true });
    };
  }, []);

  const scan = useCallback(() => {
    const scanner = scannerRef.current;
    if (!scanner) return;
    setIsScanning(true);
    void scanner.scan().finally(() => setIsScanning(false));
  }, []);

  return { snapshot, isScanning, isFirstScan, scan };
}
