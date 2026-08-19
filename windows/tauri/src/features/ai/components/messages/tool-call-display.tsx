import {
  FileTextIcon as FileText,
  GitDiffIcon as GitDiff,
  TerminalWindowIcon as TerminalSquare,
} from "@/ui/icons";
import { getAcpDiffOutputs, openAcpDiffOutput } from "@/features/ai/lib/acp-diff-output";
import {
  getAcpTerminalOutputs,
  openAcpTerminalOutput,
} from "@/features/ai/lib/acp-terminal-output";
import type { ToolCall } from "@/features/ai/types/ai-chat.types";
import type {
  AcpToolCallLocation,
  AcpToolCallStatus,
  AcpToolKind,
} from "@/features/ai/types/acp.types";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { readFileContent } from "@/features/file-system/controllers/file-operations";
import { getFileDiff } from "@/features/git/api/git-diff-api";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { getBaseName, joinPath } from "@/utils/path-helpers";
import { ChatActivityLine } from "../chat/chat-activity-line";

interface ToolCallDisplayProps {
  toolName: string;
  input?: unknown;
  output?: unknown;
  isStreaming?: boolean;
  error?: string;
  kind?: AcpToolKind;
  status?: AcpToolCallStatus;
  locations?: AcpToolCallLocation[];
}

type Translator = (key: string, values?: Record<string, string | number>) => string;

function getStatus(
  isStreaming?: boolean,
  error?: string,
  protocolStatus?: AcpToolCallStatus,
): "running" | "success" | "error" | "info" {
  if (error || protocolStatus === "failed") return "error";
  if (protocolStatus === "completed") return "success";
  if (protocolStatus === "pending" || protocolStatus === "in_progress" || isStreaming) {
    return "running";
  }
  return "success";
}

function getStatusLabel(
  status: ReturnType<typeof getStatus>,
  protocolStatus: AcpToolCallStatus | undefined,
  t: Translator,
) {
  if (status === "error") return t("ai.toolStatusFailed");
  if (protocolStatus === "pending") return t("ai.toolStatusPending");
  if (status === "running") return t("ai.toolStatusRunning");
  return t("ai.toolStatusCompleted");
}

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object";
}

function getInputSummary(toolName: string, input: unknown): string | null {
  if (!input || typeof input !== "object") return typeof input === "string" ? input : null;
  const record = input as Record<string, unknown>;
  const path =
    typeof record.file_path === "string"
      ? record.file_path
      : typeof record.path === "string"
        ? record.path
        : null;
  if (path) return path.split("/").pop() || path;
  if (toolName.toLowerCase().includes("bash") && typeof record.command === "string") {
    return record.command;
  }
  return null;
}

function isAbsolutePath(path: string): boolean {
  return path.startsWith("/") || /^[A-Za-z]:[\\/]/.test(path) || path.startsWith("remote://");
}

function resolveToolPath(
  locations: AcpToolCallLocation[] | undefined,
  input: unknown,
): string | null {
  const locationPath = locations?.[0]?.path;
  if (locationPath) return locationPath;

  if (!input || typeof input !== "object") return null;
  const record = input as Record<string, unknown>;
  const path =
    typeof record.file_path === "string"
      ? record.file_path
      : typeof record.path === "string"
        ? record.path
        : typeof record.filename === "string"
          ? record.filename
          : null;

  return path;
}

function resolveWorkspacePath(path: string): string {
  if (isAbsolutePath(path)) return path;
  const rootFolderPath = useProjectStore.getState().rootFolderPath;
  return rootFolderPath ? joinPath(rootFolderPath, path) : path;
}

async function openToolPath(path: string) {
  const resolvedPath = resolveWorkspacePath(path);
  const content = await readFileContent(resolvedPath);
  const bufferId = useBufferStore
    .getState()
    .actions.openBuffer(resolvedPath, getBaseName(resolvedPath), content);
  useBufferStore.getState().actions.setActiveBuffer(bufferId);
}

