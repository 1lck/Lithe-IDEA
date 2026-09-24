import { useState, type ReactNode } from "react";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useEffect, useState, type ReactNode } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { MavenDetectedValue } from "@/features/maven/components/maven-detected-value";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { Button } from "@/ui/button";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import Input from "@/ui/input";
import { NativeSelect, NativeSelectOption } from "@/ui/native-select";
import { FolderIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import type {
  GlobalToolchain,
  GenericRuntime,
  JavaRuntime,
  MavenRuntime,
  RunConfiguration,
  RunDiagnostic,
  RunOptions,
  RunSaveScope,
} from "../types/run.types";
import { EffectiveToolchain } from "./effective-toolchain";
import { useResolvedToolchains } from "../hooks/use-resolved-toolchains";
import {
  launchToolchainSelection,
  toolchainRequirementMessages,
  type EffectiveToolchainMode,
} from "../utils/effective-toolchain";
import {
  configurationOverrides,
  configurationUsesJava,
  configurationUsesMaven,
  configurationUsesNode,
  environmentFromText,
  environmentText,
} from "../utils/run-configuration";

interface RunConfigurationEditorProps {
  /** Project root, used to show which JDK and Maven this configuration launches with. */
  root: string;
  configuration: RunConfiguration;
  /** Core diagnostics, including unmet toolchain requirements. */
  diagnostics: RunDiagnostic[];
  /** Explicit Maven tool window choices, which a launch falls back to. */
  mavenSelection: { mavenExecutablePath: string; javaHomePath: string } | null;
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
  /** What a launch would use for the current value. */
  effective?: ReactNode;
  /**
   * Extra content under the field, used by the Maven paths to show what a blank
   * field resolves to. Left undefined by fields without a detected value.
   */
  footer?: ReactNode;
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
  effective,
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
      {effective}
    </Field>
  );
}

