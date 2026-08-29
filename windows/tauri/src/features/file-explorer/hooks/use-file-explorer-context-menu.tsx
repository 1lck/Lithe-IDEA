import {
  CaretDoubleUpIcon as CaretDoubleUp,
  ClipboardIcon as Clipboard,
  ClockCounterClockwiseIcon as ClockCounterClockwise,
  CopyIcon as Copy,
  PencilSimpleIcon as Edit,
  EyeIcon as Eye,
  FilePlusIcon as FilePlus,
  FileTextIcon as FileText,
  FolderOpenIcon as FolderOpen,
  FolderPlusIcon as FolderPlus,
  ImageIcon,
  InfoIcon as Info,
  LinkIcon as Link,
  ArrowClockwiseIcon as RefreshCw,
  ScissorsIcon as Scissors,
  MagnifyingGlassIcon as Search,
  TerminalWindowIcon as Terminal,
  TrashIcon as Trash,
  XIcon as X,
  UploadIcon as Upload,
  WarningIcon as Warning,
} from "@/ui/icons";
import { useCallback, useMemo, useState } from "react";
import { writeClipboardText } from "@/utils/clipboard";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { readFile as readTextFile, writeFile } from "@/features/file-system/controllers/platform";
import {
  buildEnvTemplateContent,
  ENV_TEMPLATE_TARGETS,
  isEnvFileName,
} from "@/features/file-explorer/lib/env-template";
import { openLocalHistoryForPath } from "@/features/local-history/utils/open-local-history";
import { useFileClipboardStore } from "@/features/file-explorer/stores/file-explorer-clipboard.store";
import { useFileTreeStore } from "@/features/file-explorer/stores/file-explorer-tree.store";
import { pasteIntoExplorerDirectory } from "@/features/file-explorer/lib/paste-into-explorer-directory";
import { JavaClipboardPasteError } from "@/features/file-explorer/lib/paste-java-class-from-clipboard";
import type { ContextMenuState } from "@/features/file-system/types/app.types";
import { Button } from "@/ui/button";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import Dialog from "@/ui/dialog";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { getBaseName, getDirName, getRelativePath, joinPath } from "@/utils/path-helpers";

interface UseFileExplorerContextMenuOptions {
  rootFolderPath?: string;
  onFileSelect: (path: string, isDir: boolean) => void | string | Promise<void | string>;
  onCreateNewFileInDirectory?: (
    directoryPath: string,
    fileName: string,
  ) => void | string | Promise<string | undefined>;
  onCreateNewFolderInDirectory?: (directoryPath: string, folderName: string) => void;
  onGenerateImage?: (directoryPath: string) => void;
  onRefreshDirectory?: (path: string, options?: { force?: boolean }) => void;
  onRenamePath?: (path: string, newName?: string) => void;
  onRevealInFinder?: (path: string) => void;
  onUploadFile?: (directoryPath: string) => void;
  onDuplicatePath?: (path: string) => void;
  onAddFolderToWorkspace?: () => void;
  onRemoveFolderFromWorkspace?: (path: string) => void;
  isWorkspaceRootPath?: (path: string) => boolean;
  canRemoveWorkspaceRootPath?: (path: string) => boolean;
  onDeleteRequested: (candidate: { path: string; isDir: boolean }) => void;
  onStartInlineEditing: (path: string, isFolder: boolean) => void;
  onOpenAllFilesInDirectory: (directoryPath: string) => Promise<void>;
}

interface EnvOverwriteDialogState {
  sourcePath: string;
  targetFileName: string;
}

interface PropertiesDialogState {
  fileName: string;
  path: string;
  size: string;
  type: string;
}

const menuIconSpacer = <span aria-hidden="true" />;

