/**
 * Small building blocks shared by the Agent panel views, matching the macOS
 * `AgentPanelHeader`, `AgentEmptyStateView` and `AgentInlineNotice`.
 */

import type { ReactNode } from "react";
import { Button } from "@/ui/button";
import { WarningCircleIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";

/** Session title on the left, icon actions on the right; 44px like macOS. */
export function AgentPanelHeader({ title, children }: { title: string; children: ReactNode }) {
  return (
    <header className="flex h-11 shrink-0 items-center gap-0.5 border-border border-b bg-surface pr-1.5 pl-5">
      <h2 className="min-w-0 flex-1 truncate font-semibold text-foreground ui-text-sm">{title}</h2>
      {children}
    </header>
  );
}

interface AgentToolbarButtonProps {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  active?: boolean;
  children: ReactNode;
}

/** 28px icon button with a tooltip, as `AgentToolbarButtonStyle`. */
export function AgentToolbarButton({
  label,
  onClick,
  disabled,
  active,
  children,
}: AgentToolbarButtonProps) {
  return (
    <Button
      type="button"
      size="icon-sm"
      variant="ghost"
      active={active}
      tooltip={label}
      aria-label={label}
      disabled={disabled}
      onClick={onClick}
    >
      {children}
    </Button>
  );
}

interface AgentEmptyStateProps {
  icon: ReactNode;
  title: string;
  message: string;
  isBusy?: boolean;
  action?: { label: string; onClick: () => void };
  secondaryAction?: { label: string; onClick: () => void };
}

/** Centered state that fills the transcript area. */
export function AgentEmptyState({
  icon,
  title,
  message,
  isBusy = false,
  action,
  secondaryAction,
}: AgentEmptyStateProps) {
  return (
    <div className="flex h-full min-h-0 flex-col items-center justify-center gap-2.5 p-6 text-center">
      <div className="text-subtle-foreground [&_svg]:size-7">
        {isBusy ? <Spinner className="size-5" /> : icon}
      </div>
      <div className="font-semibold text-foreground ui-text-sm">{title}</div>
      <div className="select-text text-subtle-foreground ui-text-sm">{message}</div>
      {action === undefined && secondaryAction === undefined ? null : (
        <div className="flex gap-2 pt-1">
          {action === undefined ? null : (
            <Button type="button" size="sm" variant="default" onClick={action.onClick}>
              {action.label}
            </Button>
          )}
          {secondaryAction === undefined ? null : (
            <Button type="button" size="sm" variant="default" onClick={secondaryAction.onClick}>
              {secondaryAction.label}
            </Button>
          )}
        </div>
      )}
    </div>
  );
}

/** Warning box under the transcript for errors that keep the conversation. */
export function AgentInlineNotice({
  text,
  action,
}: {
  text: string;
  action?: { label: string; onClick: () => void };
}) {
  return (
    <div className="mx-3 mb-1 flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/12 p-2.5 text-foreground ui-text-sm">
      <WarningCircleIcon className="mt-0.5 size-3.5 shrink-0 text-warning" />
      <span className="min-w-0 flex-1 select-text">{text}</span>
      {action === undefined ? null : (
        <Button type="button" size="xs" variant="default" onClick={action.onClick}>
          {action.label}
        </Button>
      )}
    </div>
  );
}
