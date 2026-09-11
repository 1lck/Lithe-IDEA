import type { ReactNode } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import {
  ArrowClockwiseIcon,
  BugIcon,
  CheckIcon,
  FileTextIcon,
  PackageIcon,
  PlayIcon,
  TerminalIcon,
} from "@/ui/icons";

export interface MavenModuleMenuAvailability {
  runDisabled: boolean;
  debugDisabled: boolean;
  buildDisabled: boolean;
  reloadDisabled: boolean;
}

export function resolveMavenModuleMenuAvailability(args: {
  busy: boolean;
  canRun: boolean;
  canDebug: boolean;
  debugging: boolean;
  reloading: boolean;
}): MavenModuleMenuAvailability {
  return {
    runDisabled: args.busy || !args.canRun,
    debugDisabled: args.busy || args.debugging || !args.canDebug,
    buildDisabled: args.busy,
    reloadDisabled: args.busy || args.reloading,
  };
}

interface MavenModuleContextMenuProps {
  children: ReactNode;
  availability: MavenModuleMenuAvailability;
  runUnavailableReason?: string;
  debugUnavailableReason?: string;
  onRun: () => void;
  onDebug: () => void;
  onTest: () => void;
  onPackage: () => void;
  onExecuteGoal: () => void;
  onOpenPom: () => void;
  onReload: () => void;
}

export function MavenModuleContextMenu({
  children,
  availability,
  runUnavailableReason,
  debugUnavailableReason,
  onRun,
  onDebug,
  onTest,
  onPackage,
  onExecuteGoal,
  onOpenPom,
  onReload,
}: MavenModuleContextMenuProps) {
  const { t } = useTranslation();
  return (
    <ContextMenu>
      <ContextMenuTrigger className="block" onContextMenu={(event) => event.stopPropagation()}>
        {children}
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem
          disabled={availability.runDisabled}
          title={availability.runDisabled ? runUnavailableReason : undefined}
          onClick={onRun}
        >
          <PlayIcon className="text-success" />
          {t("maven.run")}
        </ContextMenuItem>
        <ContextMenuItem
          disabled={availability.debugDisabled}
          title={availability.debugDisabled ? debugUnavailableReason : undefined}
          onClick={onDebug}
        >
          <BugIcon />
          {t("maven.debug")}
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem disabled={availability.buildDisabled} onClick={onTest}>
          <CheckIcon />
          {t("maven.test")}
        </ContextMenuItem>
        <ContextMenuItem disabled={availability.buildDisabled} onClick={onPackage}>
          <PackageIcon />
          {t("maven.package")}
        </ContextMenuItem>
        <ContextMenuItem disabled={availability.buildDisabled} onClick={onExecuteGoal}>
          <TerminalIcon />
          {t("maven.executeGoal")}
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem onClick={onOpenPom}>
          <FileTextIcon />
          {t("maven.openPom")}
        </ContextMenuItem>
        <ContextMenuItem disabled={availability.reloadDisabled} onClick={onReload}>
          <ArrowClockwiseIcon />
          {t("maven.reloadProjects")}
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}

export function MavenLifecycleContextMenu({
  children,
  disabled,
  onRun,
}: {
  children: ReactNode;
  disabled: boolean;
  onRun: () => void;
}) {
  const { t } = useTranslation();
  return (
    <ContextMenu>
      <ContextMenuTrigger className="block" onContextMenu={(event) => event.stopPropagation()}>
        {children}
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem disabled={disabled} onClick={onRun}>
          <PlayIcon className="text-success" />
          {t("maven.runPhase")}
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
