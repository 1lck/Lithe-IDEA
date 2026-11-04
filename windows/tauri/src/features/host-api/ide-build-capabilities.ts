import type { buildCore } from "@/platform/build-core-api";
import type { BuildEntry, BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import type { BuildOperation } from "@/features/build/services/build-provider-types";

interface Declaration {
  id: string; configuration?: { source?: string };
  tasks?: Array<{ id: string; displayName: string; source: string; fromModel?: boolean; scopes?: string[]; requiresUserArguments?: boolean }>;
}
const failure = (code: string, message: string) => ({ ok: false, error: { code, message } });
const active = (operation: Pick<BuildOperation, "phase">) => operation.phase === "preparing" || operation.phase === "running";

/** Agent calls borrow the product's workspace owner. Neither an MCP connection
 * nor its authorization owns a second Provider session or execution history. */
export class IdeBuildCapabilities {
  constructor(private readonly workspace: () => BuildWorkspaceController | undefined,
    private readonly current: () => void, private readonly core: typeof buildCore) {}

  private declaration(controller: BuildWorkspaceController, entry: BuildEntry): Declaration | undefined {
    const manifest = controller.snapshot().manifests[entry.pluginID];
    return (manifest?.buildSystems as Declaration[] | undefined)?.find(system => system.id === entry.buildSystemID);
  }

  operations() {
    return this.workspace()?.domain.operationSummaries().map(operation => ({
      operationID: `build:${operation.id}`, kind: "build", configurationID: "", sessionID: operation.id,
      title: `${operation.instance.buildSystemID} · ${operation.instance.root}`,
      state: operation.phase === "succeeded" ? "completed" : operation.phase,
      exitCode: operation.exitCode ?? null, output: undefined,
    })) ?? [];
  }

  output(id: string) { return this.workspace()?.domain.operationOutput(id); }
  stop(id: string) { this.current(); return this.workspace()?.domain.cancel(id) ?? false; }

  private busy(controller: BuildWorkspaceController) { return controller.domain.operationSummaries().some(active); }
  private start(controller: BuildWorkspaceController, entry: BuildEntry,
    begin: () => { operationID: string; completion: Promise<unknown> }) {
    let accepted: ReturnType<typeof begin> | undefined;
    // perform publishes the same selected output slot and retains completion,
    // including errors/cleanup, after the Agent call has returned its ID.
    void controller.perform(entry, () => { this.current(); accepted = begin(); return accepted; });
    return accepted;
  }

  async call(name: string, args: Record<string, unknown>): Promise<unknown> {
    this.current();
    const controller = this.workspace();
    if (!controller) return failure("NOT_AVAILABLE", "Build plugins are unavailable");
    // Detection reads declarations and saved options, never tooling. Native
    // admission still filters every plugin before it enters this catalog.
    await controller.ensureDetected(true); this.current();
    const snapshot = controller.snapshot();
    if (snapshot.status !== "ready") return failure("NOT_READY", snapshot.error ?? "Build detection is unavailable");
    if (name === "lithe_build_inspect") {
      const instances = [];
      for (const entry of snapshot.entries) {
        const manifest = snapshot.manifests[entry.pluginID]!, declaration = this.declaration(controller, entry);
        const model = controller.domain.model(entry);
        const modelCurrent = model && controller.domain.modelGuard(entry);
        const resolved = await this.core<{ options: { options: unknown[] } }>("build.resolveOptions", manifest, entry.buildSystemID,
          { options: entry.options, modelValues: model?.optionValues }, controller.workspacePath);
        this.current();
        // An option/model result cannot republish a removed catalog or a model
        // invalidated while the pure Core request crossed IPC.
        let unchanged = controller.snapshot().entries.includes(entry);
        try { if (modelCurrent) modelCurrent(); else unchanged &&= !controller.domain.hasCurrentModel(entry); }
        catch { unchanged = false; }
        if (!unchanged) {
          return failure("NOT_READY", "Build inputs changed during inspection");
        }
        instances.push({ instanceID: entry.id, pluginID: entry.pluginID, buildSystemID: entry.buildSystemID,
          root: entry.root, name: entry.displayName, reloadRequired: !model,
          modelState: model ? "ready" : controller.domain.operationSummaries().some(operation => active(operation)
            && operation.instance.pluginID === entry.pluginID && operation.instance.buildSystemID === entry.buildSystemID
            && operation.instance.root === entry.root) ? "loading" : "unavailable",
          tasks: (declaration?.tasks ?? []).map(task => ({ id: task.id, name: task.displayName,
            fromModel: task.fromModel ?? false, scopes: task.scopes ?? [], requiresUserArguments: task.requiresUserArguments ?? false })),
          projects: model?.projects.map(({ id, name, path }) => ({ id, name, path })) ?? [],
          targets: model?.targets.map(({ id, projectID, name }) => ({ id, projectID, name })) ?? [],
          modelTasks: model?.tasks.map(task => ({ id: task.id, projectID: task.projectID, taskID: task.template,
            name: task.displayName ?? task.name })) ?? [],
          options: resolved.options.options, nativeConfiguration: declaration?.configuration?.source === "provider" });
      }
      return { detecting: false, issues: snapshot.error ? [snapshot.error] : [], instances };
    }
    const entry = snapshot.entries.find(entry => entry.id === args.instanceID);
    if (!entry) return failure("NOT_FOUND", "Choose a detected build instance");
    if (this.busy(controller)) return failure("BUSY", "A build operation is already active");
    if(name==="lithe_build_configure") {
      if(!controller.canConfigureOptions) return failure("NOT_AVAILABLE","Build option persistence is unavailable");
      const result=await controller.configureOption(entry,args.optionID as string,args.value);
      this.current();
      return {instanceID:entry.id,saved:true,option:result.options.find(option=>option.id===args.optionID),reloadRequired:true};
    }
    if (name === "lithe_build_reload") {
      const operation = this.start(controller, entry, () => controller.domain.loadModel(entry));
      return operation ? { instanceID: entry.id, reloadRequested: true }
        : failure("LAUNCH_FAILED", "Build reload did not start");
    }
    if (name !== "lithe_build_execute") return failure("NOT_SUPPORTED", "Unknown build capability");
    const task = this.declaration(controller, entry)?.tasks?.find(task => task.id === args.taskID && task.source === "provider");
    if (!task) return failure("NOT_FOUND", "Choose a declared build task");
    const model = controller.domain.model(entry);
    if (!model || model.truncated) return failure("NOT_READY", "Reload the build model before executing its task");
    const projectID = args.projectID as string | undefined, targetID = args.targetID as string | undefined;
    const modelTaskID = args.modelTaskID as string | undefined;
    const project = model.projects.find(project => project.id === projectID);
    const target = model.targets.find(target => target.id === targetID && target.projectID === projectID);
    const modelTask = model.tasks.find(selected => selected.id === modelTaskID && selected.projectID === projectID && selected.template === task.id);
    if ((projectID !== undefined && !project) || (targetID !== undefined && (!project || !target))
      || Boolean(task.fromModel) !== (modelTaskID !== undefined) || (modelTaskID !== undefined && (!modelTask || targetID !== undefined))) {
      return failure("NOT_FOUND", "The build selection is no longer available");
    }
    if (!task.fromModel && !task.scopes?.includes(target ? "target" : project ? "project" : "workspace")) {
      return failure("NOT_FOUND", "The task does not support this selection");
    }
    const argumentsSnapshot = [...(args.userArguments as string[] | undefined ?? [])];
    const operation = this.start(controller, entry, () => modelTask
      ? controller.domain.executeModelTask(entry, modelTask.id, argumentsSnapshot)
      : controller.domain.executeTask(entry, task.id, project?.id, argumentsSnapshot, target?.id));
    if (!operation) return failure("LAUNCH_FAILED", "Build launch did not start");
    const state = controller.domain.operationSummary(operation.operationID);
    return { ...(state?.phase === "failed" ? failure("LAUNCH_FAILED", state.error ?? "Build launch failed") : {}),
      operationID: `build:${operation.operationID}`, state: state?.phase ?? "preparing" };
  }
}
