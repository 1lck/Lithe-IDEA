import { useMemo } from "react";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { NotificationsTrigger } from "@/features/notifications/components/notifications-trigger";
import {
  FOOTER_TRAILING_ITEM_IDS,
  normalizeItemOrder,
  type FooterLeadingItemId,
  type FooterTrailingItemId,
} from "@/features/layout/config/item-order";
import { orderChromeItems, type ChromeItem } from "@/features/layout/utils/chrome-items";
import { useTranslation } from "@/i18n/locale-provider";
import { useFooterFilePathItem } from "./footer-file-path-item";
import { useFooterEditorStatusItems } from "./footer-editor-status";
import { ChromeBar, ChromeGroup } from "@/ui/chrome";

const Footer = () => {
  const { t } = useTranslation();
  const footerLeadingItemsOrder = useSettingsStore(
    (state) => state.settings.footerLeadingItemsOrder,
  );
  const footerTrailingItemsOrder = useSettingsStore(
    (state) => state.settings.footerTrailingItemsOrder,
  );
  const filePathItem = useFooterFilePathItem();
  const editorStatusItems = useFooterEditorStatusItems();
  const footerLeadingItemsSource: Array<ChromeItem<FooterLeadingItemId> | null> = [
    filePathItem,
  ];
  const footerLeadingItems = footerLeadingItemsSource.filter(
    (item): item is ChromeItem<FooterLeadingItemId> => item !== null,
  );
  const footerTrailingOrder = useMemo<FooterTrailingItemId[]>(() => {
    return normalizeItemOrder(
      footerTrailingItemsOrder,
      FOOTER_TRAILING_ITEM_IDS,
    ) as FooterTrailingItemId[];
  }, [footerTrailingItemsOrder]);

  const footerTrailingItems: Array<ChromeItem<FooterTrailingItemId> | null> = [
    ...editorStatusItems,
    {
      id: "notifications",
      label: t("notifications.title"),
      content: <NotificationsTrigger />,
    },
  ];
  const visibleTrailingItems = footerTrailingItems.filter(
    (item): item is ChromeItem<FooterTrailingItemId> => item !== null,
  );

  return (
    <ChromeBar
      region="footer"
      className="lithe-footer-bar relative z-20 justify-between gap-2 bg-surface"
      aria-label={t("footer.statusBar")}
    >
      <ChromeGroup gap="tight" grow className="min-w-0">
        {filePathItem ? (
          <div className="flex min-h-(--lithe-chrome-control-height) min-w-0 flex-1 items-center overflow-hidden">
            {filePathItem.content}
          </div>
        ) : null}
        {orderChromeItems(
          footerLeadingItems.filter((item) => item.id !== "filePath"),
          footerLeadingItemsOrder,
        ).map((item) => (
          <div key={item.id} className="flex min-h-(--lithe-chrome-control-height) shrink-0 items-center">
            {item.content}
          </div>
        ))}
      </ChromeGroup>

      <ChromeGroup gap="tight" align="end" className="shrink-0">
        {orderChromeItems(visibleTrailingItems, footerTrailingOrder).map((item) => (
          <div key={item.id} className="flex min-h-(--lithe-chrome-control-height) items-center">
            {item.content}
          </div>
        ))}
      </ChromeGroup>
    </ChromeBar>
  );
};

export default Footer;
