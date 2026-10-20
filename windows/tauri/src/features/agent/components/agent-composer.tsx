import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import {
  AGENT_FILE_DROP_EVENT,
  AGENT_FILE_DROP_HOVER_EVENT,
  type AgentFileDropDetail,
  type AgentFileDropHoverDetail,
} from "@/features/file-system/utils/file-system-drop-controller";
import { extractDroppedFilePaths } from "@/features/file-system/utils/file-system-dropped-paths";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { useTranslation } from "@/i18n/locale-provider";
import {
  CheckIcon,
  FileTextIcon,
  PaperclipIcon,
  PaperPlaneTiltIcon,
  SlidersHorizontalIcon,
  SquareIcon,
  XIcon,
} from "@/ui/icons";
import { Popover, PopoverContent, PopoverTrigger } from "@/ui/popover";
import { Spinner } from "@/ui/spinner";
import { cn } from "@/utils/cn";
import { useAgentSnapshot } from "../hooks/use-agent-connection";
import {
  agentMentionQuery,
  removeAgentMention,
  type AgentMentionQuery,
} from "../services/agent-composer-mentions";
import {
  commandInvocation,
  commandSuggestions,
  completedCommandDraft,
  resolveCommandKey,
  type AgentCommandKeyState,
} from "../services/agent-command-completion";
import { chooseAgentFiles } from "../services/agent-file-picker";
import { agentConnection } from "../stores/agent-connection-service";
import { agentFileUri } from "../types/agent-file-uri";
import {
  addFileReferences,
  AgentFileReferenceError,
  AgentFileReferenceLimitError,
  type AgentCommand,
  type AgentConversation,
  type AgentFileReference,
} from "../types/agent.types";
import { AgentBrandIcon } from "./brand/agent-brand-icon";
import { AgentSessionSelectors } from "./agent-session-selectors";
import { AgentContextUsageView, AgentSubscriptionQuotaView } from "./agent-usage-panel";

const EMPTY_PROJECT_FILES: FileEntry[] = [];
const FILE_RESULT_LIMIT = 50;

function candidateFiles(entries: FileEntry[], limit: number): FileEntry[] {
  const result: FileEntry[] = [];
  const walk = (nodes: FileEntry[]) => {
    for (const node of nodes) {
      if (result.length >= limit) return;
      if (node.isDir) {
        if (node.children !== undefined) walk(node.children);
        continue;
      }
      result.push(node);
    }
  };
  walk(entries);
  return result;
}

/** Shorten a file name in the middle, as macOS `.truncationMode(.middle)`. */
function middleTruncate(name: string, maxLength = 28): string {
  if (name.length <= maxLength) return name;
  const keep = maxLength - 1;
  return `${name.slice(0, Math.ceil(keep / 2))}…${name.slice(name.length - Math.floor(keep / 2))}`;
}

function uriPath(uri: string): string {
  try {
    const path = decodeURIComponent(new URL(uri).pathname);
    return /^\/[A-Za-z]:\//.test(path) ? path.slice(1) : path;
  } catch {
    return uri;
  }
}

interface AgentComposerProps {
  conversation: AgentConversation | null;
  agentName: string | null;
  /** False while the conversation cannot accept a prompt yet. */
  canSend: boolean;
  /** Why sending is refused, shown when the user tries anyway. */
  blockedReason: string;
  draft: string;
  onDraftChange: (draft: string) => void;
  files: AgentFileReference[];
  onFilesChange: (files: AgentFileReference[]) => void;
  onOpenSettings: () => void;
  onError: (message: string | null) => void;
}

/**
 * Context strip, flexible writing area and a compact command bar, as
 * `AgentComposerView` on macOS. Typing is always allowed; sending validates
 * the setup and reports what is missing instead of hiding the composer.
 */