function formatFileSize(sizeHeader: string | null, unknownLabel: string): string {
  const bytes = Number(sizeHeader);
  if (!Number.isFinite(bytes) || bytes < 0) return unknownLabel;
  if (bytes < 1024) return `${bytes} bytes`;

  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unitIndex]}`;
}

export function useFileExplorerContextMenu({
  rootFolderPath,
  onFileSelect,
  onCreateNewFileInDirectory,
  onCreateNewFolderInDirectory,
  onGenerateImage,
  onRefreshDirectory,
  onRenamePath,
  onRevealInFinder,
  onUploadFile,
  onDuplicatePath,
  onAddFolderToWorkspace,
  onRemoveFolderFromWorkspace,
  isWorkspaceRootPath,
  canRemoveWorkspaceRootPath,
  onDeleteRequested,
  onStartInlineEditing,
  onOpenAllFilesInDirectory,
}: UseFileExplorerContextMenuOptions) {
  const { t } = useTranslation();
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);
  const [envOverwriteDialog, setEnvOverwriteDialog] = useState<EnvOverwriteDialogState | null>(
    null,
  );
  const [propertiesDialog, setPropertiesDialog] = useState<PropertiesDialogState | null>(null);
  const clipboardActions = useFileClipboardStore.getState().actions;

  const createEnvTemplateFile = useCallback(
    async (sourcePath: string, targetFileName: string, options?: { overwrite?: boolean }) => {
      if (!onCreateNewFileInDirectory) return;

      const directoryPath = getDirName(sourcePath);
      const targetPath = joinPath(directoryPath, targetFileName);

      try {
        if (targetPath === sourcePath) {
          toast.error(t("files.chooseDifferentEnvFileName"));
          return;
        }

        let targetExists = false;
        try {
          await readTextFile(targetPath);
          targetExists = true;
          if (!options?.overwrite) {
            setEnvOverwriteDialog({ sourcePath, targetFileName });
            return;
          }
        } catch {}

        const sourceContent = await readTextFile(sourcePath);
        const templateContent = buildEnvTemplateContent(sourceContent);
        const createdPath = targetExists
          ? targetPath
          : (await Promise.resolve(onCreateNewFileInDirectory(directoryPath, targetFileName))) ||
            targetPath;

        await writeFile(createdPath, templateContent);

        const bufferStore = useBufferStore.getState();
        const createdBuffer = bufferStore.buffers.find((buffer) => buffer.path === createdPath);
        if (createdBuffer) {
          bufferStore.actions.updateBufferContent(createdBuffer.id, templateContent, false);
        }

        onRefreshDirectory?.(directoryPath, { force: true });
        toast.success(t("files.created", { name: targetFileName }));
      } catch (error) {
        console.error("Failed to create env template file:", error);
        toast.error(t("files.createFailed", { name: targetFileName }), {
          description: error instanceof Error ? error.message : undefined,
        });
      }
    },
    [onCreateNewFileInDirectory, onRefreshDirectory, t],
  );

  const handleEnvOverwriteConfirm = useCallback(() => {
    if (!envOverwriteDialog) return;
    const { sourcePath, targetFileName } = envOverwriteDialog;
    setEnvOverwriteDialog(null);
    void createEnvTemplateFile(sourcePath, targetFileName, { overwrite: true });
  }, [createEnvTemplateFile, envOverwriteDialog]);

  const handleContextMenu = useCallback((e: React.MouseEvent, filePath: string, isDir: boolean) => {
    e.preventDefault();
    e.stopPropagation();

    let x = e.pageX;
    let y = e.pageY;
    const menuWidth = 250;
    const menuHeight = 400;

    if (x + menuWidth > window.innerWidth) x = window.innerWidth - menuWidth;
    if (y + menuHeight > window.innerHeight) y = window.innerHeight - menuHeight;

    setContextMenu({ x, y, path: filePath, isDir });
  }, []);

  const contextMenuItems = useMemo<MenuItem[]>(() => {
    if (!contextMenu) return [];

    const items: MenuItem[] = [];

    if (contextMenu.isDir) {
      items.push(
        {
          id: "new-file",
          label: t("files.newFile"),
          icon: <FilePlus />,
          onClick: () => onStartInlineEditing(contextMenu.path, false),
        },
        {
          id: "new-folder",
          label: t("files.newFolder"),
          icon: <FolderPlus />,
          onClick: () => {
            if (onCreateNewFolderInDirectory) onStartInlineEditing(contextMenu.path, true);
          },
        },
        {
          id: "upload-files",
          label: t("files.uploadFiles"),
          icon: <Upload />,
          onClick: () => onUploadFile?.(contextMenu.path),
        },
        {
          id: "refresh",
          label: t("files.refresh"),
          icon: <RefreshCw />,
          onClick: () => onRefreshDirectory?.(contextMenu.path, { force: true }),
        },
        {
          id: "add-folder-to-workspace",
          label: t("files.addFolderToWorkspace"),
          icon: <FolderPlus />,
          onClick: () => onAddFolderToWorkspace?.(),
        },
        ...(canRemoveWorkspaceRootPath?.(contextMenu.path)
          ? [
              {
                id: "remove-folder-from-workspace",
                label: t("files.removeFolderFromWorkspace"),
                icon: <X />,
                onClick: () => onRemoveFolderFromWorkspace?.(contextMenu.path),
              },
            ]
          : []),
        {
          id: "open-all-files",
          label: t("files.openAllFiles"),
          icon: <FolderOpen />,
          onClick: () => void onOpenAllFilesInDirectory(contextMenu.path),
        },
        {
          id: "collapse-all",
          label: t("files.collapseAll"),
          icon: <CaretDoubleUp />,
          onClick: () => useFileTreeStore.getState().actions.collapsePath(contextMenu.path),
        },
        {
          id: "open-terminal",
          label: t("files.openInTerminal"),
          icon: <Terminal />,
          onClick: () => {
            const folderName = getBaseName(contextMenu.path, "terminal");
            const { openTerminalBuffer } = useBufferStore.getState().actions;
            openTerminalBuffer({
              name: folderName,
              workingDirectory: contextMenu.path,
            });
          },
        },
        {
          id: "find-in-folder",
          label: t("files.findInFolder"),
          icon: <Search />,
          onClick: () => {},
        },
      );

      if (onGenerateImage) {
        items.push({
          id: "generate-image",
          label: t("files.generateImage"),
          icon: <ImageIcon />,
          onClick: () => onGenerateImage(contextMenu.path),
        });
      }

      items.push({ id: "sep-dir", label: "", separator: true, onClick: () => {} });
    } else {
      const fileName = getBaseName(contextMenu.path, "");
      const canCreateEnvTemplate =
        isEnvFileName(fileName) &&
        !contextMenu.path.startsWith("remote://") &&
        Boolean(onCreateNewFileInDirectory);

      items.push(
        {
          id: "open",
          label: t("files.open"),
          icon: <FolderOpen />,
          onClick: () => onFileSelect(contextMenu.path, false),
        },
        {
          id: "copy-content",
          label: t("files.copyContent"),
          icon: <Copy />,
          onClick: async () => {
            try {
              const response = await fetch(contextMenu.path);
              const content = await response.text();
              await writeClipboardText(content);
            } catch {}
          },
        },
        {
          id: "duplicate-file",
          label: t("files.duplicate"),
          icon: <FileText />,
          onClick: () => onDuplicatePath?.(contextMenu.path),
        },
        {
          id: "local-history",
          label: t("files.localHistory"),
          icon: <ClockCounterClockwise />,
          onClick: () => openLocalHistoryForPath(contextMenu.path),
        },
        ...(canCreateEnvTemplate
          ? [
              { id: "sep-env-template", label: "", separator: true, onClick: () => {} },
              ...ENV_TEMPLATE_TARGETS.map((target, index) => ({
                id: target.id,
                label: t(target.labelKey),
                icon: index === 0 ? <FilePlus /> : menuIconSpacer,
                onClick: () => void createEnvTemplateFile(contextMenu.path, target.fileName),
              })),
            ]
          : []),
        {
          id: "properties",
          label: t("files.properties"),
          icon: <Info />,
          onClick: async () => {
            const fileName = getBaseName(contextMenu.path, "");
            const extension = fileName.includes(".") ? fileName.split(".").pop() : undefined;
            let size = t("files.sizeUnknown");

            try {
              const stats = await fetch(`file://${contextMenu.path}`, { method: "HEAD" });
              size = formatFileSize(stats.headers.get("content-length"), t("files.sizeUnknown"));
            } catch {}

            setPropertiesDialog({
              fileName,
              path: contextMenu.path,
              size,
              type: extension || t("files.noExtension"),
            });
          },
        },
        { id: "sep-file", label: "", separator: true, onClick: () => {} },
      );
    }

    const shouldShowFileManagementItems =
      !contextMenu.isDir || !isWorkspaceRootPath?.(contextMenu.path);

    items.push(
      {
        id: "copy-path",
        label: t("files.copyPath"),
        icon: <Link />,
        onClick: async () => {
          try {
            await writeClipboardText(contextMenu.path);
          } catch {}
        },
      },
      {
        id: "copy-relative-path",
        label: t("files.copyRelativePath"),
        icon: <FileText />,
        onClick: async () => {
          try {
            const relativePath = getRelativePath(contextMenu.path, rootFolderPath);
            await writeClipboardText(relativePath);
          } catch {}
        },
      },
      {
        id: "copy",
        label: t("files.copy"),
        icon: <Copy />,
        onClick: () =>
          clipboardActions.copy([{ path: contextMenu.path, is_dir: contextMenu.isDir }]),
      },
      {
        id: "cut",
        label: t("files.cut"),
        icon: <Scissors />,
        onClick: () =>
          clipboardActions.cut([{ path: contextMenu.path, is_dir: contextMenu.isDir }]),
      },
    );

    if (contextMenu.isDir) {
      items.push({
        id: "paste",
        label: t("files.paste"),
        icon: <Clipboard />,
        onClick: () => {
          void pasteIntoExplorerDirectory({
            targetDirectory: contextMenu.path,
            createFileInDirectory: onCreateNewFileInDirectory,
            refreshDirectory: onRefreshDirectory,
            onJavaClassCreated: (fileName) => {
              toast.success(t("files.created", { name: fileName }));
            },
            onJavaClassFailed: (error) => {
              if (error instanceof JavaClipboardPasteError) {
                if (error.code === "exists") {
                  toast.error(t("files.javaClassAlreadyExists", { name: error.fileName ?? "" }));
                  return;
                }
                if (error.code === "remote") {
                  toast.error(t("files.javaPasteRemoteUnsupported"));
                  return;
                }
                toast.error(t("files.createFailed", { name: error.fileName ?? "Java class" }));
                return;
              }
              toast.error(t("files.createFailed", { name: "Java class" }), {
                description: error instanceof Error ? error.message : undefined,
              });
            },
            onNothingToPaste: () => {
              toast.error(t("files.nothingToPaste"));
            },
          });
        },
      });
    }

    if (shouldShowFileManagementItems) {
      items.push(
        {
          id: "rename",
          label: t("files.rename"),
          icon: <Edit />,
          onClick: () => onRenamePath?.(contextMenu.path),
        },
        {
          id: "reveal",
          label: t("files.reveal"),
          icon: <Eye />,
          onClick: () => {
            if (onRevealInFinder) onRevealInFinder(contextMenu.path);
            else if (window.electron) window.electron.shell.showItemInFolder(contextMenu.path);
            else {
              const parentDir = getDirName(contextMenu.path);
              window.open(`file://${parentDir}`, "_blank");
            }
          },
        },
        { id: "sep-end", label: "", separator: true, onClick: () => {} },
        {
          id: "delete",
          label: t("files.delete"),
          icon: <Trash />,
          className: "text-destructive",
          onClick: () => onDeleteRequested({ path: contextMenu.path, isDir: contextMenu.isDir }),
        },
      );
    } else {
      items.push({
        id: "reveal",
        label: t("files.reveal"),
        icon: <Eye />,
        onClick: () => onRevealInFinder?.(contextMenu.path),
      });
    }

    return items;
  }, [
    canRemoveWorkspaceRootPath,
    clipboardActions,
    contextMenu,
    createEnvTemplateFile,
    onCreateNewFolderInDirectory,
    onCreateNewFileInDirectory,
    onDeleteRequested,
    onDuplicatePath,
    onFileSelect,
    onGenerateImage,
    onOpenAllFilesInDirectory,
    onAddFolderToWorkspace,
    onRemoveFolderFromWorkspace,
    onRefreshDirectory,
    onRenamePath,
    onRevealInFinder,
    onStartInlineEditing,
    onUploadFile,
    isWorkspaceRootPath,
    rootFolderPath,
    t,
  ]);

  const hasDialog = Boolean(envOverwriteDialog || propertiesDialog);
  const contextMenuElement =
    contextMenu || hasDialog ? (
      <>
        {contextMenu && (
          <Dropdown
            isOpen
            point={{ x: contextMenu.x, y: contextMenu.y }}
            items={contextMenuItems}
            onClose={() => setContextMenu(null)}
          />
        )}

        {envOverwriteDialog && (
          <Dialog
            title={t("files.overwriteEnvTitle")}
            icon={Warning}
            onClose={() => setEnvOverwriteDialog(null)}
            footer={
              <>
                <Button
                  variant="ghost"
                  onClick={() => setEnvOverwriteDialog(null)}
                  className="ui-text-base"
                >
                  {t("files.cancel")}
                </Button>
                <Button
                  variant="danger"
                  onClick={handleEnvOverwriteConfirm}
                  size="xs"
                  className="ui-text-base"
                >
                  {t("files.overwrite")}
                </Button>
              </>
            }
          >
            <p className="font-sans ui-text-base text-foreground">
              {t("files.overwriteEnvMessage", { name: envOverwriteDialog.targetFileName })}
            </p>
          </Dialog>
        )}

        {propertiesDialog && (
          <Dialog title={t("files.properties")} icon={Info} onClose={() => setPropertiesDialog(null)}>
            <dl className="grid grid-cols-[72px_1fr] gap-x-3 gap-y-2 font-sans ui-text-base">
              <dt className="text-subtle-foreground">{t("files.propertiesFile")}</dt>
              <dd className="min-w-0 wrap-break-word text-foreground">
                {propertiesDialog.fileName}
              </dd>
              <dt className="text-subtle-foreground">{t("files.propertiesPath")}</dt>
              <dd className="min-w-0 wrap-break-word text-foreground">{propertiesDialog.path}</dd>
              <dt className="text-subtle-foreground">{t("files.propertiesSize")}</dt>
              <dd className="text-foreground">{propertiesDialog.size}</dd>
              <dt className="text-subtle-foreground">{t("files.propertiesType")}</dt>
              <dd className="text-foreground">{propertiesDialog.type}</dd>
            </dl>
          </Dialog>
        )}
      </>
    ) : null;

  return {
    contextMenu,
    setContextMenu,
    handleContextMenu,
    contextMenuElement,
  };
}
