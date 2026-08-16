import { useMemo, type ReactNode } from "react";
import { BACKEND_UNAVAILABLE_TOOLTIP } from "@/config/backend-capabilities";
import { useTranslation } from "@/i18n/locale-provider";
import type { CoreFeaturesState } from "@/features/settings/types/feature.types";
import { normalizeItemOrder } from "@/features/layout/config/item-order";
import { RunIcon } from "@/features/run/components/run-icon";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { SidebarListItem } from "@/ui/sidebar";
import { Tabs, TabsList, TabsTrigger } from "@/ui/tabs";
import {
  DatabaseIcon,
  GearIcon,
  GitBranchIcon,
  FilesIcon,
  MagnifyingGlassIcon,
} from "@/ui/icons";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import type { SidebarView } from "../../utils/sidebar-pane-utils";

const BOTTOM_ACTIVITY_ITEM_IDS = ["run", "settings"] as const;

interface SidebarPaneItem {
  id: string;
  label?: ReactNode;
  icon?: ReactNode;
  isActive?: boolean;
  onClick?: () => void;
  ariaLabel?: string;
  className?: string;
  disabled?: boolean;
  tooltip?: {
    content: string;
    shortcut?: string;
    side?: "top" | "bottom" | "left" | "right";
    className?: string;
  };
}

function orderItems<T extends { id: string }>(items: T[], orderedIds: string[]) {
  const itemMap = new Map(items.map((item) => [item.id, item]));
  const orderedItems = orderedIds
    .map((id) => itemMap.get(id))
    .filter((item): item is T => Boolean(item));
  const orderedIdSet = new Set(orderedIds);
  const missingItems = items.filter((item) => !orderedIdSet.has(item.id));
  return [...orderedItems, ...missingItems];
}

interface SidebarPaneSelectorProps {
  activeSidebarView: SidebarView;
  isGitViewActive: boolean;
  isSidebarVisible?: boolean;
  coreFeatures: CoreFeaturesState;
  onViewChange: (view: SidebarView) => void;
  onSearchClick?: () => void;
  isSearchActive?: boolean;
  onSettingsClick?: () => void;
  onRunClick?: () => void;
  isRunActive?: boolean;
  compact?: boolean;
  showLabels?: boolean;
  orientation?: "horizontal" | "vertical";
}

