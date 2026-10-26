import { useEffect, useState, useSyncExternalStore } from "react";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Select from "@/ui/select";
import AppDialog from "@/ui/dialog";
import BuildProviderReviewDetails from "./build-provider-review";
import {
  buildDependenciesNative,
  type BuildDependenciesNative,
} from "../build-dependencies-native";
import {
  getBuildDependenciesSession,
  type BuildDependenciesSession,
} from "../build-dependencies-session";
import type { BuildDependencyNode, BuildDependenciesDefinition } from "../build-dependencies-types";
import type { BuildInstanceView } from "../build-systems-types";
import BuildOutputPane from "../output/components/build-output-pane";

export default function BuildDependencies({
  instance,
  disabled,
  native = buildDependenciesNative,
}: {
  instance: BuildInstanceView;
  disabled: boolean;
  native?: BuildDependenciesNative;
}) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const [session, setSession] = useState<BuildDependenciesSession | null>(null);
  const [error, setError] = useState("");
  const [revision, setRevision] = useState(0);
  useEffect(() => {
    setSession(null);
    setError("");
    try {
      const next = getBuildDependenciesSession(
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
      setError(error instanceof Error ? error.message : String(error));
    }
  }, [workspaceId, instance.pluginID, instance.buildSystemID, instance.root, native, revision]);
  if (error)
    return (
      <section className="mt-3 space-y-2">
        <p role="alert">{t("buildSystems.dependencies.failed", { message: error })}</p>
        <Button size="sm" onClick={() => setRevision((value) => value + 1)}>
          {t("buildSystems.run.retryDefinitions")}
        </Button>
      </section>
    );
  return session &&
    session.workspaceId === workspaceId &&
    session.root === instance.root &&
    session.pluginId === instance.pluginID &&
    session.buildSystemId === instance.buildSystemID ? (
    <DependenciesContent
      key={session.run.sessionId}
      instance={instance}
      session={session}
      disabled={disabled}
    />
  ) : null;
}

