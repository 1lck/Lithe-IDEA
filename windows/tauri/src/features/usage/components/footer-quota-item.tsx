import { QuotaChip } from "./quota-chip";
import type { FooterTrailingItemId } from "@/features/layout/config/item-order";
import type { ChromeItem } from "@/features/layout/utils/chrome-items";
import { useTranslation } from "@/i18n/locale-provider";

export function useFooterQuotaItem(): ChromeItem<FooterTrailingItemId> {
  const { t } = useTranslation();

  return {
    id: "aiUsage",
    label: t("usage.chip.label"),
    content: <QuotaChip />,
  };
}