export function AgentComposer({
  conversation,
  agentName,
  canSend,
  blockedReason,
  draft,
  onDraftChange,
  files,
  onFilesChange,
  onOpenSettings,
  onError,
}: AgentComposerProps) {
  const { t } = useTranslation();
  const snapshot = useAgentSnapshot();
  const projectFiles = useFileSystemStore(
    (state) => state.projectFilesCache?.files ?? EMPTY_PROJECT_FILES,
  );
  const activeFilePath = useBufferStore((state) => {
    const active = state.buffers.find((buffer) => buffer.isActive);
    return typeof active?.path === "string" ? active.path : null;
  });
  const [isFocused, setIsFocused] = useState(false);
  const [isHovering, setIsHovering] = useState(false);
  const [isDropTargeted, setIsDropTargeted] = useState(false);
  const [mention, setMention] = useState<AgentMentionQuery | null>(null);
  const [fileQuery, setFileQuery] = useState("");
  const [commandKey, setCommandKey] = useState<AgentCommandKeyState>({
    highlightedIndex: 0,
    dismissed: false,
  });
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);

  const isResponding = conversation?.isResponding === true;
  const isCancelling = conversation?.isCancelling === true;
  const isConfiguring = conversation?.pendingConfigToken != null;
  const canSteer = snapshot.canSteer;
  const isSendingSupplement = conversation?.pendingSteeringToken != null;
  const hasPendingContinuation = snapshot.hasPendingContinuation;
  const hasContent = draft.trim().length > 0 || files.length > 0;
  const sessionID = snapshot.selectedSessionID;

  useEffect(() => {
    textareaRef.current?.focus();
  }, []);

  const attach = useCallback(
    (paths: string[]) => {
      if (paths.length === 0) return;
      try {
        // Validate outside the state updater: React may replay an updater while
        // rendering, where a thrown limit error would break the panel instead of
        // reporting the limit.
        onFilesChange(addFileReferences(files, paths.map(agentFileUri)));
        onError(null);
        textareaRef.current?.focus();
      } catch (error) {
        // The batch size is the one reference error the user can act on, and the
        // message the shared helper builds is Core-facing English.
        if (error instanceof AgentFileReferenceLimitError) {
          onError(t("agent.composer.fileLimit", { count: error.limit }));
          return;
        }
        onError(error instanceof AgentFileReferenceError ? error.message : String(error));
      }
    },
    [files, onError, onFilesChange, t],
  );

  // OS drops in WebView2 and project-tree drags arrive as this event instead.
  useEffect(() => {
    const root = rootRef.current;
    if (root === null) return;
    const handleRoutedDrop = (event: Event) => {
      attach((event as CustomEvent<AgentFileDropDetail>).detail?.paths ?? []);
    };
    const handleRoutedHover = (event: Event) => {
      setIsDropTargeted((event as CustomEvent<AgentFileDropHoverDetail>).detail?.active === true);
    };
    root.addEventListener(AGENT_FILE_DROP_EVENT, handleRoutedDrop);
    root.addEventListener(AGENT_FILE_DROP_HOVER_EVENT, handleRoutedHover);
    return () => {
      root.removeEventListener(AGENT_FILE_DROP_EVENT, handleRoutedDrop);
      root.removeEventListener(AGENT_FILE_DROP_HOVER_EVENT, handleRoutedHover);
    };
  }, [attach]);

  const handleDrop = useCallback(
    (event: DragEvent<HTMLDivElement>) => {
      event.preventDefault();
      setIsDropTargeted(false);
      attach(extractDroppedFilePaths(event.dataTransfer));
    },
    [attach],
  );

  const chooseFiles = useCallback(() => {
    void chooseAgentFiles()
      .then(attach)
      .catch((error: unknown) => onError(error instanceof Error ? error.message : String(error)));
  }, [attach, onError]);

  const pickMention = useCallback(
    (path: string) => {
      attach([path]);
      // The `@query` text that opened the picker is replaced by the reference.
      if (mention !== null) onDraftChange(removeAgentMention(draft, mention));
      setMention(null);
      setFileQuery("");
    },
    [attach, draft, mention, onDraftChange],
  );

  // A new draft starts at the first row and reopens a dismissed list.
  useEffect(() => {
    setCommandKey({ highlightedIndex: 0, dismissed: false });
  }, [draft]);

  const send = useCallback(() => {
    if (!hasContent || isSendingSupplement || hasPendingContinuation) return;
    // While responding, the input becomes a supplementary message only when
    // the Agent negotiated steering; otherwise the Stop button is the action.
    if (isResponding && !canSteer) return;
    if (!canSend) {
      onError(blockedReason);
      return;
    }
    try {
      agentConnection().send(
        draft,
        files.map((file) => file.uri),
      );
      onDraftChange("");
      onFilesChange([]);
      setMention(null);
      setCommandKey({ highlightedIndex: 0, dismissed: false });
      onError(null);
    } catch (error) {
      onError(error instanceof Error ? error.message : String(error));
    }
  }, [
    blockedReason,
    canSend,
    canSteer,
    draft,
    files,
    hasContent,
    hasPendingContinuation,
    isResponding,
    isSendingSupplement,
    onError,
    onDraftChange,
    onFilesChange,
  ]);

  const matches = useMemo(() => {
    if (mention === null) return [];
    const query = fileQuery.trim().toLowerCase();
    const candidates = candidateFiles(projectFiles, FILE_RESULT_LIMIT * 4);
    const filtered =
      query.length === 0
        ? candidates
        : candidates.filter((file) => file.path.toLowerCase().includes(query));
    return filtered.slice(0, FILE_RESULT_LIMIT);
  }, [fileQuery, mention, projectFiles]);

  const commands = conversation?.availableCommands ?? [];
  const commandList =
    mention !== null || commandKey.dismissed ? null : commandSuggestions(draft, commands);

  const completeCommand = useCallback(
    (command: AgentCommand) => {
      onDraftChange(completedCommandDraft(command));
      setCommandKey({ highlightedIndex: 0, dismissed: false });
      textareaRef.current?.focus();
    },
    [onDraftChange],
  );

  const options = conversation?.configOptions ?? [];
  const usesSubscription = snapshot.usesSubscription;

  return (
    <div className="h-full px-2 pb-2">
      <div
        ref={rootRef}
        data-agent-file-drop-target
        className={cn(
          "flex h-full min-h-0 flex-col rounded-lg border bg-background",
          isFocused || isHovering || isDropTargeted
            ? "border-primary"
            : "border-subtle-foreground/45",
        )}
        onMouseEnter={() => setIsHovering(true)}
        onMouseLeave={() => setIsHovering(false)}
        onDrop={handleDrop}
        onDragOver={(event) => event.preventDefault()}
        onDragEnter={(event) => {
          if (!Array.from(event.dataTransfer.types).includes("Files")) return;
          event.preventDefault();
          setIsDropTargeted(true);
        }}
        onDragLeave={(event) => {
          // Moving between children also fires dragleave on the container.
          if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
          setIsDropTargeted(false);
        }}
        onKeyDown={(event) => {
          if (
            event.key === "Escape" &&
            (isResponding || hasPendingContinuation) &&
            !isCancelling
          ) {
            agentConnection().cancel();
          }
        }}
      >
        <div className="m-px flex h-7 shrink-0 items-center gap-2 rounded-[7px] bg-muted/60 px-2.5 text-subtle-foreground ui-text-caption">
          <AgentContextUsageView usage={conversation?.contextUsage ?? null} />
          <span aria-hidden className="h-3 w-px bg-border" />
          <button
            type="button"
            title={t("agent.composer.attachHint")}
            className="flex items-center gap-1 hover:text-foreground"
            onClick={chooseFiles}
          >
            <PaperclipIcon className="size-3" />
            {isDropTargeted ? t("agent.composer.dropHere") : t("agent.composer.attachFiles")}
          </button>
          {activeFilePath === null ? null : (
            <button
              type="button"
              className="truncate hover:text-foreground"
              onClick={() => attach([activeFilePath])}
            >
              {t("agent.composer.attachActive")}
            </button>
          )}
          <span className="flex-1" />
          {usesSubscription ? (
            <AgentSubscriptionQuotaView
              quota={snapshot.subscriptionQuota}
              account={snapshot.subscriptionEmail}
              failure={snapshot.quotaFailure}
            />
          ) : null}
        </div>

        {files.length === 0 ? null : (
          <div className="flex shrink-0 gap-1.5 overflow-x-auto px-2 pt-1.5 [scrollbar-width:none]">
            {files.map((file) => (
              <span
                key={file.uri}
                title={uriPath(file.uri)}
                className="flex shrink-0 items-center gap-1 rounded bg-muted px-1.5 py-0.5 text-foreground ui-text-caption"
              >
                <FileTextIcon className="size-3 text-subtle-foreground" />
                <span className="max-w-40">{middleTruncate(file.name)}</span>
                <button
                  type="button"
                  aria-label={t("agent.composer.removeAttachment", { name: file.name })}
                  className="text-subtle-foreground hover:text-foreground"
                  onClick={() => onFilesChange(files.filter((entry) => entry.uri !== file.uri))}
                >
                  <XIcon className="size-2.5" />
                </button>
              </span>
            ))}
          </div>
        )}

        {mention === null ? null : (
          <div className="mx-2 mt-1.5 max-h-40 shrink-0 overflow-auto rounded-md border border-border py-0.5">
            {matches.length === 0 ? (
              <div className="px-2 py-1 text-subtle-foreground ui-text-caption">
                {t("agent.composer.noFiles")}
              </div>
            ) : (
              matches.map((file) => (
                <button
                  key={file.path}
                  type="button"
                  className="flex w-full items-center px-2 py-0.5 text-left text-foreground ui-text-sm hover:bg-accent"
                  onClick={() => pickMention(file.path)}
                >
                  <span className="truncate">{file.path}</span>
                </button>
              ))
            )}
          </div>
        )}

        <div className="relative flex min-h-0 flex-1 flex-col">
          {commandList === null ? null : (
            <div
              role="listbox"
              aria-label={t("agent.composer.commands")}
              className="absolute inset-x-0 bottom-full z-20 mb-1 max-h-[168px] overflow-y-auto rounded-[7px] border border-border bg-surface py-[3px] shadow-lg"
            >
              {commandList.length === 0 ? (
                <div className="px-2.5 py-1 text-subtle-foreground ui-text-caption">
                  {t("agent.composer.noCommands")}
                </div>
              ) : (
                commandList.map((command, index) => (
                  <button
                    key={command.name}
                    type="button"
                    role="option"
                    aria-selected={index === commandKey.highlightedIndex}
                    title={
                      command.hint === null
                        ? command.description
                        : `${commandInvocation(command)} ${command.hint}`
                    }
                    className={cn(
                      "flex h-[26px] w-full items-center gap-2 px-2.5 text-left",
                      index === commandKey.highlightedIndex ? "bg-accent" : "hover:bg-accent/60",
                    )}
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={() => completeCommand(command)}
                  >
                    <span className="shrink-0 font-mono font-medium text-[11.5px] text-foreground">
                      {commandInvocation(command)}
                    </span>
                    <span className="truncate text-[11.5px] text-subtle-foreground">
                      {command.description}
                    </span>
                  </button>
                ))
              )}
            </div>
          )}
          <textarea
            ref={textareaRef}
          value={draft}
          aria-label={t("agent.composer.message")}
          placeholder={t("agent.composer.messageHint")}
          className="min-h-0 w-full flex-1 resize-none bg-transparent px-2 py-2.5 text-foreground outline-none ui-text-base placeholder:text-subtle-foreground"
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          onChange={(event) => {
            const value = event.target.value;
            onDraftChange(value);
            // Typing `@` opens the picker on the unfinished reference at the caret.
            const caret = event.target.selectionStart ?? value.length;
            const opened = agentMentionQuery(value.slice(0, caret));
            setMention(opened);
            setFileQuery(opened?.query ?? "");
          }}
          onKeyDown={(event) => {
            if (commandList !== null && !event.nativeEvent.isComposing) {
              const key =
                event.key === "Enter" && !event.shiftKey
                  ? "submit"
                  : event.key === "Escape"
                    ? "escape"
                    : event.key === "ArrowUp"
                      ? "up"
                      : event.key === "ArrowDown"
                        ? "down"
                        : event.key === "Tab"
                          ? "tab"
                          : null;
              if (key !== null) {
                const outcome = resolveCommandKey(commandKey, key, draft, commands, isResponding);
                if (outcome.kind === "handled") {
                  event.preventDefault();
                  // The list consumed Escape; do not let the composer's outer
                  // handler also cancel the running turn.
                  if (key === "escape") event.stopPropagation();
                  setCommandKey(outcome.state);
                  return;
                }
                if (outcome.kind === "complete") {
                  event.preventDefault();
                  completeCommand(outcome.command);
                  return;
                }
                if (outcome.kind === "send") {
                  event.preventDefault();
                  send();
                  return;
                }
                if (outcome.kind === "cancel") {
                  event.preventDefault();
                  agentConnection().cancel();
                  return;
                }
              }
            }
            if (event.key === "Escape" && mention !== null) {
              event.stopPropagation();
              setMention(null);
              return;
            }
            if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
              event.preventDefault();
              send();
            }
          }}
          />
        </div>

        <div className="m-px flex h-9 shrink-0 items-center gap-1 rounded-[7px] bg-muted/40 px-[5px]">
          <button
            type="button"
            aria-label={t("agent.actions.settings")}
            title={t("agent.actions.settings")}
            className="flex size-7 items-center justify-center rounded text-subtle-foreground hover:bg-accent"
            onClick={onOpenSettings}
          >
            <SlidersHorizontalIcon className="size-3.5" />
          </button>
          <AgentMenu agentName={agentName} onOpenSettings={onOpenSettings} />
          {options.length > 0 ? (
            <>
              <AgentSessionSelectors
                key={sessionID ?? agentName ?? "none"}
                options={options}
                agentName={agentName}
                isDisabled={!canSend || isResponding || isConfiguring}
                onSelect={(id, value) => agentConnection().setConfigOption(id, value)}
              />
              {isConfiguring ? <Spinner className="size-3" /> : null}
            </>
          ) : null}
          <span className="flex-1" />
          {isResponding || hasPendingContinuation ? (
            <button
              type="button"
              aria-label={isCancelling ? t("agent.composer.cancelling") : t("agent.composer.stop")}
              title={isCancelling ? t("agent.composer.cancelling") : t("agent.composer.stop")}
              disabled={isCancelling}
              className="flex size-[26px] items-center justify-center rounded bg-muted text-destructive disabled:cursor-default"
              onClick={() => agentConnection().cancel()}
            >
              <SquareIcon className="size-3 fill-current" />
            </button>
          ) : null}
          <button
            type="button"
            aria-label={
              isSendingSupplement ? t("agent.composer.sending") : t("agent.composer.send")
            }
            title={isSendingSupplement ? t("agent.composer.sending") : t("agent.composer.send")}
            disabled={
              isCancelling ||
              isSendingSupplement ||
              hasPendingContinuation ||
              (isResponding && !canSteer) ||
              !hasContent ||
              isConfiguring
            }
            className={cn(
              "flex size-[26px] items-center justify-center rounded bg-muted disabled:cursor-default",
              hasContent && (!isResponding || canSteer)
                ? "text-foreground"
                : "text-subtle-foreground/70",
            )}
            onClick={send}
          >
            <PaperPlaneTiltIcon className="size-3.5" />
          </button>
        </div>
      </div>
    </div>
  );
}

