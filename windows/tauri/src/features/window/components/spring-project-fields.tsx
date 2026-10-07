import { useEffect, useMemo, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { isJavaPackageName } from "@/utils/java-name-validation";
import {
  parseInitializrMetadata,
  type InitializrMetadata,
  type SpringProjectOptions,
} from "../lib/spring-initializr";

export function SpringProjectFields({
  projectName,
  onChange,
  initialOptions,
}: {
  projectName: string;
  initialOptions?: SpringProjectOptions | null;
  onChange: (options: SpringProjectOptions | null) => void;
}) {
  const { t } = useTranslation();
  const [metadata, setMetadata] = useState<InitializrMetadata | null>(null);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  const [search, setSearch] = useState("");
  const [artifactOverride, setArtifactOverride] = useState<string | null>(
    initialOptions?.artifactId ?? null,
  );
  const [packageOverride, setPackageOverride] = useState<string | null>(
    initialOptions?.packageName ?? null,
  );
  const [options, setOptions] = useState<SpringProjectOptions>(
    initialOptions ?? {
      groupId: "com.example",
      artifactId: "demo",
      packageName: "com.example.demo",
      bootVersion: "",
      javaVersion: "",
      buildType: "maven-project",
      dependencies: [],
    },
  );
  const artifactId =
    artifactOverride ??
    projectName
      .trim()
      .replace(/[^A-Za-z0-9_-]/g, "-")
      .toLowerCase();
  const packageName =
    packageOverride ?? `${options.groupId}.${artifactId.replace(/-/g, "_") || "demo"}`;
  const valid = Boolean(
    metadata &&
    /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(artifactId) &&
    /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(options.groupId) &&
    isJavaPackageName(packageName) &&
    options.bootVersion &&
    options.javaVersion,
  );

  useEffect(() => {
    let current = true;
    setMetadata(null);
    setError("");
    void invoke<unknown>("spring_initializr_metadata")
      .then(parseInitializrMetadata)
      .then((value) => {
        if (!current) return;
        setMetadata(value);
        setOptions((previous) => ({
          ...previous,
          bootVersion: value.bootVersion.values.some(({ id }) => id === previous.bootVersion)
            ? previous.bootVersion
            : value.bootVersion.default,
          javaVersion: value.javaVersion.values.some(({ id }) => id === previous.javaVersion)
            ? previous.javaVersion
            : value.javaVersion.default,
          dependencies: previous.dependencies.filter((id) =>
            value.dependencies.values.some((group) => group.values.some((item) => item.id === id)),
          ),
        }));
      })
      .catch((reason) => {
        if (current) setError(String(reason));
      });
    return () => {
      current = false;
    };
  }, [retry]);

  useEffect(() => {
    onChange(valid ? { ...options, artifactId, packageName } : null);
  }, [valid, options, artifactId, packageName, onChange]);

  const dependencies = useMemo(
    () =>
      metadata?.dependencies.values
        .flatMap((group) => group.values)
        .filter((item) =>
          `${item.name} ${item.id} ${item.description ?? ""}`
            .toLowerCase()
            .includes(search.toLowerCase()),
        ) ?? [],
    [metadata, search],
  );
  const textField = (id: string, label: string, value: string, change: (value: string) => void) => (
    <Field>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      <Input id={id} value={value} onChange={(event) => change(event.target.value)} />
    </Field>
  );
  return (
    <div className="space-y-3">
      <FieldDescription>{t("javaProject.online")}</FieldDescription>
      {error ? (
        <div role="alert" className="space-y-2 text-destructive">
          {error}
          <Button type="button" onClick={() => setRetry((value) => value + 1)}>
            {t("javaProject.retry")}
          </Button>
        </div>
      ) : !metadata ? (
        <p role="status">{t("javaProject.loading")}</p>
      ) : null}
      {textField("spring-group", t("javaProject.group"), options.groupId, (groupId) =>
        setOptions({ ...options, groupId }),
      )}
      {textField("spring-artifact", t("javaProject.artifact"), artifactId, setArtifactOverride)}
      {textField("spring-package", t("javaProject.package"), packageName, setPackageOverride)}
      <Field>
        <FieldLabel htmlFor="spring-build">{t("javaProject.buildTool")}</FieldLabel>
        <Select
          id="spring-build"
          value={options.buildType}
          onChange={(value) =>
            setOptions({ ...options, buildType: value as SpringProjectOptions["buildType"] })
          }
          options={[
            { value: "maven-project", label: "Maven" },
            { value: "gradle-project", label: "Gradle (Groovy)" },
            { value: "gradle-project-kotlin", label: "Gradle (Kotlin)" },
          ]}
        />
      </Field>
      {metadata && (
        <>
          <Field>
            <FieldLabel htmlFor="spring-boot">{t("javaProject.bootVersion")}</FieldLabel>
            <Select
              id="spring-boot"
              value={options.bootVersion}
              options={metadata.bootVersion.values.map(({ id, name }) => ({
                value: id,
                label: name,
              }))}
              onChange={(bootVersion) => setOptions({ ...options, bootVersion })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="spring-java">{t("javaProject.javaVersion")}</FieldLabel>
            <Select
              id="spring-java"
              value={options.javaVersion}
              options={metadata.javaVersion.values.map(({ id, name }) => ({
                value: id,
                label: name,
              }))}
              onChange={(javaVersion) => setOptions({ ...options, javaVersion })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="spring-dependencies">{t("javaProject.dependencies")}</FieldLabel>
            <Input
              id="spring-dependencies"
              value={search}
              placeholder={t("javaProject.searchDependencies")}
              onChange={(event) => setSearch(event.target.value)}
            />
            <div className="max-h-40 space-y-1 overflow-auto rounded border border-border p-2">
              {dependencies.map((item) => (
                <label
                  key={item.id}
                  className="flex items-center gap-2 ui-text-sm"
                  title={item.description}
                >
                  <input
                    type="checkbox"
                    checked={options.dependencies.includes(item.id)}
                    onChange={(event) =>
                      setOptions({
                        ...options,
                        dependencies: event.target.checked
                          ? [...options.dependencies, item.id]
                          : options.dependencies.filter((id) => id !== item.id),
                      })
                    }
                  />
                  {item.name}
                </label>
              ))}
            </div>
          </Field>
        </>
      )}
      {metadata && !valid && (
        <p role="alert" className="text-destructive ui-text-sm">
          {t("javaProject.invalidPackage")}
        </p>
      )}
    </div>
  );
}
