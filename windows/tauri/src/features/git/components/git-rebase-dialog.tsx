import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  showConfirmDialog,
  showPromptDialog,
} from "@/ui/dialog";
import Input from "@/ui/input";
import Select from "@/ui/select";
import Textarea from "@/ui/textarea";
import { Spinner } from "@/ui/spinner";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { createBranch } from "../api/git-branches-api";
import { cancelGitHistoryOperation } from "../api/git-commits-api";
import {
  controlGitRebase,
  getGitRebaseSession,
  previewGitRebase,
  startGitRebase,
} from "../api/git-rebase-api";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import {
  attachGitRebaseDialogHost,
  type GitRebaseDialogRequest,
} from "../services/git-rebase-dialog-service";
import { useRepositoryStore } from "../stores/git-repository.store";
import type { GitHistoryRewriteResult } from "../types/git-history-rewrite.types";
import type {
  GitRebaseAction,
  GitRebasePreview,
  GitRebaseResult,
  GitRebaseSession,
  GitRebaseStep,
} from "../types/git-rebase.types";
import { joinGitCommitMessage, splitGitCommitMessage } from "../utils/git-history-message";
import { prepareGitRebasePlan } from "../utils/git-rebase-plan";

const actions: GitRebaseAction[] = ["pick", "reword", "edit", "squash", "fixup", "drop"];
const terminalSession = (session: GitRebaseSession) =>
  session.status === "completed" || session.status === "aborted";

function MessageEditor({
  message,
  onChange,
  disabled,
}: {
  message: string;
  onChange: (value: string) => void;
  disabled: boolean;
}) {
  const { t } = useTranslation();
  const { title, body } = splitGitCommitMessage(message);
  return (
    <div className="space-y-2">
      <Input
        aria-label={t("git.historyReview.title")}
        value={title}
        disabled={disabled}
        onChange={(event) => onChange(joinGitCommitMessage(event.target.value, body))}
      />
      <p className="text-right text-subtle-foreground">
        {t("git.historyReview.titleCharacters", { count: [...title].length })}
      </p>
      <Textarea
        aria-label={t("git.historyReview.body")}
        value={body}
        disabled={disabled}
        rows={4}
        className="max-h-64"
        onChange={(event) => onChange(joinGitCommitMessage(title, event.target.value))}
      />
      <p className="text-right text-subtle-foreground">
        {t("git.historyReview.totalCharacters", { count: [...message].length })}
      </p>
    </div>
  );
}

