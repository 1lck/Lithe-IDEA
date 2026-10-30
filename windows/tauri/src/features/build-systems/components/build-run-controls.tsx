import { useEffect, useState, useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Select from "@/ui/select";
import Textarea from "@/ui/textarea";
import AppDialog from "@/ui/dialog";
import { Spinner } from "@/ui/spinner";
import { buildRunNative, type BuildRunNative } from "../build-run-native";
import { type BuildRunSession, getBuildRunSession } from "../build-run-session";
import type { BuildInstanceView } from "../build-systems-types";
import type { BuildRunDefinition, BuildRunScope, BuildRunSelection } from "../build-run-types";
import BuildOutputPane from "../output/components/build-output-pane";

export default function BuildRunControls({
  instance,
  disabled,
  native = buildRunNative,
}: {
  instance: BuildInstanceView;
  disabled: boolean;
  native?: BuildRunNative;
}) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const [session, setSession] = useState<BuildRunSession | null>(null);
  const [acquireError, setAcquireError] = useState("");
  const [acquireRevision, setAcquireRevision] = useState(0);
  useEffect(() => {
    setAcquireError("");
    try {
      const next = getBuildRunSession(
        workspaceId,
        instance.pluginID,
        instance.buildSystemID,
        instance.root,
        native,
      );
      const release = next.attach();
      setSession(next);
      return release;
    } catch (error) {
      setSession(null);
      setAcquireError(error instanceof Error ? error.message : String(error));
    }
  }, [
    workspaceId,
    instance.pluginID,
    instance.buildSystemID,
    instance.root,
    native,
    acquireRevision,
  ]);
  if (acquireError)
    return (
      <section className="mt-3 space-y-2">
        <p role="alert" className="text-xs text-destructive">
          {t("buildSystems.run.failed", { message: acquireError })}
        </p>
        <Button type="button" size="sm" onClick={() => setAcquireRevision((value) => value + 1)}>
          {t("buildSystems.run.retryDefinitions")}
        </Button>
      </section>
    );
  return session?.workspaceId === workspaceId &&
    session.pluginId === instance.pluginID &&
    session.buildSystemId === instance.buildSystemID &&
    session.root === instance.root ? (
    <RunContent key={session.sessionId} instance={instance} disabled={disabled} session={session} />
  ) : null;
}