async function openToolDiff(path: string, output: unknown) {
  if (openAcpDiffOutput(output)) return;

  const rootFolderPath = useProjectStore.getState().rootFolderPath;
  const resolvedPath = resolveWorkspacePath(path);
  const repoPath = rootFolderPath ?? resolvedPath;
  const diff = await getFileDiff(repoPath, path);

  if (diff) {
    const displayName = `${getBaseName(diff.file_path)}.diff`;
    useBufferStore
      .getState()
      .actions.openBuffer(
        `diff://acp-tool-output/${Date.now()}`,
        displayName,
        "",
        false,
        undefined,
        true,
        true,
        diff,
      );
    return;
  }

  const newText = await readFileContent(resolvedPath);
  openAcpDiffOutput([{ type: "diff", path: resolvedPath, oldText: "", newText }]);
}

function getDiffItems(output: unknown) {
  return getAcpDiffOutputs(output);
}

function getTerminalItems(output: unknown) {
  return getAcpTerminalOutputs(output);
}

function getContentText(item: Record<string, unknown>): string {
  if (item.type !== "content" || !isRecord(item.content)) return "";
  if (item.content.type === "text" && typeof item.content.text === "string") {
    return item.content.text;
  }
  return formatValue(item.content);
}

function formatDiffText(item: Record<string, unknown>): string {
  const path = typeof item.path === "string" ? item.path : "file";
  const oldText = typeof item.oldText === "string" ? item.oldText : "";
  const newText = typeof item.newText === "string" ? item.newText : "";

  return [`diff: ${path}`, "--- before", oldText, "+++ after", newText]
    .filter((line) => line.length > 0)
    .join("\n");
}

function formatAcpDiffText(item: ReturnType<typeof getAcpDiffOutputs>[number]): string {
  return [`diff: ${item.path}`, "--- before", item.oldText, "+++ after", item.newText]
    .filter((line) => line.length > 0)
    .join("\n");
}

function getOutputSummary(output: unknown, t: Translator): string | null {
  const diffItems = getDiffItems(output);
  if (diffItems.length > 0) {
    const file = getBaseName(diffItems[0].path);
    return diffItems.length === 1
      ? t("ai.toolChangedFile", { file })
      : t("ai.toolChangedFiles", { count: diffItems.length });
  }

  const terminalItems = getTerminalItems(output);
  if (terminalItems.length > 0) {
    return terminalItems.length === 1
      ? t("ai.toolTerminalOutput")
      : t("ai.toolTerminals", { count: terminalItems.length });
  }

  return null;
}

function getOutputText(output: unknown): string {
  if (!Array.isArray(output)) return formatValue(output);

  return output
    .map((item) => {
      if (!isRecord(item)) return formatValue(item);
      if (item.type === "content") return getContentText(item);
      if (item.type === "diff") return formatDiffText(item);
      if (item.type === "terminal" && typeof item.terminalId === "string") {
        return `terminal: ${item.terminalId}`;
      }
      return formatValue(item);
    })
    .filter(Boolean)
    .join("\n\n");
}

function getToolCallDetail(
  toolName: string,
  input: unknown,
  output: unknown,
  state: ReturnType<typeof getStatus>,
  protocolStatus?: AcpToolCallStatus,
  t?: Translator,
) {
  const translate = t ?? ((key) => key);
  const statusLabel = getStatusLabel(state, protocolStatus, translate);
  const inputSummary = getInputSummary(toolName, input);
  const outputSummary = getOutputSummary(output, translate);
  const summary = outputSummary ?? inputSummary;
  return summary ? translate("ai.toolDetailWithSummary", { status: statusLabel, summary }) : statusLabel;
}

function getLatestToolSummary(toolCall: ToolCall, isStreaming: boolean | undefined, t: Translator) {
  const state = getStatus(isStreaming && !toolCall.isComplete, toolCall.error, toolCall.status);
  return `${toolCall.name}: ${getToolCallDetail(
    toolCall.name,
    toolCall.input,
    toolCall.output,
    state,
    toolCall.status,
    t,
  )}`;
}

