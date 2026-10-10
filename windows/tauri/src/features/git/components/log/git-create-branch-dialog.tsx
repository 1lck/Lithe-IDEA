import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { createAndCheckoutBranch } from "../../api/git-branches-api";
import type { GitReference } from "../../types/git.types";
import {
  cleanBranchName,
  cleanBranchNameOnTyping,
  initialBranchName,
  validateNewBranchName,
  type GitBranchNameError,
} from "../../utils/git-branch-name";

/**
 * "Create Branch from <reference>" dialog, following IDEA's `GitNewBranchDialog`: a single
 * "Branch Name" row with inline validation. The new branch is always checked out, so the
 * checkout and overwrite options are intentionally absent.
 */
export function GitCreateBranchDialog({
  repoPath,
  reference,
  references,
  onCreated,
  onClose,
}: {
  repoPath: string;
  reference: GitReference;
  references: readonly GitReference[];
  onCreated: (name: string) => void | Promise<void>;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState(() => initialBranchName(reference));
  const [submitAttempted, setSubmitAttempted] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const activeRef = useRef(true);
  const pendingRef = useRef(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const caretRef = useRef<number | null>(null);
  const cleanedName = cleanBranchName(name).trim();
  // Like IDEA, nothing is validated until the user presses Create; after that the
  // error follows the typed name so it clears as soon as the conflict is resolved.
  const validationError = useMemo(
    () => (submitAttempted ? validateNewBranchName(cleanedName, references, true) : null),
    [cleanedName, references, submitAttempted],
  );
  const errorMessage = validationError ? describeError(validationError) : failure;

  useEffect(() => {
    activeRef.current = true;
    return () => {
      activeRef.current = false;
    };
  }, []);

  // The input lives in a portal that mounts after this component's effects, so select
  // the suggested name when the node attaches: typing or Backspace then replaces it,
  // as IDEA's dialog does.
  const attachInput = useCallback((node: HTMLInputElement | null) => {
    inputRef.current = node;
    node?.focus();
    node?.select();
  }, []);

  // A cleaned value replaces the input text, which would push the caret to the end.
  useLayoutEffect(() => {
    if (caretRef.current === null) return;
    inputRef.current?.setSelectionRange(caretRef.current, caretRef.current);
    caretRef.current = null;
  }, [name]);

  function describeError(error: GitBranchNameError): string {
    switch (error.code) {
      case "empty":
        return t("git.log.branchNameEmpty");
      case "head":
        return t("git.log.branchNameHead");
      case "clashesWithRemote":
        return t("git.log.branchNameClashesWithRemote", { name: error.name });
      case "clashesWithDirectory":
        return t("git.log.branchNameClashesWithDirectory", { name: error.name });
      case "alreadyExists":
        return t("git.log.branchNameAlreadyExists", { name: error.name });
    }
  }

  const submit = async () => {
    if (pendingRef.current) return;
    setSubmitAttempted(true);
    if (validateNewBranchName(cleanedName, references, true)) return;
    pendingRef.current = true;
    setIsCreating(true);
    setFailure(null);
    try {
      await createAndCheckoutBranch(repoPath, cleanedName, reference);
      await onCreated(cleanedName);
      if (activeRef.current) onClose();
    } catch (cause) {
      if (activeRef.current) {
        setFailure(cause instanceof Error ? cause.message : t("git.log.branchCreateFailed"));
      }
    } finally {
      pendingRef.current = false;
      if (activeRef.current) setIsCreating(false);
    }
  };

  return (
    <AppDialog
      title={t("git.log.createBranchFromTitle", { reference: reference.shortName })}
      iconNode={<img src="/logo.png" alt="" draggable={false} className="size-5 object-contain" />}
      size="sm"
      onClose={() => {
        if (!pendingRef.current) onClose();
      }}
      footer={
        <>
          {/* IDEA on Windows: filled default button first, outlined Cancel after it. */}
          <Button
            className="border-transparent bg-primary text-white hover:bg-primary/90"
            disabled={isCreating || Boolean(validationError)}
            onClick={() => void submit()}
          >
            {t(isCreating ? "git.creating" : "git.create")}
          </Button>
          <Button
            className="border border-border bg-transparent hover:bg-accent"
            disabled={isCreating}
            onClick={onClose}
          >
            {t("ui.cancel")}
          </Button>
        </>
      }
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <div className="grid grid-cols-[auto_1fr] items-center gap-x-3 gap-y-1">
          <label htmlFor="git-create-branch-name" className="font-sans ui-text-sm text-foreground">
            {t("git.log.branchNameLabel")}
          </label>
          <Input
            ref={attachInput}
            id="git-create-branch-name"
            autoFocus
            value={name}
            disabled={isCreating}
            aria-invalid={errorMessage ? true : undefined}
            className={errorMessage ? "border-destructive" : undefined}
            onChange={(event) => {
              const raw = event.target.value;
              const cleaned = cleanBranchNameOnTyping(raw);
              if (cleaned !== raw) {
                const caret = event.target.selectionStart ?? raw.length;
                caretRef.current = cleanBranchNameOnTyping(raw.slice(0, caret)).length;
              }
              setFailure(null);
              setName(cleaned);
            }}
          />
          {errorMessage ? (
            <p role="alert" className="col-start-2 text-destructive ui-text-sm">
              {errorMessage}
            </p>
          ) : null}
        </div>
      </form>
    </AppDialog>
  );
}
