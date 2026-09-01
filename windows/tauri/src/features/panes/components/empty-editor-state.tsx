import { FileTextIcon, MagnifyingGlassIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/ui/context-menu";

export function EmptyEditorState() {
  const { t } = useTranslation();

  return (
    <ContextMenu>
      <ContextMenuTrigger className="flex size-full min-h-0 items-center justify-center bg-background px-6 py-8">
        <div className="flex max-w-md flex-col items-center gap-3 text-center">
          <div className="relative flex size-12 items-center justify-center text-subtle-foreground">
            <FileTextIcon className="size-10 stroke-[1.15]" aria-hidden="true" />
            <MagnifyingGlassIcon
              className="absolute right-0 bottom-0 size-5 stroke-[1.4]"
              aria-hidden="true"
            />
          </div>
          <h2 className="ui-text-base font-medium text-foreground">
            {t("workbench.emptyEditorTitle")}
          </h2>
          <p className="ui-text-sm text-subtle-foreground">
            {t("workbench.emptyEditorDescription")}
          </p>
        </div>
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem disabled>{t("ui.noActionsHere")}</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
