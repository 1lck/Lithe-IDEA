import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { createAndCheckoutBranch } from "../../api/git-branches-api";
import type { GitReference } from "../../types/git.types";
import {
  previewBranchName,
  type GitBranchNameError,
  type GitBranchNamePreview,
} from "../../utils/git-branch-name";

/** DOM carets can sit inside a surrogate pair; Core reads Unicode scalar values. */
function caretAtCodePointBoundary(rawName: string, caret: number): number {
  if (caret <= 0 || caret >= rawName.length) return caret;
  const previous = rawName.charCodeAt(caret - 1);
  // 0xd800..0xdbff is a high surrogate: including its low half keeps the pair intact.
  return (previous & 0xfc00) === 0xd800 ? caret + 1 : caret;
}

/**
 * "Create Branch from <reference>" dialog, following IDEA's `GitNewBranchDialog`: a single
 * "Branch Name" row with inline validation. Cleaning and conflict validation come from the
 * shared Core command `git.branchNamePreview`, so Windows and macOS apply the same rules.
 * The new branch is always checked out, so the checkout and overwrite options are
 * intentionally absent.
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
  // The suggested name comes from Core, so the input starts empty and adopts
  // `initialName` when the first preview arrives.
  const [name, setName] = useState("");
  const [preview, setPreview] = useState<GitBranchNamePreview | null>(null);
  const [submitAttempted, setSubmitAttempted] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [failure, setFailure] = useState<string | null>(null);
  const activeRef = useRef(true);
  const pendingRef = useRef(false);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const caretRef = useRef<number | null>(null);
  const selectAllRef = useRef(true);
  // Input generation. A preview result only applies while it is still the newest
  // request, so a slow answer cannot overwrite text typed after it.
  const requestRef = useRef(0);
  const referencesRef = useRef(references);
  referencesRef.current = references;
  const nameRef = useRef(name);
  nameRef.current = name;
  const submitAttemptedRef = useRef(submitAttempted);
  submitAttemptedRef.current = submitAttempted;
  // Like IDEA, nothing is validated until the user presses Create; after that the
  // error follows the typed name so it clears as soon as the conflict is resolved.
  const validationError = submitAttempted ? (preview?.error ?? null) : null;
  const errorMessage = validationError ? describeError(validationError) : failure;

  useEffect(() => {
    activeRef.current = true;
    return () => {
      activeRef.current = false;
      // Invalidate an in-flight preview so it cannot publish state after unmount.
      requestRef.current += 1;
    };
  }, []);

  const requestPreview = useCallback(
    async (rawName: string, caret: number | null) => {
      const request = ++requestRef.current;
      const isCurrent = () => activeRef.current && request === requestRef.current;
      try {
        const result = await previewBranchName({
          rawName,
          // After the first Create attempt the inline error must also cover the
          // empty name, which is not an error while the user is still typing.
          requireName: submitAttemptedRef.current,
          references: referencesRef.current,
          reference,
        });
        if (!isCurrent()) return;
        let caretOffset: number | null = null;
        if (caret !== null && result.typingCleanedName !== rawName) {
          // Cleaning can drop or replace characters before the caret. Core owns
          // those rules, so ask it for the cleaned prefix instead of copying the
          // rules into this component. An emoji counts as one Core character but
          // two DOM positions, and a caret between its halves would not survive
          // the string boundary, so move it past the pair first.
          const prefix = await previewBranchName({
            rawName: rawName.slice(0, caretAtCodePointBoundary(rawName, caret)),
            requireName: false,
            references: referencesRef.current,
            reference,
          });
          if (!isCurrent()) return;
          caretOffset = prefix.typingCleanedName.length;
        }
        setPreview(result);
        if (caretOffset !== null) caretRef.current = caretOffset;
        setName(result.typingCleanedName);
      } catch (cause) {
        if (!isCurrent()) return;
        console.error("Failed to preview the new branch name:", cause);
        setFailure(cause instanceof Error ? cause.message : String(cause));
      }
    },
    [reference],
  );

  useEffect(() => {
    const request = ++requestRef.current;
    const isCurrent = () => activeRef.current && request === requestRef.current;
    void previewBranchName({
      rawName: "",
      requireName: false,
      references: referencesRef.current,
      reference,
    })
      .then((result) => {
        if (!isCurrent()) return;
        setPreview(result);
        selectAllRef.current = true;
        setName(result.initialName);
      })
      .catch((cause) => {
        if (!isCurrent()) return;
        console.error("Failed to preview the new branch name:", cause);
        setFailure(cause instanceof Error ? cause.message : String(cause));
      });
  }, [reference]);

  // The input lives in a portal that mounts after this component's effects, so focus
  // the node when it attaches: typing or Backspace then replaces the suggested name,
  // as IDEA's dialog does.
  const attachInput = useCallback((node: HTMLInputElement | null) => {
    inputRef.current = node;
    node?.focus();
    if (selectAllRef.current) node?.select();
  }, []);

  useLayoutEffect(() => {
    if (selectAllRef.current) {
      selectAllRef.current = false;
      inputRef.current?.focus();
      inputRef.current?.select();
      return;
    }
    // A cleaned value replaces the input text, which would push the caret to the end.
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
      case "clashesWithBranchPrefix":
        return t("git.log.branchNameClashesWithBranchPrefix", {
          name: error.name,
          branch: error.branch,
        });
      case "alreadyExists":
        return t("git.log.branchNameAlreadyExists", { name: error.name });
    }
  }

  const submit = async () => {
    if (pendingRef.current) return;
    setSubmitAttempted(true);
    submitAttemptedRef.current = true;
    pendingRef.current = true;
    setFailure(null);
    const request = ++requestRef.current;
    try {
      const result = await previewBranchName({
        rawName: nameRef.current,
        requireName: true,
        references: referencesRef.current,
        reference,
      });
      // The input changed while the preview was in flight: never create a branch
      // from a stale name, the user must confirm the new value.
      if (!activeRef.current || request !== requestRef.current) return;
      setPreview(result);
      if (result.error) return;
      setIsCreating(true);
      await createAndCheckoutBranch(repoPath, result.cleanedName, reference);
      await onCreated(result.cleanedName);
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
              const caret = event.target.selectionStart ?? raw.length;
              selectAllRef.current = false;
              setFailure(null);
              // Show the typed text immediately; the Core-cleaned name replaces it
              // when the preview resolves, and an older preview is dropped.
              setName(raw);
              void requestPreview(raw, caret);
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