export const SidebarPaneSelector = ({
  activeSidebarView,
  isGitViewActive,
  isSidebarVisible = true,
  coreFeatures,
  onViewChange,
  onSearchClick,
  isSearchActive = false,
  onSettingsClick,
  onRunClick,
  isRunActive = false,
  compact = false,
  showLabels = false,
  orientation = "horizontal",
}: SidebarPaneSelectorProps) => {
  const { t } = useTranslation();
  const isVertical = orientation === "vertical";
  const tooltipSide = isVertical ? "right" : "bottom";
  const iconClassName = compact || isVertical ? "size-4" : undefined;
  const isBufferOwnedSurfaceActive = isSearchActive;
  const isPrimarySidebarItemActive = isSidebarVisible && !isBufferOwnedSurfaceActive;
  const isFilesActive =
    isPrimarySidebarItemActive &&
    !isGitViewActive &&
    activeSidebarView === "files";
  const sidebarActivityItemsOrder = useSettingsStore(
    (state) => state.settings.sidebarActivityItemsOrder,
  );
  const hiddenSidebarActivityItems = useSettingsStore(
    (state) => state.settings.hiddenSidebarActivityItems,
  );

  const items = useMemo<SidebarPaneItem[]>(
    () => [
      {
        id: "files",
        label: showLabels ? t("workbench.project") : undefined,
        icon: <FilesIcon className={iconClassName} />,
        isActive: isFilesActive,
        onClick: () => onViewChange("files"),
        ariaLabel: t("workbench.project"),
        tooltip: {
          content: t("workbench.project"),
          shortcut: "Mod+Shift+E",
          side: tooltipSide,
        },
      },
      ...(coreFeatures.search && onSearchClick
        ? [
            {
              id: "search",
              label: showLabels ? t("workbench.search") : undefined,
              icon: <MagnifyingGlassIcon className={iconClassName} />,
              isActive: isSearchActive,
              onClick: onSearchClick,
              ariaLabel: t("workbench.search"),
              tooltip: {
                content: t("workbench.search"),
                shortcut: "Mod+Shift+F",
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      ...(coreFeatures.git
        ? [
            {
              id: "git",
              label: showLabels ? t("workbench.changes") : undefined,
              icon: <GitBranchIcon className={iconClassName} />,
              isActive: isPrimarySidebarItemActive && isGitViewActive,
              onClick: () => onViewChange("git"),
              ariaLabel: t("workbench.changes"),
              tooltip: {
                content: t("workbench.changes"),
                shortcut: "Mod+Shift+G",
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      {
        id: "database",
        label: showLabels ? t("workbench.database") : undefined,
        icon: <DatabaseIcon className={iconClassName} />,
        disabled: true,
        ariaLabel: t("workbench.database"),
        tooltip: {
          content: BACKEND_UNAVAILABLE_TOOLTIP,
          side: tooltipSide,
        },
      },
      ...(onRunClick
        ? [
            {
              id: "run",
              label: showLabels ? t("workbench.run") : undefined,
              icon: <RunIcon className={iconClassName} />,
              isActive: isRunActive,
              onClick: onRunClick,
              ariaLabel: t("workbench.run"),
              tooltip: {
                content: t("workbench.run"),
                shortcut: "Shift+F10",
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      ...(onSettingsClick
        ? [
            {
              id: "settings",
              label: showLabels ? t("workbench.settings") : undefined,
              icon: <GearIcon className={iconClassName} />,
              onClick: onSettingsClick,
              ariaLabel: t("workbench.settings"),
              tooltip: {
                content: t("workbench.settings"),
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
    ],
    [
      coreFeatures.git,
      coreFeatures.search,
      iconClassName,
      isFilesActive,
      isPrimarySidebarItemActive,
      isGitViewActive,
      isSearchActive,
      onSearchClick,
      onRunClick,
      onSettingsClick,
      isRunActive,
      onViewChange,
      showLabels,
      t,
      tooltipSide,
    ],
  );

  const orderedIds = useMemo(
    () =>
      normalizeItemOrder(
        sidebarActivityItemsOrder,
        items.map((item) => item.id),
      ),
    [items, sidebarActivityItemsOrder],
  );

  const orderedItems = orderItems(items, orderedIds);
  const visibleItems = orderedItems.filter((item) => !hiddenSidebarActivityItems.includes(item.id));
  const topItems = visibleItems.filter(
    (item) => !BOTTOM_ACTIVITY_ITEM_IDS.includes(item.id as (typeof BOTTOM_ACTIVITY_ITEM_IDS)[number]),
  );
  const bottomItems = BOTTOM_ACTIVITY_ITEM_IDS.map((id) =>
    visibleItems.find((item) => item.id === id),
  ).filter((item): item is SidebarPaneItem => Boolean(item));

  const renderVerticalItem = (item: SidebarPaneItem) => {
    const itemNode = (
      <SidebarListItem
        key={item.id}
        active={!!item.isActive}
        leading={item.icon}
        iconOnly={!showLabels}
        onClick={item.onClick}
        disabled={item.disabled}
        aria-label={item.ariaLabel}
        aria-current={item.isActive ? "page" : undefined}
        className="ui-text-sm min-h-6 py-1"
      >
        {item.label ?? item.ariaLabel ?? item.id}
      </SidebarListItem>
    );

    return item.tooltip && (!showLabels || item.disabled) ? (
      <Tooltip
        key={item.id}
        content={item.tooltip.content}
        shortcut={item.disabled ? undefined : item.tooltip.shortcut}
        side={item.tooltip.side}
        className={item.tooltip.className}
        triggerClassName="flex w-full"
      >
        {itemNode}
      </Tooltip>
    ) : (
      <span key={item.id} className="contents">
        {itemNode}
      </span>
    );
  };

  if (isVertical) {
    return (
      <nav aria-label="Activity views" className="flex h-full w-full flex-col">
        <div className="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
          {topItems.map(renderVerticalItem)}
        </div>
        {bottomItems.length > 0 ? (
          <div className="flex shrink-0 flex-col gap-1 pt-1">{bottomItems.map(renderVerticalItem)}</div>
        ) : null}
      </nav>
    );
  }

  const renderedItems = visibleItems.map((item) => {
    const tabNode = (
      <TabsTrigger
        key={item.id}
        value={item.id}
        aria-label={item.ariaLabel}
        disabled={item.disabled}
        size={compact ? "xs" : "sm"}
        className={cn(
          compact && "aspect-7/6 flex-none px-0",
          !compact && "flex-none",
          item.className,
        )}
      >
        {item.icon}
        {item.label ? (
          <span className="min-w-0 flex-1 truncate text-left">{item.label}</span>
        ) : null}
      </TabsTrigger>
    );

    const content =
      item.tooltip && (!showLabels || item.disabled) ? (
        <Tooltip
          key={item.id}
          content={item.tooltip.content}
          shortcut={item.disabled ? undefined : item.tooltip.shortcut}
          side={item.tooltip.side}
          className={item.tooltip.className}
        >
          {tabNode}
        </Tooltip>
      ) : (
        tabNode
      );

    return {
      id: item.id,
      content,
    };
  });

  return (
    <Tabs
      value={visibleItems.find((item) => item.isActive)?.id}
      onValueChange={(value) => visibleItems.find((item) => item.id === value)?.onClick?.()}
      className="gap-0"
    >
      <TabsList
        variant={compact ? "bare" : "default"}
        className={cn(!compact && "gap-0.5 p-1")}
        aria-label="Sidebar views"
      >
        {renderedItems.map((item) => (
          <span key={item.id} className="contents">
            {item.content}
          </span>
        ))}
      </TabsList>
    </Tabs>
  );
};
