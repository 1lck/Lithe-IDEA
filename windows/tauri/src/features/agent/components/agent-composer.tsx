import { useCallback, useMemo, useState, type DragEvent } from "react";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { extractDroppedFilePaths } from "@/features/file-system/utils/file-system-dropped-paths";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import type { FileEntry } from "@/features/file-system/types/app.types";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { FilePlusIcon, PaperPlaneTiltIcon, StopIcon, XIcon } from "@/ui/icons";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import Textarea from "@/ui/textarea";
import { cn } from "@/utils/cn";
import { useAgentSnapshot } from "../hooks/use-agent-connection";
import {
  agentMentionQuery,
  removeAgentMention,
  type AgentMentionQuery,
} from "../services/agent-composer-mentions";
import { agentConnection } from "../stores/agent-connection-service";
import { agentFileUri } from "../types/agent-file-uri";
import {
  addFileReferences,
  AgentFileReferenceError,
  configOptionLabel,
  type AgentConversation,
  type AgentFileReference,
} from "../types/agent.types";
import { AgentUsagePanel } from "./agent-usage-panel";

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

interface AgentComposerProps {
  conversation: AgentConversation | null;
  /** False while the conversation cannot accept a new turn. */
  canSend: boolean;
}

/**
 * Prompt entry for the selected conversation: the session options the agent
 * reported, the draft, its attached project files, and send or stop.
 */
