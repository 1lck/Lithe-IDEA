import { useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { CaretDownIcon, CaretRightIcon, FileTextIcon, WarningCircleIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { cn } from "@/utils/cn";
import {
  currentPermission,
  type AgentConversation,
  type AgentConversationMessage,
  type AgentPermissionPrompt,
  type AgentToolDetails,
} from "../types/agent.types";

interface AgentTranscriptProps {
  conversation: AgentConversation;
  onOpenToolLocation: (path: string, line: number | null) => void;
  onAnswerPermission: (optionId: string | null) => void;
}

function ToolDetails({ details, onOpenToolLocation }: {
  details: AgentToolDetails;
  onOpenToolLocation: (path: string, line: number | null) => void;
}) {
  const { t } = useTranslation();
  const [isExpanded, setIsExpanded] = useState(false);
  const hasEvidence =
    details.input !== null || details.output !== null || details.content.length > 0;

  return (
    <div className="mt-1 space-y-1">
      {details.locations.length === 0 ? null : (
        <div className="flex flex-wrap gap-1">
          {details.locations.map((location) => (
            <button
              key={`${location.path}:${location.line ?? 0}`}
              type="button"
              className="flex max-w-full items-center gap-1 rounded-sm bg-muted px-1.5 py-0.5 text-left text-subtle-foreground hover:text-foreground"
              onClick={() => onOpenToolLocation(location.path, location.line)}
            >
              <FileTextIcon className="size-3 shrink-0" />
              <span className="truncate">
                {location.path}
                {location.line === null ? "" : `:${location.line}`}
              </span>
            </button>
          ))}
        </div>
      )}
      {!hasEvidence ? null : (
        <>
          <button
            type="button"
            className="flex items-center gap-1 text-subtle-foreground hover:text-foreground"
            aria-expanded={isExpanded}
            onClick={() => setIsExpanded((value) => !value)}
          >
            {isExpanded ? (
              <CaretDownIcon className="size-3" />
            ) : (
              <CaretRightIcon className="size-3" />
            )}
            {t("agent.tool.details")}
          </button>
          {isExpanded ? (
            <div className="space-y-1 rounded-sm border border-border/60 bg-surface/60 p-2">
              {details.input === null ? null : (
                <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words text-subtle-foreground ui-text-caption">
                  {details.input}
                </pre>
              )}
              {details.output === null ? null : (
                <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-foreground ui-text-caption">
                  {details.output}
                </pre>
              )}
              {details.content.map((entry, index) => (
                <div key={index} className="space-y-0.5">
                  {entry.title.length === 0 ? null : (
                    <div className="text-subtle-foreground">{entry.title}</div>
                  )}
                  <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-foreground ui-text-caption">
                    {entry.text}
                  </pre>
                </div>
              ))}
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}

function Message({ message, onOpenToolLocation }: {
  message: AgentConversationMessage;
  onOpenToolLocation: (path: string, line: number | null) => void;
}) {
  const { t } = useTranslation();
  if (message.role === "tool") {
    return (
      <div className="rounded-lg border border-border/70 bg-surface/50 px-2.5 py-2">
        <div className="flex items-center gap-2">
          {message.toolStatus === "pending" || message.toolStatus === "in_progress" ? (
            <Spinner className="size-3.5 shrink-0 text-primary" />
          ) : (
            <span
              aria-hidden
              className={cn(
                "size-1.5 shrink-0 rounded-full",
                message.toolStatus === "completed" ? "bg-success" : "bg-warning",
              )}
            />
          )}
          <span className="min-w-0 flex-1 truncate">{message.text}</span>
          <span className="shrink-0 text-subtle-foreground ui-text-caption">
            {t(`agent.tool.status.${message.toolStatus ?? "pending"}`)}
          </span>
        </div>
        <ToolDetails details={message.toolDetails} onOpenToolLocation={onOpenToolLocation} />
      </div>
    );
  }
  return (
    <div
      className={cn(
        "rounded-lg px-2.5 py-2",
        message.role === "user" ? "bg-muted" : "bg-transparent",
      )}
    >
      <div className="mb-0.5 text-subtle-foreground ui-text-caption">
        {message.role === "user" ? t("agent.role.user") : t("agent.role.agent")}
      </div>
      <div className="whitespace-pre-wrap break-words text-foreground ui-text-base">
        {message.text}
      </div>
    </div>
  );
}

function PermissionCard({ prompt, onAnswer }: {
  prompt: AgentPermissionPrompt;
  onAnswer: (optionId: string | null) => void;
}) {
  const { t } = useTranslation();
  return (
    <div className="rounded-lg border border-warning/40 bg-warning/5 px-2.5 py-2">
      <div className="flex items-center gap-1.5 font-medium text-foreground">
        <WarningCircleIcon className="size-3.5 text-warning" />
        {prompt.title}
      </div>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        {prompt.choices.map((choice) => (
          <Button
            key={choice.id}
            type="button"
            size="xs"
            variant={choice.kind === "reject_once" ? "ghost" : "accent"}
            onClick={() => onAnswer(choice.id)}
          >
            {choice.label}
          </Button>
        ))}
        <Button type="button" size="xs" variant="ghost" onClick={() => onAnswer(null)}>
          {t("agent.permission.dismiss")}
        </Button>
      </div>
    </div>
  );
}

/** The conversation as the host reported it: messages, tool evidence, prompts. */
export function AgentTranscript({
  conversation,
  onOpenToolLocation,
  onAnswerPermission,
}: AgentTranscriptProps) {
  const { t } = useTranslation();
  const permission = currentPermission(conversation);

  if (conversation.isLoading) {
    return (
      <div className="flex items-center gap-2 p-3 text-subtle-foreground">
        <Spinner className="size-3.5" />
        {t("agent.transcript.loading")}
      </div>
    );
  }
  if (conversation.messages.length === 0) {
    return (
      <div className="p-3 text-subtle-foreground ui-text-sm">{t("agent.transcript.empty")}</div>
    );
  }

  return (
    <div className="space-y-2 p-2">
      {conversation.messages.map((message) => (
        <Message key={message.id} message={message} onOpenToolLocation={onOpenToolLocation} />
      ))}
      {permission === null ? null : (
        <PermissionCard prompt={permission} onAnswer={onAnswerPermission} />
      )}
      {conversation.errorMessage === null ? null : (
        <div className="flex items-start gap-1.5 rounded-lg border border-border/70 bg-surface/50 px-2.5 py-2 text-subtle-foreground">
          <WarningCircleIcon className="mt-0.5 size-3.5 shrink-0" />
          <span className="ui-text-sm">{conversation.errorMessage}</span>
        </div>
      )}
    </div>
  );
}