/** Brand mark that switches agents, as the macOS composer's agent menu. */
function AgentMenu({
  agentName,
  onOpenSettings,
}: {
  agentName: string | null;
  onOpenSettings: () => void;
}) {
  const { t } = useTranslation();
  const [isOpen, setIsOpen] = useState(false);
  return (
    <Popover open={isOpen} onOpenChange={setIsOpen}>
      <PopoverTrigger
        aria-label={t("agent.actions.switchAgent")}
        title={agentName ?? t("agent.composer.chooseAgent")}
        render={<button type="button" />}
      >
        <span className="flex size-7 items-center justify-center rounded text-subtle-foreground hover:bg-accent">
          <AgentBrandIcon name={agentName} size={16} variant="brand" />
        </span>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="w-48 gap-0 p-1">
        {agentName === null ? (
          <div className="px-2.5 py-1.5 text-subtle-foreground ui-text-sm">
            {t("agent.composer.noAgent")}
          </div>
        ) : (
          <div className="flex items-center gap-2 rounded px-2.5 py-1.5 text-foreground ui-text-sm">
            <AgentBrandIcon name={agentName} size={14} variant="brand" />
            <span className="flex-1">{agentName}</span>
            <CheckIcon className="size-3" />
          </div>
        )}
        <div className="my-1 h-px bg-border" />
        <button
          type="button"
          className="w-full rounded px-2.5 py-1.5 text-left text-foreground ui-text-sm hover:bg-accent"
          onClick={() => {
            setIsOpen(false);
            onOpenSettings();
          }}
        >
          {t("agent.composer.agentSettings")}
        </button>
      </PopoverContent>
    </Popover>
  );
}
