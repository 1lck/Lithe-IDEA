import { useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import { NativeSelect, NativeSelectOption } from "@/ui/native-select";
import { FolderIcon, PlayIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type {
  GlobalToolchain,
  GenericRuntime,
  JavaRuntime,
  MavenRuntime,
  RunConfiguration,
  RunOptions,
  RunSaveScope,
} from "../types/run.types";
import {
  configurationOverrides,
  configurationUsesJava,
  configurationUsesMaven,
  configurationUsesNode,
  environmentFromText,
  environmentText,
} from "../utils/run-configuration";

interface RunConfigurationEditorProps {
  configuration: RunConfiguration;
  options: RunOptions;
  saveError: string | null;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  discoveredRuntimes: GenericRuntime[];
  globalToolchain: GlobalToolchain;
  onClose: () => void;
  onSave: (
    options: RunOptions,
    toolchain: GlobalToolchain,
    scope: RunSaveScope,
  ) => Promise<boolean>;
}

interface ToolchainFieldProps {
  id: string;
  label: string;
  hint: string;
  value: string;
  autoLabel: string;
  customLabel: string;
  candidates: Array<{ value: string; label: string }>;
  onSelect: (value: string) => void;
  onPick: () => void;
}

function ToolchainField({
  id,
  label,
  hint,
  value,
  autoLabel,
  customLabel,
  candidates,
  onSelect,
  onPick,
}: ToolchainFieldProps) {
  const options = [{ value: "", label: autoLabel }, ...candidates];
  const hasCustomValue = Boolean(value) && !options.some((option) => option.value === value);
  if (hasCustomValue) {
    options.push({ value, label: `${customLabel}: ${value}` });
  }
  return (
    <Field>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      <div className="flex gap-1.5">
        <NativeSelect
          id={id}
          className="min-w-0 flex-1 font-mono"
          value={value}
          onChange={(event) => onSelect(event.target.value)}
        >
          {options.map((option) => (
            <NativeSelectOption key={option.value} value={option.value}>
              {option.label}
            </NativeSelectOption>
          ))}
        </NativeSelect>
        <Button type="button" variant="ghost" size="icon-sm" onClick={() => void onPick()}>
          <FolderIcon />
        </Button>
      </div>
      <FieldDescription>{hint}</FieldDescription>
    </Field>
  );
}

export function RunConfigurationEditor({
  configuration,
  options,
  saveError,
  discoveredJava,
  discoveredMaven,
  discoveredRuntimes,
  globalToolchain,
  onClose,
  onSave,
}: RunConfigurationEditorProps) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState(() => configurationOverrides(options, globalToolchain));
  const [toolchainDraft, setToolchainDraft] = useState(globalToolchain);
  const [scope, setScope] = useState<RunSaveScope>("local");
  const [envText, setEnvText] = useState(environmentText(options.environment));
  const [saving, setSaving] = useState(false);

  const projectUsesMaven = configurationUsesMaven(configuration);
  const projectUsesJava = configurationUsesJava(configuration);
  const projectUsesNode = configurationUsesNode(configuration);
  const javaCandidates = discoveredJava.map((runtime) => ({
    value: runtime.homePath,
    label: runtime.version ? `${runtime.homePath} (${runtime.version})` : runtime.homePath,
  }));
  const mavenCandidates = discoveredMaven.map((runtime) => ({
    value: runtime.executablePath,
    label: runtime.version
      ? `${runtime.executablePath} (${runtime.version})`
      : runtime.executablePath,
  }));
  const nodeCandidates = discoveredRuntimes
    .filter((runtime) => runtime.id === "project-node")
    .map((runtime) => ({
      value: runtime.executablePath,
      label: runtime.version
        ? `${runtime.executablePath} (${runtime.version})`
        : runtime.executablePath,
    }));

  const pickDirectory = (field: "javaHomePath" | "mavenJavaHomePath" | "workingDirectoryPath") => {
    void open({ directory: true, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        setDraft((current) => ({ ...current, [field]: selected }));
      }
    });
  };

  const pickToolchainDirectory = (field: "javaHomePath" | "mavenJavaHomePath") => {
    void open({ directory: true, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        setToolchainDraft((current) => ({ ...current, [field]: selected }));
      }
    });
  };

  const pickMavenHome = (target: "configuration" | "project") => {
    void open({ directory: true, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        if (target === "project") {
          setToolchainDraft((current) => ({ ...current, mavenExecutablePath: selected }));
        } else {
          setDraft((current) => ({ ...current, mavenExecutablePath: selected }));
        }
      }
    });
  };

  const pickNodeExecutable = () => {
    void open({ directory: false, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        setToolchainDraft((current) => ({
          ...current,
          runtimeExecutablePaths: {
            ...current.runtimeExecutablePaths,
            "project-node": selected,
          },
        }));
      }
    });
  };

  const save = async () => {
    setSaving(true);
    const runOptions = { ...draft, environment: environmentFromText(envText) };
    try {
      const saved = await onSave(runOptions, toolchainDraft, scope);
      if (saved) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog
      title={t("run.editorTitle")}
      icon={PlayIcon}
      onClose={onClose}
      size="lg"
      classNames={{ modal: "h-[min(82vh,40rem)]" }}
      footer={
        <>
          {saveError ? <span className="min-w-0 flex-1 truncate text-destructive ui-text-sm">{saveError}</span> : <span />}
          <Button variant="ghost" onClick={onClose}>
            {t("run.cancel")}
          </Button>
          <Button disabled={saving} onClick={() => void save()}>
            {t("run.done")}
          </Button>
        </>
      }
    >
      <div className="space-y-6">
        <div className="space-y-2">
          <div className="font-medium text-subtle-foreground ui-text-sm">
            {t("run.projectDefaultsSection")} · {t("run.saveScopeLocal")}
          </div>
          <p className="text-subtle-foreground ui-text-sm">{t("run.saveScopeLocalHint")}</p>
          {projectUsesJava ? (
            <ToolchainField
              id="run-jdk-home"
              label={t("run.jdkHome")}
              hint={t("run.jdkHomeHint")}
              value={toolchainDraft.javaHomePath}
              autoLabel={t("run.toolchainAuto")}
              customLabel={t("run.toolchainCurrent")}
              candidates={javaCandidates}
              onSelect={(value) => setToolchainDraft((current) => ({ ...current, javaHomePath: value }))}
              onPick={() => pickToolchainDirectory("javaHomePath")}
            />
          ) : null}
          {projectUsesMaven ? (
            <>
              <ToolchainField
                id="run-maven"
                label={t("run.mavenExecutable")}
                hint={t("run.mavenExecutableHint")}
                value={toolchainDraft.mavenExecutablePath}
                autoLabel={t("run.toolchainAuto")}
                customLabel={t("run.toolchainCurrent")}
                candidates={mavenCandidates}
                onSelect={(value) => setToolchainDraft((current) => ({ ...current, mavenExecutablePath: value }))}
                onPick={() => pickMavenHome("project")}
              />
              <ToolchainField
                id="run-maven-jdk"
                label={t("run.mavenJdkHome")}
                hint={t("run.mavenJdkHomeHint")}
                value={toolchainDraft.mavenJavaHomePath}
                autoLabel={t("run.toolchainAuto")}
                customLabel={t("run.toolchainCurrent")}
                candidates={javaCandidates}
                onSelect={(value) => setToolchainDraft((current) => ({ ...current, mavenJavaHomePath: value }))}
                onPick={() => pickToolchainDirectory("mavenJavaHomePath")}
              />
            </>
          ) : null}
          {projectUsesNode ? (
            <ToolchainField
              id="run-node-executable"
              label={t("run.nodeExecutable")}
              hint={t("run.nodeExecutableHint")}
              value={toolchainDraft.runtimeExecutablePaths["project-node"] ?? ""}
              autoLabel={t("run.toolchainAuto")}
              customLabel={t("run.toolchainCurrent")}
              candidates={nodeCandidates}
              onSelect={(value) => setToolchainDraft((current) => ({
                ...current,
                runtimeExecutablePaths: {
                  ...current.runtimeExecutablePaths,
                  "project-node": value,
                },
              }))}
              onPick={pickNodeExecutable}
            />
          ) : null}
        </div>

        <div className="border-border/70 border-t pt-4">
          <div className="space-y-1.5">
            <div className="font-medium text-subtle-foreground ui-text-sm">{t("run.configuration")}</div>
            <div className="grid grid-cols-[7.5rem_1fr] gap-y-1 ui-text-sm">
              <span className="text-subtle-foreground">{t("run.type")}</span>
              <span>{configuration.kindTitle}</span>
              <span className="text-subtle-foreground">{t("run.effectiveSource")}</span>
              <span>{t(`run.source.${configuration.source}`)}</span>
              {configuration.mainClass ? (
                <>
                  <span className="text-subtle-foreground">{t("run.mainClass")}</span>
                  <span className="truncate font-mono">{configuration.mainClass}</span>
                </>
              ) : null}
            </div>
          </div>

          <div className="mt-4">
            <div className="mb-2 font-medium text-subtle-foreground ui-text-sm">{t("run.saveScope")}</div>
            <div className="flex gap-1 rounded-md bg-surface p-0.5">
              <Button
                size="xs"
                variant={scope === "local" ? "accent" : "ghost"}
                onClick={() => setScope("local")}
              >
                {t("run.saveScopeLocal")}
              </Button>
              <Button
                size="xs"
                variant={scope === "project" ? "accent" : "ghost"}
                onClick={() => setScope("project")}
              >
                {t("run.saveScopeProject")}
              </Button>
            </div>
            <p className="mt-2 text-subtle-foreground ui-text-sm">
              {scope === "local" ? t("run.saveScopeLocalHint") : t("run.saveScopeProjectHint")}
            </p>
          </div>

          <div className="mt-4 space-y-4">
            <div className="font-medium text-subtle-foreground ui-text-sm">
              {t("run.configurationOverridesSection")}
            </div>
            {projectUsesJava ? (
              <ToolchainField
                id="run-configuration-jdk-home"
                label={t("run.jdkHome")}
                hint={t("run.configurationOverrideHint")}
                value={draft.javaHomePath}
                autoLabel={t("run.toolchainProjectDefault")}
                customLabel={t("run.toolchainCurrent")}
                candidates={javaCandidates}
                onSelect={(value) => setDraft((current) => ({ ...current, javaHomePath: value }))}
                onPick={() => pickDirectory("javaHomePath")}
              />
            ) : null}
            {projectUsesMaven ? (
              <>
                <ToolchainField
                  id="run-configuration-maven"
                  label={t("run.mavenExecutable")}
                  hint={t("run.configurationOverrideHint")}
                  value={draft.mavenExecutablePath}
                  autoLabel={t("run.toolchainProjectDefault")}
                  customLabel={t("run.toolchainCurrent")}
                  candidates={mavenCandidates}
                  onSelect={(value) => setDraft((current) => ({ ...current, mavenExecutablePath: value }))}
                  onPick={() => pickMavenHome("configuration")}
                />
                <ToolchainField
                  id="run-configuration-maven-jdk"
                  label={t("run.mavenJdkHome")}
                  hint={t("run.configurationOverrideHint")}
                  value={draft.mavenJavaHomePath}
                  autoLabel={t("run.toolchainProjectDefault")}
                  customLabel={t("run.toolchainCurrent")}
                  candidates={javaCandidates}
                  onSelect={(value) => setDraft((current) => ({ ...current, mavenJavaHomePath: value }))}
                  onPick={() => pickDirectory("mavenJavaHomePath")}
                />
                <Field>
                  <FieldLabel htmlFor="run-maven-tests">{t("run.mavenTests")}</FieldLabel>
                  <NativeSelect
                    id="run-maven-tests"
                    value={
                      draft.mavenSkipTests == null
                        ? "inherit"
                        : draft.mavenSkipTests
                          ? "skip"
                          : "run"
                    }
                    onChange={(event) =>
                      setDraft((current) => ({
                        ...current,
                        mavenSkipTests:
                          event.target.value === "inherit" ? null : event.target.value === "skip",
                      }))
                    }
                  >
                    <NativeSelectOption value="inherit">
                      {t("run.mavenTestsProjectDefault")}
                    </NativeSelectOption>
                    <NativeSelectOption value="run">{t("run.mavenTestsRun")}</NativeSelectOption>
                    <NativeSelectOption value="skip">{t("run.mavenTestsSkip")}</NativeSelectOption>
                  </NativeSelect>
                  <FieldDescription>{t("run.mavenTestsHint")}</FieldDescription>
                </Field>
              </>
            ) : null}
            <Field>
              <FieldLabel htmlFor="run-args">{t("run.programArguments")}</FieldLabel>
              <Input
                id="run-args"
                value={draft.programArguments}
                onChange={(event) => setDraft({ ...draft, programArguments: event.target.value })}
                className="font-mono"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="run-vm-args">{t("run.vmArguments")}</FieldLabel>
              <Input
                id="run-vm-args"
                value={draft.vmArguments}
                onChange={(event) => setDraft({ ...draft, vmArguments: event.target.value })}
                className="font-mono"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="run-cwd">{t("run.workingDirectory")}</FieldLabel>
              <Input
                id="run-cwd"
                value={draft.workingDirectoryPath}
                onChange={(event) => setDraft({ ...draft, workingDirectoryPath: event.target.value })}
                className="font-mono"
              />
              <FieldDescription>{t("run.workingDirectoryHint")}</FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="run-env">{t("run.environment")}</FieldLabel>
              <Input
                id="run-env"
                value={envText}
                onChange={(event) => setEnvText(event.target.value)}
                className="font-mono"
                placeholder="KEY=VALUE"
              />
            </Field>
          </div>
        </div>
      </div>
    </Dialog>
  );
}
