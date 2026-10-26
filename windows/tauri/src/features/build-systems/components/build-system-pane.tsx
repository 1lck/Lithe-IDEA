import { useEffect, useMemo, useRef, useState } from "react";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import Input from "@/ui/input";
import Select from "@/ui/select";
import { Spinner } from "@/ui/spinner";
import { parseBuildSystemViewId, useBuildSystemsStore } from "../build-systems-store";
import {
  acquireBuildSyncWatcher,
  refreshBuildSystems,
  setBuildOption,
} from "../build-systems-service";
import type { BuildOptionDescription, BuildWindowState } from "../build-systems-types";
import BuildModelControls, { type BuildModelService } from "./build-model-controls";
import BuildRunControls from "./build-run-controls";
import type { BuildRunNative } from "../build-run-native";

/**
 * Tool window for one declarative build system: Core-resolved options,
 * model data and an explicit consent flow for command-backed models.
 * Declared task/test execution uses the window-owned native coordinator.
 */

export default function BuildSystemPane({
  view,
  onClose,
  modelService,
  runNative,
}: {
  view: string;
  onClose: () => void;
  modelService?: BuildModelService;
  runNative?: BuildRunNative;
}) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const parsed = parseBuildSystemViewId(view);
  const status = useBuildSystemsStore((state) => state.status);
  const error = useBuildSystemsStore((state) => state.error);
  const issues = useBuildSystemsStore((state) => state.issues);
  const generation = useBuildSystemsStore((state) => state.generation);
  const windowState = useBuildSystemsStore((state) => (parsed ? state.windows[view] : undefined));
  const selectInstance = useBuildSystemsStore((state) => state.actions.selectInstance);

  // Mount/reopen retries failed and stale models once. Workspace activation
  // itself is owned by the bootstrap service, including already-ready stores.
  useEffect(() => {
    const state = useBuildSystemsStore.getStore(workspaceId).getState();
    if (
      state.status === "idle" ||
      state.status === "failed" ||
      (state.status === "ready" &&
        Object.values(state.windows).some((target) =>
          target.instances.some((instance) => instance.stale || instance.modelError),
        ))
    ) {
      void refreshBuildSystems().catch(() => {});
    }
  }, [workspaceId]);

  // The debounced sync watcher lives while any build window is mounted; the
  // last unmount releases the shared listener.
  useEffect(() => {
    let release: (() => void) | null = null;
    let cancelled = false;
    void acquireBuildSyncWatcher().then((releaseWatcher) => {
      if (cancelled) {
        releaseWatcher();
        return;
      }
      release = releaseWatcher;
    });
    return () => {
      cancelled = true;
      release?.();
    };
  }, []);

  const instance = useMemo(
    () =>
      windowState?.instances.find((item) => item.root === windowState.selectedRoot) ??
      windowState?.instances[0] ??
      null,
    [windowState],
  );

  if (!parsed) {
    return null;
  }
  const displayName = windowState?.displayName ?? parsed.buildSystemId;

  return (
    <section
      aria-label={displayName}
      className="flex h-full flex-col overflow-hidden bg-surface text-sm text-foreground"
    >
      <header className="flex items-center gap-2 border-b border-border px-3 py-2">
        <h2 className="min-w-0 flex-1 truncate font-medium">{displayName}</h2>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={status === "loading"}
          onClick={() => void refreshBuildSystems().catch(() => {})}
        >
          {t("buildSystems.refresh")}
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onClose}>
          {t("buildSystems.close")}
        </Button>
      </header>

      {issues.length > 0 && (
        <div role="alert" className="border-b border-warning/40 px-3 py-1.5 text-xs text-warning">
          {issues.map((issue, index) => (
            <p key={index}>
              {issue.kind === "rejected"
                ? t("buildSystems.manifestRejected", {
                    plugin: issue.pluginID ?? "",
                    message: issue.error?.message ?? "",
                  })
                : t("buildSystems.shadowed", {
                    plugin: issue.pluginID ?? "",
                    by: issue.by ?? "",
                  })}
            </p>
          ))}
        </div>
      )}
      {error && (
        <div role="alert" className="border-b border-warning/40 px-3 py-1.5 text-xs text-warning">
          {t("buildSystems.detectFailed", { message: error })}
        </div>
      )}

      {status === "loading" && !windowState && (
        <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
          <Spinner className="size-4" />
          {t("buildSystems.loading")}
        </div>
      )}

      {status === "ready" && !windowState?.instances.length && (
        <div className="flex flex-1 items-center justify-center px-6 text-center text-muted-foreground">
          <p>{t("buildSystems.emptyState", { name: displayName })}</p>
        </div>
      )}

      {windowState && windowState.instances.length > 0 && (
        <div className="flex min-h-0 flex-1 flex-col">
          {windowState.instances.length > 1 && (
            <div className="flex items-center gap-2 border-b border-border px-3 py-1.5 text-xs">
              <label htmlFor="build-system-instance" className="text-muted-foreground">
                {t("buildSystems.instanceSelector")}
              </label>
              <Select
                id="build-system-instance"
                className="min-w-0 flex-1"
                size="xs"
                value={windowState.selectedRoot ?? ""}
                options={windowState.instances.map((item) => ({
                  value: item.root,
                  label: item.root,
                }))}
                onChange={(root) => selectInstance(view, root)}
              />
            </div>
          )}
          {instance && (
            <InstanceBody
              key={`${workspaceId}:${instance.pluginID}:${instance.buildSystemID}:${instance.root}`}
              windowState={windowState}
              root={instance.root}
              disabled={status === "loading"}
              generation={generation}
              modelService={modelService}
              runNative={runNative}
            />
          )}
        </div>
      )}
    </section>
  );
}