function DependenciesContent({
  instance,
  session,
  disabled,
}: {
  instance: BuildInstanceView;
  session: BuildDependenciesSession;
  disabled: boolean;
}) {
  const { t } = useTranslation();
  const state = useSyncExternalStore(session.subscribe, session.getSnapshot, session.getSnapshot);
  const [definition, setDefinition] = useState<BuildDependenciesDefinition | null>(null);
  const [definitionError, setDefinitionError] = useState("");
  const [revision, setRevision] = useState(0);
  const [selected, setSelected] = useState("");
  useEffect(() => {
    let current = true;
    setDefinition(null);
    setDefinitionError("");
    void session.native.definition(instance.pluginID, instance.buildSystemID).then(
      (value) => {
        if (current) setDefinition(value);
      },
      (error) => {
        if (current) setDefinitionError(error instanceof Error ? error.message : String(error));
      },
    );
    return () => {
      current = false;
    };
  }, [session, instance.pluginID, instance.buildSystemID, revision]);
  const source = definition?.dependencies;
  const scopes =
    source?.source === "hostIntegration" ? ["workspace", "project"] : (source?.scopes ?? []);
  const projects = instance.model?.projects?.filter((project) => !!project.id) ?? [];
  const project = projects.find((project) => project.id === selected);
  const projectId = selected ? project?.id : null;
  const busy = ["preparing", "review", "starting", "running", "stopping", "cancelFailed"].includes(
    state.phase,
  );
  const valid =
    !!source &&
    (selected
      ? !!projectId && scopes.includes("project") && !instance.stale
      : scopes.includes("workspace"));
  if (definition && !source) return null;
  return (
    <section
      className="mt-3 space-y-2 border-t border-border pt-3"
      aria-label={t("buildSystems.dependencies.title")}
    >
      <h3 className="text-xs font-medium">{t("buildSystems.dependencies.title")}</h3>
      {source && (
        <>
          <Select
            size="xs"
            aria-label={t("buildSystems.dependencies.selection")}
            value={selected}
            disabled={disabled || busy}
            options={[
              ...(scopes.includes("workspace")
                ? [{ value: "", label: t("buildSystems.dependencies.instance") }]
                : []),
              ...(scopes.includes("project")
                ? projects.map((project) => ({
                    value: project.id!,
                    label: project.displayName ?? project.name,
                  }))
                : []),
            ]}
            onChange={setSelected}
          />
          <div className="flex items-center gap-2">
            <Button
              size="sm"
              disabled={disabled || busy || !valid}
              onClick={() => {
                void session.start(projectId ?? null);
              }}
            >
              {t("buildSystems.dependencies.load")}
            </Button>
            {busy && (
              <Button
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
            {state.phase !== "idle" && (
              <span role="status" className="text-xs text-muted-foreground">
                {t(`buildSystems.run.phase.${state.phase}`)}
              </span>
            )}
          </div>
        </>
      )}
      {(state.error || definitionError) && (
        <p role="alert" className="break-words text-xs text-destructive">
          {t("buildSystems.dependencies.failed", { message: t(state.error ?? definitionError) })}
        </p>
      )}
      {definitionError && (
        <Button size="sm" variant="ghost" onClick={() => setRevision((value) => value + 1)}>
          {t("buildSystems.run.retryDefinitions")}
        </Button>
      )}
      {state.stale && (
        <p role="status" className="text-xs text-warning">
          {t("buildSystems.dependencies.stale")}
        </p>
      )}
      {state.dependencies && !state.stale && (
        <div aria-label={t("buildSystems.dependencies.tree")}>
          {state.truncated && (
            <p role="status" className="text-xs text-warning">
              {t("buildSystems.dependencies.truncated")}
            </p>
          )}
          <p className="text-xs text-muted-foreground">
            {state.projectId
              ? (projects.find((project) => project.id === state.projectId)?.name ??
                state.projectId)
              : t("buildSystems.dependencies.instance")}
          </p>
          {state.dependencies.length ? (
            <DependencyRows nodes={state.dependencies} />
          ) : (
            <p className="text-xs">{t("buildSystems.dependencies.empty")}</p>
          )}
        </div>
      )}
      {state.review && (
        <AppDialog
          title={t("buildSystems.dependencies.review")}
          size="md"
          onClose={() => session.decide(false)}
          footer={
            <>
              <Button onClick={() => session.decide(false)}>
                {t("buildSystems.model.decline")}
              </Button>
              <Button variant="accent" onClick={() => session.decide(true)}>
                {t("buildSystems.dependencies.approve")}
              </Button>
            </>
          }
        >
          <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-2 text-xs">
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
            <dt>{t("buildSystems.run.project")}</dt>
            <dd>
              {state.projectId
                ? (projects.find((row) => row.id === state.projectId)?.name ?? state.projectId)
                : t("buildSystems.dependencies.instance")}
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
          {state.review.provider && <BuildProviderReviewDetails review={state.review.provider} />}
          <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all text-xs">
            {JSON.stringify(state.programs, null, 2)}
          </pre>
        </AppDialog>
      )}
      <div className="h-64 min-h-48">
        <BuildOutputPane sessionId={session.run.sessionId} port={session.run.port} managedEvents />
      </div>
    </section>
  );
}

/** Children mount only on expansion; wide levels are paged independently. */
export function DependencyRows({ nodes }: { nodes: BuildDependencyNode[] }) {
  const { t } = useTranslation();
  const [limit, setLimit] = useState(200);
  return (
    <ul className="space-y-1 pl-3 text-xs">
      {nodes.slice(0, limit).map((node, index) => (
        <DependencyRow key={index} node={node} />
      ))}
      {nodes.length > limit && (
        <li>
          <Button size="sm" variant="ghost" onClick={() => setLimit((value) => value + 200)}>
            {t("buildSystems.dependencies.more")}
          </Button>
        </li>
      )}
    </ul>
  );
}
function DependencyRow({ node }: { node: BuildDependencyNode }) {
  const [open, setOpen] = useState(false);
  const label = [node.group, node.name, node.version].filter(Boolean).join(":");
  const properties = Object.entries(node.properties ?? {});
  return (
    <li>
      <details open={open} onToggle={(event) => setOpen(event.currentTarget.open)}>
        <summary className="cursor-pointer break-all">
          {label}
          {node.scope ? ` (${node.scope})` : ""}
        </summary>
        {open && (
          <>
            {properties.length > 0 && (
              <dl className="ml-3 text-muted-foreground">
                {properties.map(([key, value]) => (
                  <div className="flex gap-2" key={key}>
                    <dt>{key}</dt>
                    <dd className="break-all">{value}</dd>
                  </div>
                ))}
              </dl>
            )}
            {node.children.length > 0 && <DependencyRows nodes={node.children} />}
          </>
        )}
      </details>
    </li>
  );
}
