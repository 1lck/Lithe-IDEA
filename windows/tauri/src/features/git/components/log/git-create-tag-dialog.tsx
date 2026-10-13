import { useEffect, useRef, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { QuestionIcon } from "@/ui/icons";
import { createTag } from "../../api/git-tags-api";
import type { GitCommit } from "../../types/git.types";

export function GitCreateTagDialog({
  repoPath,
  commit,
  onCreated,
  onClose,
}: {
  repoPath: string;
  commit: GitCommit;
  onCreated: () => void | Promise<void>;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [name, setName] = useState("");
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const activeRef = useRef(true);
  const pendingRef = useRef(false);
  const isValidName = name.length > 0 && !/\s/.test(name);

  useEffect(() => {
    activeRef.current = true;
    return () => {
      activeRef.current = false;
    };
  }, []);

  const submit = async () => {
    if (!isValidName || pendingRef.current) return;
    pendingRef.current = true;
    setIsCreating(true);
    setError(null);
    try {
      const created = await createTag(repoPath, name, undefined, commit.hash, false, { lightweight: true });
      if (!activeRef.current) return;
      if (!created) {
        setError(t("git.log.tagCreateFailed", { name }));
        return;
      }
      await onCreated();
      if (activeRef.current) onClose();
    } catch (cause) {
      if (activeRef.current) {
        setError(cause instanceof Error ? cause.message : String(cause));
      }
    } finally {
      pendingRef.current = false;
      if (activeRef.current) setIsCreating(false);
    }
  };

  return (
    <AppDialog
      title={t("git.log.createTagOnCommit", { commit: commit.hash })}
      icon={QuestionIcon}
      size="sm"
      onClose={() => {
        if (!pendingRef.current) onClose();
      }}
      footer={
        <>
          <Button disabled={isCreating} onClick={onClose}>
            {t("ui.cancel")}
          </Button>
          <Button
            variant="accent"
            disabled={!isValidName || isCreating}
            onClick={() => void submit()}
          >
            {t(isCreating ? "git.creating" : "ui.ok")}
          </Button>
        </>
      }
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
        className="flex flex-col gap-2"
      >
        <label className="flex flex-col gap-2 font-sans ui-text-sm text-foreground">
          {t("git.log.tagNamePrompt")}
          <Input
            autoFocus
            value={name}
            disabled={isCreating}
            onChange={(event) => setName(event.target.value)}
          />
        </label>
        {error ? (
          <p role="alert" className="text-destructive ui-text-sm">
            {error}
          </p>
        ) : null}
      </form>
    </AppDialog>
  );
}