function RunContent({
  instance,
  disabled,
  session,
}: {
  instance: BuildInstanceView;
  disabled: boolean;
  session: BuildRunSession;
}) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(session.subscribe, session.getSnapshot, session.getSnapshot);
  const [definition, setDefinition] = useState<BuildRunDefinition | null>(null);
  const [definitionError, setDefinitionError] = useState("");
  const [revision, setRevision] = useState(0);
  const [action, setAction] = useState("");
  const [scope, setScope] = useState<BuildRunScope>("workspace");
  const [projectId, setProjectId] = useState("");
  const [targetId, setTargetId] = useState("");
  const [modelTaskId, setModelTaskId] = useState("");
  const [suite, setSuite] = useState("");
  const [testCase, setCase] = useState("");
  const [argumentsText, setArguments] = useState("");
  useEffect(() => {
    let active = true;
    setDefinition(null);
    setDefinitionError("");
    void session.native.definition(instance.pluginID, instance.buildSystemID).then(
      (value) => {
        if (active) setDefinition(value);
      },
      (error) => {
        if (active) setDefinitionError(error instanceof Error ? error.message : String(error));
      },
    );
    return () => {
      active = false;
    };
  }, [session, instance.pluginID, instance.buildSystemID, revision]);
  const tasks = (definition?.tasks ?? []).filter(
    (row) => row.fromModel || !row.execution || row.execution === "task",
  );
  const task = tasks.find((row) => `task:${row.id}` === action);
  const testing = action === "test";
  const scopes = task?.fromModel
    ? ["project" as const]
    : testing
      ? (definition?.test?.scopes ?? [])
      : (task?.scopes ?? []);
  const effectiveScope = scopes.includes(scope) ? scope : scopes[0];
  const project = instance.model?.projects?.find((row) => row.id === projectId);
  const tags = testing ? (definition?.test?.targetTags ?? []) : (task?.targetTags ?? []);
  const targets = (instance.model?.targets ?? []).filter(
    (row) =>
      row.id &&
      row.projectID === project?.id &&
      (!tags.length || tags.some((tag) => row.tags?.includes(tag))),
  );
  const target = targets.find((row) => row.id === targetId);
  const modelTasks = (instance.model?.tasks ?? []).filter(
    (row) => row.projectID === project?.id && row.template === task?.id && row.execution === "task",
  );
  const modelTask = modelTasks.find((row) => row.id === modelTaskId);
  const userArguments = argumentsText.split(/\r?\n/).filter((value) => value.length > 0);
  const valid =
    !!(task || testing) &&
    !!effectiveScope &&
    (effectiveScope === "workspace" || !!project?.id) &&
    (effectiveScope !== "target" || !!target?.id) &&
    (!task?.fromModel || !!modelTask) &&
    (!task?.requiresUserArguments || userArguments.length > 0);
  const busy = ["preparing", "review", "starting", "running", "stopping", "cancelFailed"].includes(
    state.phase,
  );
  const run = () => {
    if (!valid || busy || disabled) return;
    const selection: BuildRunSelection = {
      kind: testing ? "test" : "task",
      taskId: task?.id ?? null,
      projectId: effectiveScope === "workspace" ? null : project!.id!,
      targetId: effectiveScope === "target" ? target!.id! : null,
      modelTaskId: task?.fromModel ? modelTask!.id : null,
      suite: testing && definition?.test?.filters?.includes("suite") ? suite || null : null,
      case: testing && definition?.test?.filters?.includes("case") ? testCase || null : null,
      userArguments,
    };
    void session.start(selection);
  };
  const failure = state.error ?? definitionError;
  const reloadRequired = failure?.includes("plugin.build.modelReloadRequired");
  const missingModel =
    effectiveScope && effectiveScope !== "workspace" && (!instance.model || instance.stale);
  return (
    <section
      className="mt-3 min-w-0 space-y-2 border-t border-border pt-3"
      aria-label={t("buildSystems.run.title")}
    >
      <h3 className="text-xs font-medium">{t("buildSystems.run.title")}</h3>
      {definition && (
        <fieldset disabled={disabled || busy} className="min-w-0 space-y-2">
          <Select
            disabled={disabled || busy}
            aria-label={t("buildSystems.run.action")}
            size="xs"
            value={action}
            onChange={(value) => {
              setAction(value);
              setTargetId("");
              setModelTaskId("");
            }}
            options={[
              { value: "", label: t("buildSystems.run.chooseAction") },
              ...tasks.map((row) => ({
                value: `task:${row.id}`,
                label: [...(row.category ?? (row.group ? [row.group] : [])), row.displayName].join(
                  " / ",
                ),
              })),
              ...(definition.test ? [{ value: "test", label: t("buildSystems.run.tests") }] : []),
            ]}
          />
          {!!scopes.length && (
            <Select
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.scope")}
              size="xs"
              value={effectiveScope}
              onChange={(value) => {
                setScope(value as BuildRunScope);
                setTargetId("");
                setModelTaskId("");
              }}
              options={scopes.map((value) => ({
                value,
                label: t(`buildSystems.run.scope.${value}`),
              }))}
            />
          )}
          {effectiveScope && effectiveScope !== "workspace" && (
            <Select
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.project")}
              size="xs"
              value={projectId}
              onChange={(value) => {
                setProjectId(value);
                setTargetId("");
                setModelTaskId("");
              }}
              options={[
                { value: "", label: t("buildSystems.run.chooseProject") },
                ...(instance.model?.projects ?? [])
                  .filter((row) => row.id)
                  .map((row) => ({
                    value: row.id!,
                    label: `${row.displayName ?? row.name} (${row.path})`,
                  })),
              ]}
            />
          )}
          {effectiveScope === "target" && (
            <Select
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.target")}
              size="xs"
              value={targetId}
              onChange={setTargetId}
              options={[
                { value: "", label: t("buildSystems.run.chooseTarget") },
                ...targets.map((row) => ({
                  value: row.id!,
                  label: `${row.name} [${(row.tags ?? []).join(", ")}]`,
                })),
              ]}
            />
          )}
          {task?.fromModel && (
            <Select
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.modelTask")}
              size="xs"
              value={modelTaskId}
              onChange={setModelTaskId}
              options={[
                { value: "", label: t("buildSystems.run.chooseTask") },
                ...modelTasks.map((row) => ({
                  value: row.id,
                  label: [...(row.category ?? []), row.displayName ?? row.name].join(" / "),
                })),
              ]}
            />
          )}
          {testing && definition.test?.filters?.includes("suite") && (
            <Input
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.suite")}
              placeholder={t("buildSystems.run.suite")}
              value={suite}
              onChange={(event) => setSuite(event.target.value)}
            />
          )}
          {testing && definition.test?.filters?.includes("case") && (
            <Input
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.case")}
              placeholder={t("buildSystems.run.case")}
              value={testCase}
              onChange={(event) => setCase(event.target.value)}
            />
          )}
          {(task || testing) && (
            <Textarea
              disabled={disabled || busy}
              aria-label={t("buildSystems.run.arguments")}
              placeholder={t("buildSystems.run.arguments")}
              rows={2}
              value={argumentsText}
              onChange={(event) => setArguments(event.target.value)}
            />
          )}
        </fieldset>
      )}
      <div className="flex flex-wrap items-center gap-2">
        <Button type="button" size="sm" disabled={disabled || busy || !valid} onClick={run}>
          {t("buildSystems.run.prepare")}
        </Button>
        {busy && (
          <Button
            type="button"
            size="sm"
            variant="ghost"
            disabled={state.phase === "stopping"}
            onClick={() => {
              void session.cancel().catch(() => {});
            }}
          >
            {t(
              state.phase === "cancelFailed"
                ? "buildSystems.model.retryCancel"
                : "buildSystems.run.cancel",
            )}
          </Button>
        )}
        {["preparing", "starting", "stopping"].includes(state.phase) && (
          <Spinner className="size-3.5" />
        )}
        {state.phase !== "idle" && (
          <span role="status" className="text-xs text-muted-foreground">
            {t(`buildSystems.run.phase.${state.phase}`)}
          </span>
        )}
      </div>
      {failure && (
        <p role="alert" className="break-words text-xs text-destructive">
          {reloadRequired
            ? t("buildSystems.run.modelReloadRequired")
            : t("buildSystems.run.failed", { message: failure })}
        </p>
      )}
      {missingModel && !reloadRequired && (
        <p role="status" className="text-xs text-warning">
          {t("buildSystems.run.modelReloadRequired")}
        </p>
      )}
      {definitionError && (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          onClick={() => setRevision((value) => value + 1)}
        >
          {t("buildSystems.run.retryDefinitions")}
        </Button>
      )}
      {state.review && (
        <AppDialog
          title={t("buildSystems.run.review")}
          size="md"
          onClose={() => session.decide(false)}
          footer={
            <>
              <Button type="button" onClick={() => session.decide(false)}>
                {t("buildSystems.model.decline")}
              </Button>
              <Button type="button" variant="accent" onClick={() => session.decide(true)}>
                {t("buildSystems.run.approve")}
              </Button>
            </>
          }
        >
          <dl className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] gap-2 text-xs">
            {(
              [
                ["plugin", state.review.pluginId],
                ["buildSystem", state.review.buildSystemId],
                ["workspace", state.review.workspaceRoot],
                ["instance", state.review.root],
                ["operation", state.review.operationId],
                ["generation", state.review.generation],
              ] as const
            ).map(([key, value]) => (
              <div className="contents" key={key}>
                <dt>{t(`buildSystems.model.${key}`)}</dt>
                <dd className="break-all">{value}</dd>
              </div>
            ))}
            <dt>{t("buildSystems.run.action")}</dt>
            <dd>
              {state.review.title} (
              {t(state.review.kind === "test" ? "buildSystems.run.tests" : "buildSystems.run.task")}
              )
            </dd>
          </dl>
          <p className="mt-3 text-xs text-warning">
            {t(
              state.review.executesProjectCode
                ? "buildSystems.model.projectCode"
                : "buildSystems.model.noProjectCode",
            )}
          </p>
          <p className="mt-2 text-xs text-warning">
            {t(
              state.review.mayUseNetwork
                ? "buildSystems.model.network"
                : "buildSystems.model.noNetwork",
            )}
          </p>
          <p className="mt-3 text-xs">{t("buildSystems.run.programs")}</p>
          <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all text-xs">
            {JSON.stringify(state.programs, null, 2)}
          </pre>
        </AppDialog>
      )}
      <div className="h-80 min-h-48">
        <BuildOutputPane sessionId={session.sessionId} port={session.port} managedEvents />
      </div>
    </section>
  );
}