export function AgentComposer({ conversation, canSend }: AgentComposerProps) {
  const { t } = useTranslation();
  const snapshot = useAgentSnapshot();
  const projectFiles = useFileSystemStore(
    (state) => state.projectFilesCache?.files ?? EMPTY_PROJECT_FILES,
  );
  const activeFilePath = useBufferStore((state) => {
    const active = state.buffers.find((buffer) => buffer.isActive);
    return typeof active?.path === "string" ? active.path : null;
  });
  const [draft, setDraft] = useState("");
  const [files, setFiles] = useState<AgentFileReference[]>([]);
  const [composerError, setComposerError] = useState<string | null>(null);
  const [isPickingFile, setIsPickingFile] = useState(false);
  const [fileQuery, setFileQuery] = useState("");
  const [isDropTargeted, setIsDropTargeted] = useState(false);
  const [mention, setMention] = useState<AgentMentionQuery | null>(null);

  const isResponding = conversation?.isResponding === true;
  const isCancelling = conversation?.isCancelling === true;
  const isCreatingSession = snapshot.isCreatingSession;

  const attach = useCallback((paths: string[]) => {
    if (paths.length === 0) return;
    try {
      setFiles((current) => addFileReferences(current, paths.map(agentFileUri)));
      setComposerError(null);
    } catch (error) {
      setComposerError(error instanceof AgentFileReferenceError ? error.message : String(error));
    }
  }, []);

  const closePicker = useCallback(() => {
    setIsPickingFile(false);
    setMention(null);
    setFileQuery("");
  }, []);

  const pickFile = useCallback(
    (path: string) => {
      attach([path]);
      // The `@query` text that opened the picker is replaced by the reference.
      if (mention !== null) setDraft((current) => removeAgentMention(current, mention));
      closePicker();
    },
    [attach, closePicker, mention],
  );

  /** A dropped file is referenced by absolute path, exactly like a picked one. */
  const handleDrop = useCallback(
    (event: DragEvent<HTMLDivElement>) => {
      event.preventDefault();
      setIsDropTargeted(false);
      attach(extractDroppedFilePaths(event.dataTransfer));
    },
    [attach],
  );

  const handleDragEnter = useCallback((event: DragEvent<HTMLDivElement>) => {
    if (!Array.from(event.dataTransfer.types).includes("Files")) return;
    event.preventDefault();
    setIsDropTargeted(true);
  }, []);

  const handleDragLeave = useCallback((event: DragEvent<HTMLDivElement>) => {
    // Moving between children also fires dragleave on the container.
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    setIsDropTargeted(false);
  }, []);

  const send = useCallback(() => {
    if (isResponding) return;
    const text = draft.trim();
    if (text.length === 0 && files.length === 0) return;
    try {
      agentConnection().send(text, files.map((file) => file.uri));
      setDraft("");
      setFiles([]);
      closePicker();
      setComposerError(null);
    } catch (error) {
      setComposerError(error instanceof Error ? error.message : String(error));
    }
  }, [closePicker, draft, files, isResponding]);

  const matches = useMemo(() => {
    const query = fileQuery.trim().toLowerCase();
    const candidates = candidateFiles(projectFiles, FILE_RESULT_LIMIT * 4);
    const filtered =
      query.length === 0
        ? candidates
        : candidates.filter((file) => file.path.toLowerCase().includes(query));
    return filtered.slice(0, FILE_RESULT_LIMIT);
  }, [fileQuery, projectFiles]);

  const options = conversation?.configOptions ?? [];

  return (
    <div
      className={cn("border-border/70 border-t p-2", isDropTargeted && "bg-accent/30")}
      onDrop={handleDrop}
      onDragOver={(event) => event.preventDefault()}
      onDragEnter={handleDragEnter}
      onDragLeave={handleDragLeave}
    >
      {isDropTargeted ? (
        <div className="mb-1 text-subtle-foreground ui-text-caption">
          {t("agent.composer.dropFiles")}
        </div>
      ) : null}
      {options.length === 0 ? null : (
        <div className="mb-1.5 flex flex-wrap gap-1">
          {options.map((option) => (
            <Select
              key={option.id}
              size="xs"
              variant="ghost"
              value={option.currentValue}
              title={configOptionLabel(option)}
              aria-label={configOptionLabel(option)}
              options={option.choices.map((choice) => ({
                value: choice.id,
                label: choice.name,
              }))}
              disabled={option.choices.length === 0}
              onChange={(value) => agentConnection().setConfigOption(option.id, value)}
            />
          ))}
        </div>
      )}

      {files.length === 0 ? null : (
        <div className="mb-1 flex flex-wrap gap-1">
          {files.map((file) => (
            <span
              key={file.uri}
              className="flex max-w-full items-center gap-1 rounded-sm bg-muted px-1.5 py-0.5 text-subtle-foreground ui-text-caption"
              title={file.uri}
            >
              <span className="max-w-40 truncate">{file.name}</span>
              <button
                type="button"
                aria-label={t("agent.composer.removeFile", { name: file.name })}
                onClick={() =>
                  setFiles((current) => current.filter((entry) => entry.uri !== file.uri))
                }
              >
                <XIcon className="size-3" />
              </button>
            </span>
          ))}
        </div>
      )}

      {isPickingFile ? (
        <div className="mb-1 rounded-lg border border-border/70">
          <input
            autoFocus
            value={fileQuery}
            placeholder={t("agent.composer.searchFiles")}
            className="w-full border-border/70 border-b bg-transparent px-2 py-1 text-foreground outline-none ui-text-sm"
            onChange={(event) => setFileQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") closePicker();
            }}
          />
          <div className="max-h-40 overflow-auto py-0.5">
            {matches.length === 0 ? (
              <div className="px-2 py-1 text-subtle-foreground ui-text-caption">
                {t("agent.composer.noFiles")}
              </div>
            ) : (
              matches.map((file) => (
                <button
                  key={file.path}
                  type="button"
                  className="flex w-full items-center px-2 py-0.5 text-left hover:bg-accent ui-text-sm"
                  onClick={() => pickFile(file.path)}
                >
                  <span className="truncate text-foreground">{file.path}</span>
                </button>
              ))
            )}
          </div>
        </div>
      ) : null}

      <Textarea
        size="sm"
        rows={3}
        value={draft}
        placeholder={t("agent.composer.placeholder")}
        onChange={(event) => {
          const value = event.target.value;
          setDraft(value);
          // Typing `@` opens the picker on the unfinished reference at the caret.
          const caret = event.target.selectionStart ?? value.length;
          const opened = agentMentionQuery(value.slice(0, caret));
          if (opened === null) return;
          setMention(opened);
          setFileQuery(opened.query);
          setIsPickingFile(true);
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
            event.preventDefault();
            send();
          }
        }}
      />

      <div className="mt-1.5 flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-1">
          <Button
            type="button"
            size="icon-xs"
            variant="ghost"
            tooltip={t("agent.composer.attachFile")}
            aria-label={t("agent.composer.attachFile")}
            onClick={() => {
              if (isPickingFile) {
                closePicker();
                return;
              }
              setMention(null);
              setFileQuery("");
              setIsPickingFile(true);
            }}
          >
            <FilePlusIcon className="size-3.5" />
          </Button>
          {activeFilePath === null ? null : (
            <Button type="button" size="xs" variant="ghost" onClick={() => attach([activeFilePath])}>
              {t("agent.composer.attachActive")}
            </Button>
          )}
        </div>
        <div className="flex items-center gap-2">
          <AgentUsagePanel
            usage={conversation?.contextUsage ?? null}
            quota={snapshot.usesSubscription ? snapshot.subscriptionQuota : null}
          />
          {isResponding ? (
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={isCancelling}
              onClick={() => agentConnection().cancel()}
            >
              <StopIcon className="size-3.5" />
              {isCancelling ? t("agent.composer.cancelling") : t("agent.composer.stop")}
            </Button>
          ) : (
            <Button
              type="button"
              size="sm"
              variant="accent"
              disabled={!canSend || (draft.trim().length === 0 && files.length === 0)}
              onClick={send}
            >
              <PaperPlaneTiltIcon className="size-3.5" />
              {t("agent.composer.send")}
            </Button>
          )}
        </div>
      </div>

      {isCreatingSession ? (
        <div className="mt-1 flex items-center gap-1.5 text-subtle-foreground ui-text-caption">
          <Spinner className="size-3" />
          {t("agent.composer.preparing")}
        </div>
      ) : null}
      {snapshot.pendingNewConversationPrompt === null ? null : (
        <div className="mt-1 text-subtle-foreground ui-text-caption">
          {t("agent.composer.queued", { text: snapshot.pendingNewConversationPrompt })}
        </div>
      )}
      {composerError === null ? null : (
        <div className="mt-1 text-warning ui-text-caption">{composerError}</div>
      )}
    </div>
  );
}
