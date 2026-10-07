import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { NewModuleDialog } from "@/features/window/components/new-module-dialog";
import { useNewEntryStore } from "../stores/new-entry.store";
import { NewJavaEntryDialog } from "./new-java-entry-dialog";

/** One modal owner shared by the File menu and explorer New submenus. */
export function NewEntryDialogHost() {
  const request = useNewEntryStore((state) => state.request);
  if (!request) return null;
  const close = () => {
    if (useNewEntryStore.getState().request === request)
      useNewEntryStore.setState({ request: null });
  };
  const key = `${request.kind}:${request.workspaceRoot}:${request.sourceRoot}:${request.directory}`;
  if (request.kind === "module") return <NewModuleDialog key={key} {...request} onClose={close} />;
  return (
    <NewJavaEntryDialog
      key={key}
      directory={request.directory}
      workspaceRoot={request.sourceRoot}
      packageOnly={request.kind === "package"}
      onClose={close}
      onCreated={(path, isDirectory) => {
        const fileSystem = useFileSystemStore.getState();
        if (fileSystem.rootFolderPath !== request.workspaceRoot) return;
        void fileSystem.refreshDirectory(request.directory, { force: true });
        if (!isDirectory) void fileSystem.handleFileSelect(path, false);
      }}
    />
  );
}