function InstanceBody({
  windowState,
  root,
  disabled,
  generation,
  modelService,
  runNative,
}: {
  windowState: BuildWindowState;
  root: string;
  disabled: boolean;
  generation: number | null;
  modelService?: BuildModelService;
  runNative?: BuildRunNative;
}) {
  const { t } = useTranslation();
  const instance =
    windowState.instances.find((item) => item.root === root) ?? windowState.instances[0]!;

  return (
    <div className="min-h-0 flex-1 overflow-y-auto px-3 py-2">
      {instance.modelSource === "command" && (
        <BuildModelControls
          key={generation}
          instance={instance}
          disabled={disabled}
          service={modelService}
        />
      )}
      {instance.modelError && (
        <p role="alert" className="mb-2 text-xs text-destructive">
          {t("buildSystems.modelError", {
            message: instance.modelError.message,
          })}
        </p>
      )}
      {instance.stale && (
        <p className="mb-2 text-xs text-warning" role="status">
          {t("buildSystems.staleBanner")}
        </p>
      )}

      {instance.options.length > 0 && (
        <section className="mb-3">
          <h3 className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t("buildSystems.optionsTitle")}
          </h3>
          <ul className="space-y-1">
            {instance.options.map((option) => (
              <li key={option.id}>
                <OptionRow
                  pluginId={instance.pluginID}
                  buildSystemId={instance.buildSystemID}
                  root={instance.root}
                  option={option}
                  disabled={disabled}
                />
              </li>
            ))}
          </ul>
        </section>
      )}

      {(instance.model?.projects?.length ?? 0) > 0 && (
        <section>
          <h3 className="mb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
            {t("buildSystems.projectsTitle")}
          </h3>
          <ul className="space-y-1">
            {(instance.model?.projects ?? []).map((project) => (
              <li key={`${project.path}/${project.name}`} className="text-xs">
                <span className="font-medium">{project.name}</span>
                <span className="ml-1 text-muted-foreground">{project.path}</span>
                {((
                  instance.model?.targets?.filter((row) => row.projectID === project.id) ??
                  project.targets
                )?.length ?? 0) > 0 && (
                  <ul className="ml-3 list-disc">
                    {(
                      instance.model?.targets?.filter((row) => row.projectID === project.id) ??
                      project.targets ??
                      []
                    ).map((target) => (
                      <li key={target.id ?? target.name}>
                        {target.name}
                        {target.tags && target.tags.length > 0 && (
                          <span className="ml-1 text-muted-foreground">
                            [{target.tags.join(", ")}]
                          </span>
                        )}
                      </li>
                    ))}
                  </ul>
                )}
                {((
                  instance.model?.tasks?.filter((row) => row.projectID === project.id) ??
                  project.tasks
                )?.length ?? 0) > 0 && (
                  <ul className="ml-3 list-disc">
                    {(
                      instance.model?.tasks?.filter((row) => row.projectID === project.id) ??
                      project.tasks ??
                      []
                    ).map((task) => (
                      <li key={task.id}>
                        {task.name}
                        {task.group && (
                          <span className="ml-1 text-muted-foreground">{task.group}</span>
                        )}
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
      <BuildRunControls instance={instance} disabled={disabled} native={runNative} />
    </div>
  );
}

function OptionRow({
  pluginId,
  buildSystemId,
  root,
  option,
  disabled,
}: {
  pluginId: string;
  buildSystemId: string;
  root: string;
  option: BuildOptionDescription;
  disabled: boolean;
}) {
  const { t } = useTranslation();
  const title = option.displayName ?? option.id;
  const commit = (value: unknown): Promise<boolean> =>
    setBuildOption(pluginId, buildSystemId, root, option.id, value).then(
      () => true,
      // Core rejects invalid values; keep the draft available for retry.
      () => false,
    );

  if (option.kind === "boolean") {
    const checked = option.value === true;
    return (
      <label className="flex items-center gap-2 text-xs">
        <Checkbox
          disabled={disabled}
          checked={checked}
          onCheckedChange={(checked) => commit(checked === true)}
          aria-label={title}
        />
        {title}
      </label>
    );
  }

  if (option.kind === "multiSelect") {
    const selected = new Set(
      Array.isArray(option.value) ? option.value.map((value) => String(value)) : [],
    );
    return (
      <div className="text-xs">
        <p className="mb-0.5 font-medium">{title}</p>
        <ul className="ml-3 space-y-0.5">
          {option.choices.map((choice) => (
            <li key={choice.value}>
              <label className="flex items-center gap-2">
                <Checkbox
                  disabled={disabled}
                  checked={selected.has(choice.value)}
                  onCheckedChange={(checked) => {
                    const next = new Set(selected);
                    if (checked === true) {
                      next.add(choice.value);
                    } else {
                      next.delete(choice.value);
                    }
                    commit([...next]);
                  }}
                  aria-label={choice.title ?? choice.value}
                />
                {choice.title ?? choice.value}
                {choice.fromModel && (
                  <span className="text-muted-foreground">{t("buildSystems.fromModel")}</span>
                )}
              </label>
            </li>
          ))}
        </ul>
      </div>
    );
  }

  if (option.kind === "singleSelect") {
    return (
      <div className="flex items-center gap-2 text-xs">
        <span className="shrink-0">{title}</span>
        <Select
          className="min-w-0 flex-1"
          size="xs"
          value={typeof option.value === "string" ? option.value : ""}
          options={option.choices.map((choice) => ({
            value: choice.value,
            label: choice.title ?? choice.value,
          }))}
          searchable={option.allowCustom === true}
          allowCustomValue={option.allowCustom === true}
          onChange={commit}
          disabled={disabled}
          aria-label={title}
        />
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={disabled}
          onClick={() => commit(null)}
          aria-label={t("buildSystems.resetOption", { name: title })}
        >
          {t("buildSystems.reset")}
        </Button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-2 text-xs">
      <span className="shrink-0">{title}</span>
      <DraftOptionInput
        value={typeof option.value === "string" ? option.value : ""}
        title={title}
        disabled={disabled}
        onCommit={commit}
      />
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={disabled}
        onClick={() => commit(null)}
        aria-label={t("buildSystems.resetOption", { name: title })}
      >
        {t("buildSystems.reset")}
      </Button>
    </div>
  );
}

/** Keeps partial edits local until a complete value is submitted to Core. */
function DraftOptionInput({
  value,
  title,
  disabled,
  onCommit,
}: {
  value: string;
  title: string;
  disabled: boolean;
  onCommit: (value: string) => Promise<boolean>;
}) {
  const [draft, setDraft] = useState(value);
  const focused = useRef(false);
  const submitted = useRef(value);
  useEffect(() => {
    if (!focused.current) {
      setDraft(value);
      submitted.current = value;
    }
  }, [value]);
  const submit = () => {
    if (draft === submitted.current) return;
    const previous = submitted.current;
    submitted.current = draft;
    void onCommit(draft).then((accepted) => {
      if (!accepted && submitted.current === draft) submitted.current = previous;
    });
  };
  return (
    <Input
      size="xs"
      className="min-w-0 flex-1"
      value={draft}
      disabled={disabled}
      aria-label={title}
      onFocus={() => {
        focused.current = true;
      }}
      onChange={(event) => setDraft(event.target.value)}
      onBlur={() => {
        focused.current = false;
        submit();
      }}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing) return;
        if (event.key === "Enter") {
          event.preventDefault();
          submit();
        } else if (event.key === "Escape") {
          event.preventDefault();
          setDraft(value);
          submitted.current = value;
        }
      }}
    />
  );
}