export function RunConfigurationEditor({
  root,
  configuration,
  diagnostics,
  mavenSelection,
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
  // The Maven settings page owns the project-wide Maven paths, so this editor
  // shows and edits the same values instead of a private copy.
  const mavenSettingsPath = useMavenStore((state) => state.settingsPath);
  const mavenLocalRepositoryPath = useMavenStore((state) => state.localRepositoryPath);
  const mavenExecutablePath = useMavenStore((state) => state.mavenExecutablePath);
  const mavenJavaHomePath = useMavenStore((state) => state.javaHomePath);
  const mavenEffectiveConfiguration = useMavenStore((state) => state.effectiveConfiguration);
  const mavenEffectiveStatus = useMavenStore((state) => state.effectiveConfigurationStatus);
  const mavenProject = useMavenStore((state) => state.project);
  const updateMavenConfiguration = useMavenStore((state) => state.actions.updateLocalConfiguration);
  const [draft, setDraft] = useState(() => ({
    ...configurationOverrides(options, globalToolchain),
    mavenExecutablePath,
    mavenJavaHomePath,
  }));
  const [toolchainDraft, setToolchainDraft] = useState(() => ({
    ...globalToolchain,
    mavenExecutablePath,
    mavenJavaHomePath,
  }));
  const [scope, setScope] = useState<RunSaveScope>("local");
  const [envText, setEnvText] = useState(environmentText(options.environment));
  const [saving, setSaving] = useState(false);

  // Both sections edit the same shared Maven paths, so one edit updates the
  // other section and vice versa.
  const setSharedMavenPaths = (patch: {
    mavenExecutablePath?: string;
    mavenJavaHomePath?: string;
  }) => {
    setToolchainDraft((current) => ({ ...current, ...patch }));
    setDraft((current) => ({ ...current, ...patch }));
  };

  // The drafts above snapshot the store when this editor mounts; mirror later
  // changes so values saved from the settings page (or loaded afterwards) show.
  useEffect(() => {
    setSharedMavenPaths({ mavenExecutablePath, mavenJavaHomePath });
    // eslint-disable-next-line react-hooks/exhaustive-deps -- setSharedMavenPaths updates both drafts and is recreated each render
  }, [mavenExecutablePath, mavenJavaHomePath]);

  const projectUsesMaven = configurationUsesMaven(configuration);
  const projectUsesJava = configurationUsesJava(configuration);
  const projectUsesNode = configurationUsesNode(configuration);
  // Resolve what this draft would launch with; an empty Maven JDK then
  // inherits this configuration's JDK in the host.
  const selection = launchToolchainSelection(draft, globalToolchain, mavenSelection);
  const resolved = useResolvedToolchains(
    projectUsesJava || projectUsesMaven ? root : null,
    selection.javaHomePath,
    selection.mavenExecutablePath,
    selection.mavenJavaHomePath,
  );
  const overrideMode = (value: string): EffectiveToolchainMode =>
    value ? "configured" : "inherit";
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

  // The Maven paths show what a blank field resolves to, exactly as the settings
  // page does; other toolchain fields have no detected counterpart here.
  const detectedMavenValue = (
    field: "mavenExecutablePath" | "mavenJavaHomePath",
    value: string,
  ) => {
    const effectiveField =
      field === "mavenExecutablePath" ? "mavenExecutablePath" : "javaHomePath";
    return (
      <MavenDetectedValue
        field={effectiveField}
        value={value}
        effective={mavenEffectiveConfiguration}
        status={mavenEffectiveStatus}
      />
    );
  };

  const pickDirectory = (field: "javaHomePath" | "mavenJavaHomePath" | "workingDirectoryPath") => {
    void open({ directory: true, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        if (field === "mavenJavaHomePath") {
          setSharedMavenPaths({ mavenJavaHomePath: selected });
        } else {
          setDraft((current) => ({ ...current, [field]: selected }));
        }
      }
    });
  };

  const pickMavenHome = () => {
    void open({ directory: true, multiple: false }).then((selected) => {
      if (typeof selected === "string" && selected) {
        setDraft((current) => ({ ...current, mavenExecutablePath: selected }));
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
    // A Maven project keeps these paths in the Maven settings document. The run
    // documents must not keep a second copy, or a blank automatic field gets
    // filled back in from the toolchain the next time the project opens.
    const mavenPathsOwnedBySettings = Boolean(mavenProject);
    const runOptions = {
      ...draft,
      environment: environmentFromText(envText),
      ...(mavenPathsOwnedBySettings
        ? { mavenExecutablePath: "", mavenJavaHomePath: "" }
        : {}),
    };
    const toolchainToSave = mavenPathsOwnedBySettings
      ? { ...toolchainDraft, mavenExecutablePath: "", mavenJavaHomePath: "" }
      : toolchainDraft;
    try {
      if (mavenPathsOwnedBySettings) {
        updateMavenConfiguration({
          settingsPath: mavenSettingsPath,
          localRepositoryPath: mavenLocalRepositoryPath,
          mavenExecutablePath: toolchainDraft.mavenExecutablePath,
          javaHomePath: toolchainDraft.mavenJavaHomePath,
        });
      }
      const saved = await onSave(runOptions, toolchainToSave, scope);
      if (saved) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="space-y-6">
        <div className="space-y-2">
          <div className="font-medium text-subtle-foreground ui-text-sm">
            {t("run.projectDefaultsSection")} · {t("run.saveScopeLocal")}
          </div>
          <p className="text-subtle-foreground ui-text-sm">{t("run.saveScopeLocalHint")}</p>
          {(projectUsesJava || projectUsesMaven) && (
            <Button variant="ghost" onClick={() => {
              onClose();
              useUIState.getState().openSettingsDialog("project");
            }}>{t("settings.project.openSettings")}</Button>
          )}
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
            <p className="text-subtle-foreground ui-text-sm">{t("settings.project.overrides")}</p>
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
                effective={
                  <EffectiveToolchain
                    state={resolved.java}
                    kind="java"
                    mode={overrideMode(draft.javaHomePath)}
                    requirements={toolchainRequirementMessages(
                      diagnostics,
                      "project-jdk",
                      configuration.id,
                    )}
                  />
                }
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
                  onPick={pickMavenHome}
                  effective={
                    <EffectiveToolchain
                      state={resolved.maven}
                      kind="maven"
                      mode={overrideMode(draft.mavenExecutablePath)}
                      requirements={toolchainRequirementMessages(
                        diagnostics,
                        "project-maven",
                        configuration.id,
                      )}
                    />
                  }
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
                  effective={
                    <EffectiveToolchain
                      state={resolved.mavenJava}
                      kind="java"
                      mode={overrideMode(draft.mavenJavaHomePath)}
                    />
                  }
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
      <div className="flex items-center justify-end gap-2 border-t border-border pt-3">
        {saveError && <span role="alert" className="text-destructive ui-text-sm">{saveError}</span>}
        <Button variant="ghost" disabled={saving} onClick={onClose}>{t("run.cancel")}</Button>
        <Button disabled={saving} onClick={() => void save()}>{t("ui.save")}</Button>
      </div>
    </div>
  );
}
