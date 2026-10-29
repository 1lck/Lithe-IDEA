import { PlusIcon, PencilSimpleIcon, TrashIcon } from "@/ui/icons";
import { useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Checkbox } from "@/ui/checkbox";
import { IDEA_CHECKBOX_CLASS_NAME } from "../utils/idea-control-styles";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Select from "@/ui/select";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
  showConfirmDialog,
} from "@/ui/dialog";
import { useGitChangelistsStore, workspaceChangelists } from "../stores/git-changelists.store";
import { DEFAULT_CHANGELIST } from "../utils/git-changelists";

export function GitChangelistBar({
  workspace,
  disabled,
  includeParentReferences,
  onIncludeParentReferencesChange,
  showChangelists = true,
  showParentReferences = true,
}: {
  workspace: string;
  disabled: boolean;
  includeParentReferences: boolean;
  onIncludeParentReferencesChange: (include: boolean) => void;
  /** Settings `showGitChangelists`: hides the selector and its create/rename/delete buttons. */
  showChangelists?: boolean;
  /** Settings `showGitParentReferences`: hides the "update parent repository references" option. */
  showParentReferences?: boolean;
}) {
  const { t } = useTranslation();
  const state = useGitChangelistsStore((store) => workspaceChangelists(store, workspace));
  const unavailable = useGitChangelistsStore((store) => store.unavailable);
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState(false);
  const active = state.lists.find((list) => list.id === state.activeId)!;
  const title = (list: typeof active) =>
    list.id === DEFAULT_CHANGELIST ? t("git.changelists.default") : list.name;
  const beginEdit = (id: string) => {
    setName(id ? active.name : "");
    setEditing(id);
    setError(false);
  };
  const save = () => {
    if (disabled || unavailable || editing === null) return;
    const store = useGitChangelistsStore.getState();
    const saved = editing
      ? store.renameList(workspace, editing, name)
      : store.createList(workspace, name, crypto.randomUUID());
    if (saved) setEditing(null);
    else setError(true);
  };
  if (!showChangelists && !showParentReferences) return null;
  return (
    <div className="shrink-0 p-2 space-y-1.5">
      {showChangelists ? (
        <div className="flex items-center gap-1">
          <Select
            size="xs"
            variant="default"
            // macOS pins the selector to LitheDropdownMetrics.minimumRootWidth (156pt) and
            // pushes the icon buttons to the trailing edge instead of stretching the selector.
            // The panel can be narrower than that row, so the selector keeps the pinned width
            // only as its basis and yields space first; the buttons already carry shrink-0.
            className="w-39 min-w-0"
            triggerClassName="h-7 rounded-[4px] border border-control-border bg-checkbox-background"
            aria-label={t("git.changelists.active")}
            title={t("git.changelists.scope", { name: title(active) })}
            value={state.activeId}
            disabled={disabled || unavailable}
            options={state.lists.map((list) => ({ value: list.id, label: title(list) }))}
            onChange={(id) => useGitChangelistsStore.getState().activateList(workspace, id)}
          />
          <span className="min-w-0 flex-1" />
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label={t("git.changelists.new")}
            title={t("git.changelists.new")}
            disabled={disabled || unavailable}
            onClick={() => beginEdit("")}
          >
            <PlusIcon />
          </Button>
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label={t("git.changelists.rename")}
            title={t("git.changelists.rename")}
            disabled={disabled || unavailable || active.id === DEFAULT_CHANGELIST}
            onClick={() => beginEdit(active.id)}
          >
            <PencilSimpleIcon />
          </Button>
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label={t("git.changelists.delete")}
            title={t("git.changelists.delete")}
            disabled={disabled || unavailable || active.id === DEFAULT_CHANGELIST}
            onClick={async () => {
              const id = active.id;
              if (
                await showConfirmDialog(t("git.changelists.deleteDescription"), {
                  title: t("git.changelists.delete"),
                })
              ) {
                useGitChangelistsStore.getState().removeList(workspace, id);
              }
            }}
          >
            <TrashIcon />
          </Button>
        </div>
      ) : null}
      {showParentReferences ? (
        // `ui-text-xs` is not a defined utility, so it left this at the base size; macOS uses .caption.
        <label className="flex items-center gap-1.5 ui-text-caption">
          <Checkbox
            className={IDEA_CHECKBOX_CLASS_NAME}
            checked={includeParentReferences}
            onCheckedChange={onIncludeParentReferencesChange}
            disabled={disabled}
          />
          {t("git.workspaceCommit.parents")}
        </label>
      ) : null}
      {showChangelists && unavailable && (
        <p className="ui-text-xs text-subtle-foreground" role="alert">
          {t("git.changelists.unavailable")}
        </p>
      )}
      <Dialog
        open={editing !== null}
        onOpenChange={(open) => {
          if (!open) setEditing(null);
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {t(editing ? "git.changelists.rename" : "git.changelists.new")}
            </DialogTitle>
          </DialogHeader>
          <Input
            autoFocus
            aria-label={t("git.changelists.name")}
            value={name}
            maxLength={100}
            onChange={(event) => setName(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                save();
              }
            }}
          />
          {error && <p role="alert">{t("git.changelists.invalidName")}</p>}
          <DialogFooter>
            <Button onClick={() => setEditing(null)}>{t("common.cancel")}</Button>
            <Button disabled={disabled || unavailable} onClick={save}>
              {t("git.execution.save")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