function GitRebaseDialog({
  request,
  onClose,
}: {
  request: GitRebaseDialogRequest;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [preview, setPreview] = useState<GitRebasePreview | null>(null);
  const [steps, setSteps] = useState<GitRebaseStep[]>([]);
  const [session, setSession] = useState<GitRebaseSession | null>(null);
  const [command, setCommand] = useState<GitHistoryRewriteResult | null>(null);
  const [amendMessage, setAmendMessage] = useState("");
  const [status, setStatus] = useState<"loading" | "ready" | "failed" | "working">("loading");
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  const alive = useRef(true);
  const working = useRef(false);
  const sessionRef = useRef<GitRebaseSession | null>(null);
  const amendIdentity = useRef("");

  const acceptSession = (value: GitRebaseSession | null) => {
    sessionRef.current = value;
    setSession(value);
    const identity = value ? `${value.sessionId}:${value.currentCommit}:${value.status}` : "";
    if (identity !== amendIdentity.current) {
      amendIdentity.current = identity;
      setAmendMessage(
        value?.currentMessage ??
          value?.steps.find((entry) => entry.hash === value.currentCommit)?.message ??
          "",
      );
    }
  };
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  useEffect(() => {
    let current = true;
    const operationId = crypto.randomUUID();
    setStatus("loading");
    void (async () => {
      try {
        const existing = await getGitRebaseSession(request.repoPath, operationId);
        if (!current) return;
        const unfinished =
          existing &&
          !terminalSession(existing) &&
          (existing.status !== "failed" ||
            existing.canContinue ||
            existing.canSkip ||
            existing.canAbort);
        if (existing && (unfinished || !request.revision || sessionRef.current)) {
          acceptSession(existing);
          setPreview(null);
        } else if (request.revision) {
          const value = await previewGitRebase(request.repoPath, request.revision, operationId);
          if (!current) return;
          setPreview(value);
          setSteps(
            value.commits.map((entry) => ({
              hash: entry.hash,
              action: "pick",
            })),
          );
        } else acceptSession(null);
        if (current) {
          setError("");
          setStatus("ready");
        }
      } catch (failure) {
        if (current) {
          setError(String(failure));
          setStatus("failed");
        }
      }
    })();
    return () => {
      current = false;
      void cancelGitHistoryOperation(operationId);
    };
  }, [request, attempt]);
  useEffect(
    () =>
      subscribeToGitChanges((change) => {
        if (!working.current && sessionRef.current && isGitChangeRelevant(change, request.repoPath))
          setAttempt((value) => value + 1);
      }),
    [request.repoPath],
  );

  const moveStep = (index: number, offset: number) =>
    setSteps((current) => {
      const next = [...current];
      const target = index + offset;
      if (target < 0 || target >= next.length) return current;
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  const updateStep = (index: number, update: Partial<GitRebaseStep>) =>
    setSteps((current) =>
      current.map((entry, offset) => (offset === index ? { ...entry, ...update } : entry)),
    );
  const plan = prepareGitRebasePlan(steps, preview?.commits ?? []);
  const changeAction = (index: number, action: GitRebaseAction) => updateStep(index, { action });
  let hasPriorCommit = false;
  const invalidPlan = steps.some((step) => {
    if ((step.action === "squash" || step.action === "fixup") && !hasPriorCommit) return true;
    if (step.action !== "drop") hasPriorCommit = true;
    return (
      (step.action === "reword" || step.action === "squash") &&
      !plan.messages.get(step.hash)?.trim()
    );
  });
  const run = async (operation: () => Promise<GitRebaseResult>) => {
    if (working.current) return;
    working.current = true;
    setStatus("working");
    setError("");
    try {
      const result = await operation();
      if (alive.current) {
        acceptSession(result.session);
        setCommand(result.command);
        setPreview(null);
        setStatus("ready");
      }
    } catch (failure) {
      if (!alive.current) return;
      setError(String(failure));
      // A transport error may follow a started sequencer. Discover the durable
      // session before offering any retry so the same plan cannot run twice.
      try {
        const value = await getGitRebaseSession(request.repoPath);
        if (alive.current) {
          acceptSession(value);
          if (value) setPreview(null);
        }
      } catch (readFailure) {
        if (alive.current) setError(`${String(failure)}\n${String(readFailure)}`);
      }
      if (alive.current) setStatus("failed");
    } finally {
      working.current = false;
    }
  };
  const control = async (action: "continue" | "skip" | "abort", amend = false) => {
    if (!session || working.current) return;
    if (
      (action !== "continue" || amend) &&
      !(await showConfirmDialog(
        t(
          amend
            ? "git.rebasePlan.amendConfirm"
            : action === "skip"
              ? "git.rebasePlan.skipConfirm"
              : "git.rebasePlan.abortConfirm",
        ),
        { title: t("git.rebasePlan.title") },
      ))
    )
      return;
    if (!alive.current) return;
    await run(() =>
      controlGitRebase(
        request.repoPath,
        session.sessionId,
        action,
        amend ? amendMessage : undefined,
      ),
    );
  };
  const recoverBranch = async () => {
    if (!session || working.current) return;
    const name = await showPromptDialog(t("git.historyReview.recoveryName"), {
      title: t("git.historyReview.createRecovery"),
      confirmLabel: t("git.create"),
    });
    if (!name?.trim() || !alive.current) return;
    working.current = true;
    setStatus("working");
    try {
      const success = await createBranch(request.repoPath, name.trim(), {
        fullName: session.originalHead,
        shortName: session.originalHead,
        kind: "local",
        isCurrent: false,
        peelsToCommit: true,
      });
      if (!success) throw new Error(t("git.operationFailed"));
      if (alive.current)
        toast.success(t("git.historyReview.recoveryCreated", { name: name.trim() }));
    } catch (failure) {
      if (alive.current) setError(String(failure));
    } finally {
      working.current = false;
      if (alive.current) setStatus("ready");
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !working.current) onClose();
      }}
    >
      <DialogContent size="lg" className="max-w-4xl" showCloseButton={status !== "working"}>
        <DialogHeader>
          <DialogTitle>{t("git.rebasePlan.title")}</DialogTitle>
          <DialogDescription>{t("git.rebasePlan.description")}</DialogDescription>
        </DialogHeader>
        <div className="min-h-0 space-y-4 overflow-auto px-5 py-4 ui-text-sm">
          {status === "loading" ? <Spinner label={t("ui.loading")} showLabel /> : null}
          {preview ? (
            <>
              <p>
                {t("git.rebasePlan.range", {
                  count: preview.commits.length,
                  branch: preview.branch ?? "",
                  base: preview.base?.slice(0, 7) ?? "",
                })}
              </p>
              <p>
                {t("git.rebasePlan.resultCount", {
                  before: steps.length,
                  after: steps.filter(
                    (step) =>
                      step.action !== "drop" && step.action !== "fixup" && step.action !== "squash",
                  ).length,
                })}
              </p>
              {preview.blockers.map((entry) => (
                <p key={entry.code} role="alert" className="text-destructive">
                  {entry.message}
                </p>
              ))}
              {invalidPlan ? (
                <p role="alert" className="text-destructive">
                  {t("git.rebasePlan.invalidPlan")}
                </p>
              ) : null}
              <ol className="space-y-3">
                {steps.map((step, index) => (
                  <li key={step.hash} className="space-y-2 rounded-md border border-border p-3">
                    <div className="flex items-center gap-2">
                      <span className="w-6 shrink-0 text-subtle-foreground">{index + 1}</span>
                      <code>{step.hash.slice(0, 7)}</code>
                      <Select
                        value={step.action}
                        options={actions.map((action) => ({
                          value: action,
                          label: t(`git.rebasePlan.action.${action}`),
                        }))}
                        onChange={(value) => changeAction(index, value as GitRebaseAction)}
                        disabled={status === "working"}
                        aria-label={t("git.rebasePlan.actionLabel")}
                      />
                      <Button
                        size="xs"
                        disabled={status === "working" || index === 0}
                        onClick={() => moveStep(index, -1)}
                      >
                        {t("git.rebasePlan.up")}
                      </Button>
                      <Button
                        size="xs"
                        disabled={status === "working" || index === steps.length - 1}
                        onClick={() => moveStep(index, 1)}
                      >
                        {t("git.rebasePlan.down")}
                      </Button>
                    </div>
                    {step.action === "reword" || step.action === "squash" ? (
                      <MessageEditor
                        message={plan.messages.get(step.hash) ?? ""}
                        onChange={(message) => updateStep(index, { message })}
                        disabled={status === "working"}
                      />
                    ) : (
                      <details>
                        <summary className="cursor-pointer break-words">
                          {splitGitCommitMessage(plan.messages.get(step.hash) ?? "").title}
                        </summary>
                        <pre className="whitespace-pre-wrap break-words pt-2 font-sans">
                          {plan.messages.get(step.hash)}
                        </pre>
                      </details>
                    )}
                    <p className="text-subtle-foreground">
                      {t(`git.rebasePlan.help.${step.action}`)}
                    </p>
                  </li>
                ))}
              </ol>
            </>
          ) : null}
          {session ? (
            <>
              <p className="font-medium">
                {t(`git.rebasePlan.status.${session.status}`)} · {session.completedSteps}/
                {session.steps.length}
              </p>
              <p>
                {session.branch} · {session.currentCommit?.slice(0, 7)}
              </p>
              {session.conflictedPaths.length ? (
                <div>
                  <p>{t("git.rebasePlan.conflicts")}</p>
                  <ul className="list-inside list-disc">
                    {session.conflictedPaths.map((path) => (
                      <li key={path} className="break-all">
                        {path}
                      </li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {session.status === "edit" ? (
                <>
                  <p>{t("git.rebasePlan.editHelp")}</p>
                  <MessageEditor
                    message={amendMessage}
                    onChange={setAmendMessage}
                    disabled={status === "working"}
                  />
                </>
              ) : null}
              <div className="rounded-md border border-border p-3">
                <p>{t("git.historyReview.recovery")}</p>
                <code className="block break-all">{session.recoveryReference}</code>
                <div className="mt-2 flex gap-2">
                  <Button
                    size="xs"
                    onClick={() => void tryWriteClipboardText(session.recoveryReference)}
                  >
                    {t("git.historyReview.copyRecovery")}
                  </Button>
                  <Button
                    size="xs"
                    disabled={status === "working"}
                    onClick={() => void recoverBranch()}
                  >
                    {t("git.historyReview.createRecovery")}
                  </Button>
                </div>
              </div>
            </>
          ) : null}
          {status === "ready" && !session && !preview ? (
            <p>{t("git.rebasePlan.noSession")}</p>
          ) : null}
          {command?.operationError ? (
            <p role="alert" className="whitespace-pre-wrap text-destructive">
              {command.operationError.message}
              {command.operationError.details ? `\n${command.operationError.details}` : ""}
            </p>
          ) : null}
          {command?.warnings?.map((warning, index) => (
            <p key={`${warning.code}:${index}`} className="whitespace-pre-wrap text-git-modified">
              {warning.message}
              {warning.details ? `\n${warning.details}` : ""}
            </p>
          ))}
          {command?.output ? (
            <details>
              <summary>{t("git.rebasePlan.output")}</summary>
              <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words">
                {command.output}
              </pre>
            </details>
          ) : null}
          {error ? (
            <p role="alert" className="whitespace-pre-wrap text-destructive">
              {error}
            </p>
          ) : null}
        </div>
        <DialogFooter className="flex-wrap">
          <Button disabled={status === "working"} onClick={onClose}>
            {t("ui.close")}
          </Button>
          <Button disabled={status === "working"} onClick={() => setAttempt((value) => value + 1)}>
            {t("ui.refresh")}
          </Button>
          {preview ? (
            <Button
              variant="accent"
              disabled={
                status !== "ready" || !preview.allowed || !preview.expectedState || invalidPlan
              }
              onClick={() => void run(() => startGitRebase(request.repoPath, preview, plan.steps))}
            >
              {t("git.rebasePlan.start")}
            </Button>
          ) : null}
          {session && !terminalSession(session) ? (
            <>
              <Button
                disabled={status !== "ready" || !session.canAbort}
                onClick={() => void control("abort")}
              >
                {t("git.abort")}
              </Button>
              <Button
                disabled={status !== "ready" || !session.canSkip}
                onClick={() => void control("skip")}
              >
                {t("git.skipCommit")}
              </Button>
              {session.status === "edit" ? (
                <Button
                  disabled={status !== "ready" || !session.canContinue || !amendMessage.trim()}
                  onClick={() => void control("continue", true)}
                >
                  {t("git.rebasePlan.amendContinue")}
                </Button>
              ) : null}
              <Button
                variant="accent"
                disabled={status !== "ready" || !session.canContinue}
                onClick={() => void control("continue")}
              >
                {t("git.continueRebase")}
              </Button>
            </>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export function GitRebaseDialogHost() {
  const [request, setRequest] = useState<GitRebaseDialogRequest | null>(null);
  const requestRef = useRef<GitRebaseDialogRequest | null>(null);
  const workspaceId = useActiveWorkspaceId();
  const selectedRepository = useRepositoryStore((state) => state.activeRepoPath);
  const close = () => {
    requestRef.current = null;
    setRequest(null);
  };
  useEffect(
    () =>
      attachGitRebaseDialogHost((next) => {
        if (!requestRef.current) {
          requestRef.current = next;
          setRequest(next);
        }
      }),
    [],
  );
  const current =
    request?.workspaceId === workspaceId && request.selectedRepository === selectedRepository;
  useEffect(() => {
    if (request && !current) close();
  }, [request, current]);
  return request && current ? (
    <GitRebaseDialog key={request.id} request={request} onClose={close} />
  ) : null;
}
