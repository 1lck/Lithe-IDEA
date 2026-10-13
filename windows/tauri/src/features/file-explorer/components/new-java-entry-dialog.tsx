import { useRef, useState } from "react";
import Dialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import { useTranslation } from "@/i18n/locale-provider";
import {
  JAVA_TYPE_KINDS,
  isJavaIdentifier,
  isJavaPackageName,
  suggestJavaSourceLocation,
  type JavaTypeKind,
} from "../lib/java-source-template";
import { createJavaPackage, createJavaType } from "../services/create-java-entry";

export function NewJavaEntryDialog({
  directory,
  workspaceRoot,
  packageOnly,
  onClose,
  onCreated,
}: {
  directory: string;
  workspaceRoot: string;
  packageOnly: boolean;
  onClose: () => void;
  onCreated: (path: string, isDirectory: boolean) => void;
}) {
  const { t } = useTranslation();
  const suggestion = suggestJavaSourceLocation(workspaceRoot, directory);
  const [name, setName] = useState("");
  const [kind, setKind] = useState<JavaTypeKind>("class");
  const [packageName, setPackageName] = useState(suggestion.packageName);
  const [withMain, setWithMain] = useState(false);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  const [error, setError] = useState("");
  const valid = packageOnly
    ? isJavaPackageName(name)
    : isJavaPackageName(packageName, kind !== "packageInfo") &&
      (kind === "packageInfo" || isJavaIdentifier(name));
  const create = async () => {
    if (!valid || busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setError("");
    try {
      const path = packageOnly
        ? await createJavaPackage(directory, name)
        : await createJavaType({
            sourceRoot: suggestion.sourceRoot,
            name,
            kind,
            packageName,
            withMain,
          });
      onCreated(path, packageOnly);
      onClose();
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : String(reason);
      setError(message.startsWith("javaEntry.") ? t(message) : t("javaEntry.failed", { message }));
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  };
  return (
    <Dialog
      title={t(packageOnly ? "javaEntry.newPackage" : "javaEntry.title")}
      onClose={() => {
        if (!busyRef.current) onClose();
      }}
      footer={
        <>
          <Button variant="ghost" disabled={busy} onClick={onClose}>
            {t("javaEntry.cancel")}
          </Button>
          <Button type="submit" form="new-java-entry" disabled={!valid || busy}>
            {busy ? t("newProject.creatingProject") : t("javaEntry.create")}
          </Button>
        </>
      }
    >
      <form
        id="new-java-entry"
        className="space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          void create();
        }}
      >
        <p className="break-all font-mono ui-text-sm">{directory}</p>
        {(packageOnly || kind !== "packageInfo") && (
          <Field>
            <FieldLabel htmlFor="java-name">
              {t(packageOnly ? "javaEntry.package" : "javaEntry.typeName")}
            </FieldLabel>
            <Input
              autoFocus
              id="java-name"
              disabled={busy}
              value={name}
              onChange={(event) => setName(event.target.value)}
              placeholder={packageOnly ? "com.example" : "MyClass"}
            />
          </Field>
        )}
        {!packageOnly && (
          <Field>
            <FieldLabel htmlFor="java-kind">{t("javaEntry.typeKind")}</FieldLabel>
            <div
              id="java-kind"
              role="radiogroup"
              aria-label={t("javaEntry.typeKind")}
              className="rounded-md border border-border p-1"
            >
              {JAVA_TYPE_KINDS.map((value) => (
                <label
                  key={value}
                  className={`flex cursor-pointer items-center gap-2 rounded px-2 py-1 ui-text-sm ${kind === value ? "bg-accent text-foreground" : "hover:bg-accent/60"}`}
                >
                  <input
                    type="radio"
                    name="java-kind"
                    value={value}
                    checked={kind === value}
                    disabled={busy}
                    onChange={() => setKind(value)}
                  />
                  {t(`javaEntry.${value}`)}
                </label>
              ))}
            </div>
          </Field>
        )}
        {!packageOnly && (
          <Field>
            <FieldLabel htmlFor="java-package">{t("javaEntry.package")}</FieldLabel>
            <Input
              id="java-package"
              disabled={busy}
              value={packageName}
              onChange={(event) => setPackageName(event.target.value)}
            />
            <FieldDescription>{t("javaEntry.packageHint")}</FieldDescription>
          </Field>
        )}
        {!packageOnly && kind === "class" && (
          <label className="flex items-center gap-2 ui-text-sm">
            <input
              type="checkbox"
              disabled={busy}
              checked={withMain}
              onChange={(event) => setWithMain(event.target.checked)}
            />
            {t("javaEntry.withMain")}
          </label>
        )}
        {!valid && name && (
          <p className="text-destructive ui-text-sm">
            {t(
              packageOnly || !isJavaPackageName(packageName, true)
                ? "javaEntry.invalidPackage"
                : "javaEntry.invalidName",
            )}
          </p>
        )}
        {error && (
          <p role="alert" className="text-destructive ui-text-sm">
            {error}
          </p>
        )}
      </form>
    </Dialog>
  );
}
