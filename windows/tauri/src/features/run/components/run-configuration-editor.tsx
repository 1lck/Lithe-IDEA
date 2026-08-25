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
  JavaRuntime,
  MavenRuntime,
  RunConfiguration,
  RunOptions,
  RunSaveScope,
} from "../types/run.types";
import {
  configurationOverrides,
  configurationUsesMaven,
  environmentFromText,
  environmentText,
  saveRunConfigurationChanges,
} from "../utils/run-configuration";

interface RunConfigurationEditorProps {
  configuration: RunConfiguration;
  options: RunOptions;
  saveError: string | null;
  discoveredJava: JavaRuntime[];
  discoveredMaven: MavenRuntime[];
  globalToolchain: GlobalToolchain;
  onClose: () => void;
  onSave: (options: RunOptions, scope: RunSaveScope) => Promise<boolean>;
  onSaveToolchain: (toolchain: GlobalToolchain) => Promise<boolean>;
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
  globalToolchain,
  onClose,
  onSave,
  onSaveToolchain,
}: RunConfigurationEditorProps) {
  const { t } = useTranslation();
  const [draft, setDraft] = useState(() => configurationOverrides(options, globalToolchain));
  const [toolchainDraft, setToolchainDraft] = useState(globalToolchain);
  const [scope, setScope] = useState<RunSaveScope>("local");
  const [envText, setEnvText] = useState(environmentText(options.environment));
  const [saving, setSaving] = useState(false);

  const projectUsesMaven = configurationUsesMaven(configuration);
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

  const save = async () => {
    setSaving(true);
    const runOptions = { ...draft, environment: environmentFromText(envText) };
    try {
      // Local options and the global toolchain share run/local.json. Save them
      // in sequence so the option mutation reads the toolchain write instead
      // of racing two complete-document replacements against each other.
      const saved = await saveRunConfigurationChanges(
        () => onSaveToolchain(toolchainDraft),
        () => onSave(runOptions, scope),
      );
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
