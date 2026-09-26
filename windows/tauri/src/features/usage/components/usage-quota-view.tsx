import { useMemo, useState } from "react";
import { useQuota } from "../hooks/use-quota";
import { selectActiveQuota } from "../services/quota-api";
import type { QuotaPlatformId } from "../types/quota.types";
import { QuotaPanel } from "./quota-panel";

/**
 * The quota half of the panel.
 *
 * It reads the live endpoint rather than the local logs, which is why it lives
 * beside the token statistics instead of inside them: one answers "how much of
 * my subscription is left", the other "what have I actually spent".
 */
export function UsageQuotaView() {
  const { snapshot, isRefreshing, refresh } = useQuota();
  const [selectedPlatform, setSelectedPlatform] = useState<QuotaPlatformId | null>(null);

  const active = useMemo(
    () => selectActiveQuota(snapshot, selectedPlatform),
    [snapshot, selectedPlatform],
  );

  return (
    <QuotaPanel
      snapshot={snapshot}
      active={active}
      isRefreshing={isRefreshing}
      onRefresh={refresh}
      onSelectPlatform={setSelectedPlatform}
      showDataSource={false}
    />
  );
}
