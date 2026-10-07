import { useRef, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import Dialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { Field, FieldLabel } from "@/ui/field";
import Select from "@/ui/select";
import { SpringProjectFields } from "./spring-project-fields";
import type { SpringProjectOptions } from "../lib/spring-initializr";
import { getProjectNameError } from "../lib/new-project-model";
import { attachCreatedModule, createWorkspaceModule } from "../services/create-workspace-module";

export function NewModuleDialog({
  workspaceRoot,
  directory,
  onClose,
}: {
  workspaceRoot: string;
  directory: string;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const [source, setSource] = useState<"java" | "spring-boot">("java");
  const [name, setName] = useState("");
  const [parentPath, setParentPath] = useState(directory);
  const [springOptions, setSpringOptions] = useState<SpringProjectOptions | null>(null);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [createdPath, setCreatedPath] = useState<string | null>(null);
  const [error, setError] = useState("");
  const nameError = getProjectNameError(name, t);
  const valid = !nameError && !!parentPath.trim() && (source === "java" || springOptions !== null);
  const create = async () => {
    if (busyRef.current || (!createdPath && !valid)) return;
    busyRef.current = true;
    setBusy(true);
    setError("");
    // Capture this workspace's actions before native work; never attach to a later active project.
    const fileSystem = useFileSystemStore.getState();
    const ports = {
      activeRoot: () => useFileSystemStore.getState().rootFolderPath,
      create: (request: Record<string, unknown>) =>
        invoke<string>("create_project_scaffold", { request }),
      attach: (path: string) => fileSystem.addFolderToWorkspace(path),
    };
    try {
      const result = createdPath
        ? await attachCreatedModule(workspaceRoot, createdPath, ports)
        : await createWorkspaceModule(
            { workspaceRoot, parentPath, name, source, springOptions: springOptions ?? undefined },
            ports,
          );
      setCreatedPath(result.path);
      if (result.attached) onClose();
      else setError(t(`javaModule.${result.reason}`, { path: result.path }));
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : String(reason);
      setError(message.startsWith("newProject.") ? t(message) : message);
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };
  return (
    <Dialog
      title={t("javaModule.moduleTitle")}
      size="lg"
      onClose={() => {
        if (!busyRef.current) onClose();
      }}
      footer={
        <>
          <Button variant="ghost" disabled={busy} onClick={onClose}>
            {t("javaModule.cancel")}
          </Button>
          <Button type="submit" form="new-module-form" disabled={busy || (!createdPath && !valid)}>
            {busy
              ? t("newProject.creatingProject")
              : createdPath
                ? t("files.addFolderToWorkspace")
                : t("javaModule.create")}
          </Button>
        </>
      }
    >
      <form
        id="new-module-form"
        className="space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          void create();
        }}
      >
        <p className="ui-text-sm text-muted-foreground">{t("javaModule.moduleHint")}</p>
        <fieldset disabled={busy || !!createdPath} className="space-y-3">
          <Field>
            <FieldLabel htmlFor="module-kind">{t("javaModule.typeKind")}</FieldLabel>
            <Select
              id="module-kind"
              value={source}
              disabled={busy || !!createdPath}
              options={[
                { value: "java", label: t("javaModule.project") },
                { value: "spring-boot", label: t("javaModule.spring") },
              ]}
              onChange={(value) => {
                setSource(value as "java" | "spring-boot");
                setSpringOptions(null);
              }}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="module-name">{t("javaModule.moduleName")}</FieldLabel>
            <Input
              id="module-name"
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="module-parent">{t("newProject.location")}</FieldLabel>
            <Input
              id="module-parent"
              value={parentPath}
              onChange={(e) => setParentPath(e.target.value)}
            />
          </Field>
          {source === "spring-boot" && (
            <SpringProjectFields
              projectName={name}
              onChange={setSpringOptions}
              initialOptions={springOptions}
            />
          )}
        </fieldset>
        {name && nameError && <p className="text-destructive ui-text-sm">{nameError}</p>}
        {error && (
          <p role="alert" className="text-destructive ui-text-sm break-all">
            {error}
          </p>
        )}
      </form>
    </Dialog>
  );
}
