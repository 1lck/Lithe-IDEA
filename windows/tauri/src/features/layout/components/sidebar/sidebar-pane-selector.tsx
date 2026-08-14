import { useMemo, type ReactNode } from "react";
import {
  BACKEND_UNAVAILABLE_TOOLTIP,
  isBackendCapabilityAvailable,
} from "@/config/backend-capabilities";
import type { CoreFeaturesState } from "@/features/settings/types/feature.types";
import { useExtensionViews } from "@/extensions/ui/hooks/use-extension-views";
import { DynamicIcon } from "@/extensions/ui/components/dynamic-icon";
import { normalizeItemOrder } from "@/features/layout/config/item-order";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { SidebarListItem } from "@/ui/sidebar";
import { Tabs, TabsList, TabsTrigger } from "@/ui/tabs";
import {
  BoxIcon,
  GitBranchIcon,
  ExtensionsIcon,
  FilesIcon,
  GitPullRequestIcon,
  MagnifyingGlassIcon,
} from "@/ui/icons";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import type { SidebarView } from "../../utils/sidebar-pane-utils";

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
  isGitHubPRsViewActive: boolean;
  isSidebarVisible?: boolean;
  coreFeatures: CoreFeaturesState;
  onViewChange: (view: SidebarView) => void;
  onSearchClick?: () => void;
  onExtensionsClick?: () => void;
  isSearchActive?: boolean;
  isExtensionsActive?: boolean;
  compact?: boolean;
  showLabels?: boolean;
  orientation?: "horizontal" | "vertical";
}

export const SidebarPaneSelector = ({
  activeSidebarView,
  isGitViewActive,
  isGitHubPRsViewActive,
  isSidebarVisible = true,
  coreFeatures,
  onViewChange,
  onSearchClick,
  onExtensionsClick,
  isSearchActive = false,
  isExtensionsActive = false,
  compact = false,
  showLabels = false,
  orientation = "horizontal",
}: SidebarPaneSelectorProps) => {
  const isVertical = orientation === "vertical";
  const tooltipSide = isVertical ? "right" : "bottom";
  const iconClassName = compact || isVertical ? "size-4" : undefined;
  const isBufferOwnedSurfaceActive = isSearchActive || isExtensionsActive;
  const isPrimarySidebarItemActive = isSidebarVisible && !isBufferOwnedSurfaceActive;
  const isFilesActive =
    isPrimarySidebarItemActive &&
    !isGitViewActive &&
    !isGitHubPRsViewActive &&
    activeSidebarView === "files";
  const extensionViews = useExtensionViews();
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
        label: showLabels ? "Files" : undefined,
        icon: <FilesIcon className={iconClassName} />,
        isActive: isFilesActive,
        onClick: () => onViewChange("files"),
        ariaLabel: "Files",
        tooltip: {
          content: "Files",
          shortcut: "Mod+Shift+E",
          side: tooltipSide,
        },
      },
      ...(coreFeatures.search && onSearchClick
        ? [
            {
              id: "search",
              label: showLabels ? "Search" : undefined,
              icon: <MagnifyingGlassIcon className={iconClassName} />,
              isActive: isSearchActive,
              onClick: onSearchClick,
              ariaLabel: "Search",
              tooltip: {
                content: "Search",
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
              label: showLabels ? "Source Control" : undefined,
              icon: <GitBranchIcon className={iconClassName} />,
              isActive: isPrimarySidebarItemActive && isGitViewActive,
              onClick: () => onViewChange("git"),
              disabled: !isBackendCapabilityAvailable("git"),
              ariaLabel: "Git Source Control",
              tooltip: {
                content: isBackendCapabilityAvailable("git")
                  ? "Source Control"
                  : BACKEND_UNAVAILABLE_TOOLTIP,
                shortcut: "Mod+Shift+G",
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      ...(coreFeatures.github
        ? [
            {
              id: "github-prs",
              label: showLabels ? "Pull Requests" : undefined,
              icon: <GitPullRequestIcon className={iconClassName} />,
              isActive: isPrimarySidebarItemActive && isGitHubPRsViewActive,
              onClick: () => onViewChange("github-prs"),
              disabled: !isBackendCapabilityAvailable("github"),
              ariaLabel: "GitHub Pull Requests",
              tooltip: {
                content: isBackendCapabilityAvailable("github")
                  ? "Pull Requests"
                  : BACKEND_UNAVAILABLE_TOOLTIP,
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      ...(coreFeatures.docker
        ? [
            {
              id: "docker",
              label: showLabels ? "Docker" : undefined,
              icon: <BoxIcon className={iconClassName} />,
              isActive: isPrimarySidebarItemActive && activeSidebarView === "docker",
              onClick: () => onViewChange("docker"),
              disabled: !isBackendCapabilityAvailable("docker"),
              ariaLabel: "Docker",
              tooltip: {
                content: isBackendCapabilityAvailable("docker")
                  ? "Docker"
                  : BACKEND_UNAVAILABLE_TOOLTIP,
                side: tooltipSide,
              },
            } satisfies SidebarPaneItem,
          ]
        : []),
      {
        id: "extensions",
        label: showLabels ? "Extensions" : undefined,
        icon: <ExtensionsIcon className={iconClassName} />,
        isActive: isExtensionsActive,
        onClick: onExtensionsClick ?? (() => onViewChange("extensions")),
        disabled: !isBackendCapabilityAvailable("extensions"),
        ariaLabel: "Extensions",
        tooltip: {
          content: isBackendCapabilityAvailable("extensions")
            ? "Extensions"
            : BACKEND_UNAVAILABLE_TOOLTIP,
          side: tooltipSide,
        },
      },
      ...Array.from(extensionViews.values()).map(
        (view) =>
          ({
            id: view.id,
            label: showLabels ? view.title : undefined,
            icon: <DynamicIcon name={view.icon} className={iconClassName} />,
            isActive: isPrimarySidebarItemActive && activeSidebarView === view.id,
            onClick: () => onViewChange(view.id),
            disabled: !isBackendCapabilityAvailable("extensions"),
            ariaLabel: view.title,
            tooltip: {
              content: isBackendCapabilityAvailable("extensions")
                ? view.title
                : BACKEND_UNAVAILABLE_TOOLTIP,
              side: tooltipSide,
            },
          }) satisfies SidebarPaneItem,
      ),
    ],
    [
      activeSidebarView,
      coreFeatures.git,
      coreFeatures.github,
      coreFeatures.docker,
      coreFeatures.search,
      extensionViews,
      iconClassName,
      isFilesActive,
      isPrimarySidebarItemActive,
      isGitHubPRsViewActive,
      isGitViewActive,
      isSearchActive,
      isExtensionsActive,
      isSidebarVisible,
      onExtensionsClick,
      onSearchClick,
      onViewChange,
      showLabels,
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

  if (isVertical) {
    return (
      <nav aria-label="Activity views" className="flex w-full flex-col gap-1">
        {visibleItems.map((item) => {
          const itemNode = (
            <SidebarListItem
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
        })}
      </nav>
    );
  }

  const renderedItems = visibleItems.map((item) => {
    const tabNode = (
      <TabsTrigger
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