export function ToolCallGroupDisplay({
  toolCalls,
  isStreaming,
}: {
  toolCalls: ToolCall[];
  isStreaming?: boolean;
}) {
  const { t } = useTranslation();

  if (toolCalls.length === 0) return null;

  const latestToolCall = toolCalls[toolCalls.length - 1];
  const title =
    toolCalls.length === 1 ? t("ai.toolCall") : t("ai.toolCalls", { count: toolCalls.length });
  const detail = getLatestToolSummary(latestToolCall, isStreaming, t);

  return (
    <ChatActivityLine title={title} detail={detail}>
      <div className="space-y-1">
        {toolCalls.map((toolCall, toolIndex) => (
          <ToolCallDisplay
            key={`${toolCall.id || toolCall.name}-${toolIndex}`}
            toolName={toolCall.name}
            input={toolCall.input}
            output={toolCall.output}
            error={toolCall.error}
            kind={toolCall.kind}
            status={toolCall.status}
            locations={toolCall.locations}
            isStreaming={!toolCall.isComplete && isStreaming}
          />
        ))}
      </div>
    </ChatActivityLine>
  );
}

function ToolCallDisplay({
  toolName,
  input,
  output,
  isStreaming,
  error,
  kind,
  status: protocolStatus,
  locations,
}: ToolCallDisplayProps) {
  const { t } = useTranslation();
  const state = getStatus(isStreaming, error, protocolStatus);
  const detail = getToolCallDetail(toolName, input, output, state, protocolStatus, t);
  const hasDetails =
    Boolean(input) ||
    Boolean(output) ||
    Boolean(error) ||
    Boolean(kind && kind !== "other") ||
    Boolean(locations?.length);
  const diffItems = getDiffItems(output);
  const hasDiffOutput = diffItems.length > 0;
  const terminalItems = getTerminalItems(output);
  const hasTerminalOutput = terminalItems.length > 0;
  const toolPath = resolveToolPath(locations, input);
  const hasActions = Boolean(toolPath || hasTerminalOutput);
  const actionButtons = hasActions ? (
    <span className="flex items-center gap-1">
      {toolPath && (kind === "edit" || kind === "delete" || kind === "move" || hasDiffOutput) ? (
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          tooltip={t("ai.openDiff")}
          onClick={(event) => {
            event.stopPropagation();
            void openToolDiff(toolPath, output);
          }}
        >
          <GitDiff weight="duotone" />
        </Button>
      ) : null}
      {toolPath ? (
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          tooltip={t("ai.openFile")}
          onClick={(event) => {
            event.stopPropagation();
            void openToolPath(toolPath);
          }}
        >
          <FileText weight="duotone" />
        </Button>
      ) : null}
      {hasTerminalOutput ? (
        <Button
          type="button"
          variant="ghost"
          size="icon-xs"
          tooltip={t("ai.openTerminal")}
          onClick={(event) => {
            event.stopPropagation();
            openAcpTerminalOutput(output);
          }}
        >
          <TerminalSquare weight="duotone" />
        </Button>
      ) : null}
    </span>
  ) : null;

  return (
    <ChatActivityLine title={toolName} detail={detail} state={state} actions={actionButtons}>
      {hasDetails ? (
        <>
          {kind && kind !== "other" ? `kind: ${kind}\n` : ""}
          {locations?.length
            ? `locations:\n${locations
                .map((location) => `  ${location.path}${location.line ? `:${location.line}` : ""}`)
                .join("\n")}\n`
            : ""}
          {input ? `input:\n${formatValue(input)}\n` : ""}
          {output
            ? `output:\n${
                hasDiffOutput
                  ? diffItems.map(formatAcpDiffText).join("\n\n")
                  : getOutputText(output)
              }\n`
            : ""}
          {error ? `error:\n${error}` : ""}
        </>
      ) : null}
    </ChatActivityLine>
  );
}
