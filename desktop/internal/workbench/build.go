package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
)

const (
	buildRequestTimeout = 30 * time.Minute
	buildStopTimeout    = 15 * time.Second
	buildOutputMaxLines = 4000
	buildOutputLineSize = 16 << 10
	buildOutputBytes    = 4 << 20
)

// buildState is the Run tool window's state for one project. All fields are
// read and written on the window thread; provider and process objects may be
// used from background goroutines but their own operations are synchronized.
type buildState struct {
	loaded  bool
	loading bool
	failed  string
	// status is the last result line under the output.
	status string
	// output is bounded and stores whole lines; the oldest lines go first.
	output []string
	// outputBytes is the current size of output, so trimming stays cheap.
	outputBytes int
	// outputStart is the sequence number of output[0] and outputSequence counts the
	// lines ever appended. An IDE operation reads from the sequence it started at, so a
	// trimmed console reports a reset instead of silently skipping lines.
	outputStart, outputSequence int

	instances []buildInstance
	selected  int
	projectID string
	targetID  string
	taskID    string

	operation *buildOperation
	runtime   buildRuntime
	// runs are the plugin-started runs the panel keeps beside the build console,
	// and view is the one it shows: "" for the build console, else a run's ID.
	runs []*runEntry
	view string
	// generation rejects a detection or model load that a newer one replaced.
	generation uint64
}

func (s *buildState) reset() {
	*s = buildState{}
}

type buildInstance struct {
	core.BuildInstance
	PluginID           string
	Version            string
	Manifest           json.RawMessage
	PackageDirectory   string
	System             pluginservice.BuildSystemDeclaration
	Model              core.BuildModel
	modelLoaded        bool
	modelLoading       bool
	modelReloadPending bool
	modelError         string
}

// buildOperation is the one provider request or host process the window is
// running. A provider model load also uses one, but it does not expose output.
type buildOperation struct {
	label     string
	provider  *buildprovider.Client
	request   *buildprovider.Operation
	process   *buildprocess.Process
	cancelled bool
}

func (o *buildOperation) stop() {
	if o == nil {
		return
	}
	o.cancelled = true
	if o.process != nil {
		o.process.Stop()
	}
}

// buildRuntime owns provider sessions for one project. A session is keyed by
// plugin and build system, so two projects never share a process.
type buildRuntime struct {
	mu        sync.Mutex
	providers map[string]*buildprovider.Client
	// shared maps a plugin and language to the client attached to that
	// language server's session.
	shared map[string]*buildprovider.Client
	closed bool
}

func (r *buildRuntime) provider(ctx context.Context, runner *pluginbackend.Runner, pluginRoot, root, rootURI string, instance buildInstance, settings core.PluginSettingsState) (*buildprovider.Client, error) {
	key := instance.PluginID + "\x00" + instance.BuildSystemID
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, errors.New("the project is closing")
	}
	if r.providers == nil {
		r.providers = make(map[string]*buildprovider.Client)
	}
	if client := r.providers[key]; client != nil {
		if !client.Closed() {
			return client, nil
		}
		delete(r.providers, key)
	}
	state := buildStateDirectory(pluginRoot, root, instance)
	if err := os.MkdirAll(state, 0o700); err != nil {
		return nil, err
	}
	workspaceState := filepath.Join(state, "workspace")
	logDirectory := filepath.Join(state, "log")
	temporaryDirectory := filepath.Join(state, "tmp")
	for _, directory := range []string{workspaceState, logDirectory, temporaryDirectory} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, err
		}
	}
	client, err := buildprovider.Start(ctx, runner, pluginbackend.StartRequest{
		Manifest:                instance.Manifest,
		PackageDirectory:        instance.PackageDirectory,
		PluginID:                instance.PluginID,
		ProviderID:              instance.PluginID + "/" + instance.BuildSystemID,
		BuildSystemID:           instance.BuildSystemID,
		Role:                    "build",
		StateDirectory:          state,
		WorkspaceStateDirectory: workspaceState,
		LogDirectory:            logDirectory,
		TemporaryDirectory:      temporaryDirectory,
		Architecture:            core.PluginArchitecture(),
		Settings:                settings.Settings,
		ProjectSettings:         settings.ProjectSettings,
		RootURI:                 rootURI,
		WorkingDirectory:        root,
	})
	if err != nil {
		return nil, err
	}
	r.providers[key] = client
	return client, nil
}

func (r *buildRuntime) close(ctx context.Context) {
	r.mu.Lock()
	r.closed = true
	providers := r.providers
	r.providers = nil
	r.mu.Unlock()
	for _, provider := range providers {
		_ = provider.Close(ctx)
	}
	r.mu.Lock()
	shared := r.shared
	r.shared = nil
	r.mu.Unlock()
	for _, provider := range shared {
		_ = provider.Close(ctx)
	}
}

func workspaceDigest(root string) string {
	sum := sha256.Sum256([]byte(filepath.Clean(root)))
	return hex.EncodeToString(sum[:8])
}

func buildStateDirectory(pluginRoot, workspace string, instance buildInstance) string {
	return filepath.Join(pluginRoot, ".state", instance.PluginID, instance.Version, "build", workspaceDigest(workspace))
}

// buildProvider starts a provider process, or attaches to the language server
// that shares it. The caller runs this away from the window thread.
func (a *App) buildProvider(ctx context.Context, p *project, instance buildInstance) (*buildprovider.Client, error) {
	settings, err := a.loadPluginPreferenceSources(ctx, instance.Manifest, p.root)
	if err != nil {
		return nil, err
	}
	rootURI, err := a.kernel.PluginDocumentURI(ctx, p.root, "auto")
	if err != nil {
		return nil, err
	}
	client, err := p.build.runtime.provider(ctx, a.plugins.Backend, a.plugins.Root, p.root, rootURI, instance, settings.State)
	var shared *pluginbackend.SharedProviderError
	if !errors.As(err, &shared) {
		return client, err
	}
	return a.sharedBuildProvider(ctx, p, instance, shared.LanguageID)
}

// sharedBuildProvider attaches a build client to the language server of the
// same plugin. If no server runs yet, it starts one and publishes it as the
// window's language server so both build and editor requests reuse it.
func (a *App) sharedBuildProvider(ctx context.Context, p *project, instance buildInstance, languageID string) (*buildprovider.Client, error) {
	key := instance.PluginID + "\x00" + languageID
	p.build.runtime.mu.Lock()
	if client := p.build.runtime.shared[key]; client != nil && !client.Closed() {
		p.build.runtime.mu.Unlock()
		return client, nil
	}
	p.build.runtime.mu.Unlock()

	a.pluginServerMu.Lock()
	if server := a.pluginServers[instance.PluginID]; server != nil && server.project == p {
		a.pluginServerMu.Unlock()
		return a.attachSharedBuildClient(ctx, p, instance, key, server)
	}
	a.pluginServerMu.Unlock()

	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		return nil, err
	}
	rootURI, err := a.kernel.PluginDocumentURI(ctx, p.root, "auto")
	if err != nil {
		return nil, err
	}
	session, err := a.plugins.StartLanguageServer(ctx, entries, languageID, pluginservice.BackendRequest{
		RootURI:          rootURI,
		WorkingDirectory: p.root,
		Architecture:     core.PluginArchitecture(),
	})
	if err != nil {
		return nil, err
	}
	if session == nil {
		return nil, errors.New("no enabled plugin serves the shared provider language")
	}
	if session.Warnings != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server_selection", session.Warnings))
	}
	server := &pluginServer{session: session, project: p, done: make(chan struct{})}
	serveCtx, serveCancel := context.WithCancel(context.Background())
	server.cancel = serveCancel

	a.pluginServerMu.Lock()
	if ctx.Err() != nil || p.ctx.Err() != nil || a.pluginServerSuppressed[instance.PluginID] {
		a.pluginServerMu.Unlock()
		serveCancel()
		a.stopPluginSession(session)
		return nil, buildprovider.ErrClosed
	}
	if a.pluginServers == nil {
		a.pluginServers = make(map[string]*pluginServer)
		a.pluginServerLanguages = make(map[string]string)
		a.pluginServerStarting = make(map[string]bool)
	}
	if existing := a.pluginServers[instance.PluginID]; existing != nil {
		a.pluginServerMu.Unlock()
		// Another start won; attach to it and dispose the extra session.
		serveCancel()
		a.stopPluginSession(session)
		return a.attachSharedBuildClient(ctx, p, instance, key, existing)
	}
	a.pluginServers[instance.PluginID] = server
	if a.pluginServerLanguages == nil {
		a.pluginServerLanguages = make(map[string]string)
	}
	a.pluginServerLanguages[languageID] = instance.PluginID
	a.pluginServerMu.Unlock()
	a.servePluginServer(server, serveCtx)
	a.post(func(a *App) {
		if a.project != p || !a.isCurrentPluginServer(instance.PluginID, server) {
			return
		}
		a.clearPluginDiagnostics(instance.PluginID)
		a.releasePluginDocuments(instance.PluginID)
		a.openDocumentsForPlugin(p, server, languageID)
	})
	return a.attachSharedBuildClient(ctx, p, instance, key, server)
}

// attachSharedBuildClient waits for the session's real ready event before it
// returns. A language server that is already ready is recorded by pluginServer,
// so Attach can mark this client ready without inventing a ready state.
func (a *App) attachSharedBuildClient(ctx context.Context, p *project, instance buildInstance, key string, server *pluginServer) (*buildprovider.Client, error) {
	client := server.attachBuild(a.plugins.Backend, server.session.Session)
	if err := client.WaitReady(ctx); err != nil {
		server.detachBuild(client)
		_ = client.Close(context.Background())
		return nil, err
	}
	p.build.runtime.mu.Lock()
	if p.build.runtime.closed || ctx.Err() != nil || p.ctx.Err() != nil {
		p.build.runtime.mu.Unlock()
		server.detachBuild(client)
		_ = client.Close(context.Background())
		return nil, buildprovider.ErrClosed
	}
	if p.build.runtime.shared == nil {
		p.build.runtime.shared = make(map[string]*buildprovider.Client)
	}
	p.build.runtime.shared[key] = client
	p.build.runtime.mu.Unlock()
	return client, nil
}

// loadBuildSystems detects provider-backed build systems in the open project.
func (a *App) loadBuildSystems(p *project) {
	if p == nil || p.build.loading {
		return
	}
	if a.plugins == nil || a.plugins.Backend == nil {
		p.build.loaded = true
		p.build.failed = a.text.Build.PluginsUnavailable
		return
	}
	p.build.loading = true
	p.build.failed = ""
	p.build.generation++
	generation := p.build.generation
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishBuildDetection(p, generation, nil, err) }
		}
		plugins, pluginErr := a.plugins.BuildPlugins(ctx, entries)
		manifests := make([]json.RawMessage, 0, len(plugins))
		byPlugin := make(map[string]pluginservice.BuildPlugin, len(plugins))
		for _, plugin := range plugins {
			manifests = append(manifests, plugin.Manifest)
			byPlugin[plugin.PluginID] = plugin
		}
		detection, detectErr := kernel.DetectBuildSystems(ctx, p.root, manifests)
		instances := make([]buildInstance, 0, len(detection.Instances))
		for _, detected := range detection.Instances {
			plugin, ok := byPlugin[detected.PluginID]
			if !ok {
				continue
			}
			system, ok := plugin.Systems[detected.BuildSystemID]
			if !ok {
				continue
			}
			instance := buildInstance{
				BuildInstance:    detected,
				PluginID:         plugin.PluginID,
				Version:          plugin.Version,
				Manifest:         plugin.Manifest,
				PackageDirectory: plugin.Directory,
				System:           system,
			}
			if len(detected.Model) != 0 && string(detected.Model) != "null" {
				if err := json.Unmarshal(detected.Model, &instance.Model); err == nil {
					instance.modelLoaded = true
				}
			}
			instances = append(instances, instance)
		}
		return func(a *App) {
			a.finishBuildDetection(p, generation, instances, errors.Join(pluginErr, detectErr))
		}
	})
}

func (a *App) finishBuildDetection(p *project, generation uint64, instances []buildInstance, err error) {
	if a.project != p || p.build.generation != generation {
		return
	}
	p.build.loading = false
	p.build.loaded = true
	p.build.instances = instances
	if p.build.selected >= len(instances) {
		p.build.selected = 0
	}
	if err != nil && len(instances) == 0 {
		p.build.failed = err.Error()
	} else if err != nil {
		p.build.status = err.Error()
	}
	if len(instances) == 0 {
		p.build.status = a.text.Build.NoBuildSystems
		return
	}
	a.loadBuildModel(p, p.build.selected)
}

// loadBuildModel loads the selected provider-backed instance once.
func (a *App) loadBuildModel(p *project, index int) {
	if p == nil || index < 0 || index >= len(p.build.instances) {
		return
	}
	instance := &p.build.instances[index]
	if instance.modelLoaded || instance.modelLoading {
		return
	}
	instance.modelLoading = true
	instance.modelError = ""
	captured := *instance
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		model, err := a.providerModel(ctx, p, captured, kernel)
		return func(a *App) { a.finishBuildModel(p, captured.ID, model, err) }
	})
}

// reloadBuildModel asks a detected build plugin to load or reload its project model. It
// clears the decoded model first so finishBuildModel replaces it instead of keeping the
// old one; a read that is still in flight is not started twice.
func (a *App) reloadBuildModel(p *project, index int) {
	if p == nil || index < 0 || index >= len(p.build.instances) {
		return
	}
	instance := &p.build.instances[index]
	instance.modelLoaded, instance.modelError = false, ""
	a.loadBuildModel(p, index)
}

// commandModel runs a command-sourced model plan and decodes its output. The
// output file, when the plan uses one, is host-allocated under the plugin's
// writable state and removed after decoding.
func (a *App) commandModel(ctx context.Context, p *project, instance buildInstance, kernel Kernel, messages i18n.BuildMessages) (core.BuildModel, error) {
	state := buildStateDirectory(a.plugins.Root, p.root, instance)
	if err := os.MkdirAll(state, 0o700); err != nil {
		return core.BuildModel{}, err
	}
	file, createErr := os.CreateTemp(state, "model-*.json")
	if createErr != nil {
		return core.BuildModel{}, createErr
	}
	outputFile := file.Name()
	_ = file.Close()
	_ = os.Remove(outputFile)
	defer os.Remove(outputFile)
	plan, err := kernel.PlanBuildModel(ctx, instance.Manifest, instance.BuildSystemID, core.BuildPlanRequest{
		Root:          instance.Root,
		Options:       instance.Options,
		WorkspaceRoot: p.root,
		OutputFile:    outputFile,
	})
	if err != nil {
		return core.BuildModel{}, err
	}
	if plan.Provider != nil {
		return core.BuildModel{}, errors.New("the build system answered with a provider model")
	}
	execution, err := a.resolveBuildExecutable(ctx, p, instance, messages)
	if err != nil {
		return core.BuildModel{}, err
	}
	workingDirectory := filepath.Join(p.root, filepath.FromSlash(plan.WorkingDirectory))
	output, runErr := captureBuildProcess(ctx, execution.Executable, plan.Arguments, workingDirectory, applyToolchainSelection(plan.Environment, execution.selection()))
	request := core.BuildDecodeModelRequest{WorkspaceRoot: p.root, Root: instance.Root, Options: instance.Options}
	if plan.Output == "outputFile" {
		request.OutputFile = outputFile
	} else {
		request.Output = output
	}
	model, decodeErr := kernel.DecodeBuildModel(ctx, instance.Manifest, instance.BuildSystemID, request)
	if decodeErr != nil {
		return core.BuildModel{}, errors.Join(runErr, decodeErr)
	}
	return model, runErr
}

func (a *App) providerModel(ctx context.Context, p *project, instance buildInstance, kernel Kernel) (core.BuildModel, error) {
	plan, err := kernel.PlanBuildModel(ctx, instance.Manifest, instance.BuildSystemID, core.BuildPlanRequest{
		Root:                    instance.Root,
		Options:                 instance.Options,
		WorkspaceRoot:           p.root,
		WorkspaceStateDirectory: "",
	})
	if err != nil {
		return core.BuildModel{}, err
	}
	if plan.Provider == nil {
		return core.BuildModel{}, errors.New("the build system answered with a command model")
	}
	client, err := a.buildProvider(ctx, p, instance)
	if err != nil {
		return core.BuildModel{}, err
	}
	operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
	if err != nil {
		return core.BuildModel{}, err
	}
	result, err := operation.Wait(ctx)
	if err != nil {
		return core.BuildModel{}, err
	}
	return kernel.DecodeBuildModel(ctx, instance.Manifest, instance.BuildSystemID, core.BuildDecodeModelRequest{
		WorkspaceRoot: p.root,
		Root:          instance.Root,
		Result:        result,
		Options:       instance.Options,
	})
}

func (a *App) finishBuildModel(p *project, id string, model core.BuildModel, err error) {
	if a.project != p {
		return
	}
	for index := range p.build.instances {
		if p.build.instances[index].ID != id {
			continue
		}
		instance := &p.build.instances[index]
		instance.modelLoading = false
		if instance.modelReloadPending {
			instance.modelReloadPending = false
			instance.modelLoaded = false
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_model_superseded", err))
			}
			if index == p.build.selected {
				a.loadBuildModel(p, index)
			}
			return
		}
		if err != nil {
			p.build.instances[index].modelError = err.Error()
			p.build.status = err.Error()
			return
		}
		p.build.instances[index].Model = model
		p.build.instances[index].modelLoaded = true
		p.build.status = ""
		return
	}
}

// selectBuildInstance changes the instance and loads its model.
func (a *App) selectBuildInstance(p *project, index int) {
	if p == nil || index < 0 || index >= len(p.build.instances) {
		return
	}
	p.build.selected = index
	p.build.projectID, p.build.targetID, p.build.taskID = "", "", ""
	a.loadBuildModel(p, index)
}

// selectedBuildInstance returns the current instance, or nil.
func (p *project) selectedBuildInstance() *buildInstance {
	if p == nil || p.build.selected < 0 || p.build.selected >= len(p.build.instances) {
		return nil
	}
	return &p.build.instances[p.build.selected]
}

// runSelectedBuildTask runs the selected declared or model task.
func (a *App) runSelectedBuildTask(p *project) {
	_ = a.runBuildTask(p, p.build.projectID, p.build.targetID, p.build.taskID, nil)
}

// runBuildTask runs one declared or model task of the selected instance. The Build window
// passes its stored selection and no user arguments; the IDE API passes the identities a
// client chose. Validation refusals are returned so a tool call can report them, and the
// Build window keeps its notification and ignores the error.
func (a *App) runBuildTask(p *project, projectID, targetID, taskID string, userArguments []string) error {
	instance := p.selectedBuildInstance()
	if instance == nil || taskID == "" {
		a.notify(a.text.Build.ChooseTask)
		return errors.New("choose a build task")
	}
	if p.build.operation != nil {
		return errors.New("the Build window is already running an operation")
	}
	task, modelTask := buildTaskByID(instance, taskID)
	if task == nil && modelTask == nil {
		return errors.New("unknown build task")
	}
	request := core.BuildPlanRequest{
		Root:          instance.Root,
		Options:       instance.Options,
		WorkspaceRoot: p.root,
		UserArguments: append([]string(nil), userArguments...),
	}
	if projectID != "" {
		project, ok := buildProjectByID(instance.Model, projectID)
		if !ok {
			a.notify(a.text.Build.ProjectMissing)
			return errors.New("unknown build project")
		}
		request.Project = &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties}
	}
	if targetID != "" {
		target, ok := buildTargetByID(instance.Model, targetID)
		if !ok {
			a.notify(a.text.Build.TargetMissing)
			return errors.New("unknown build target")
		}
		request.Target = &core.BuildSelection{Name: target.Name, Path: target.Path, Tags: target.Tags, Properties: target.Properties}
	}
	if modelTask != nil {
		request.Task = modelTask.Template
		request.ModelTask = &core.BuildSelection{
			Name: modelTask.Name, Path: modelTask.Path, Execution: modelTask.Execution, Properties: modelTask.Properties,
		}
	} else {
		request.Task = task.ID
		if task.RequiresUserArguments && len(userArguments) == 0 {
			a.notify(a.text.Build.ArgumentsRequired)
			return errors.New("this task requires user arguments")
		}
	}
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "build.runTask", "surface": "build"})
	captured := *instance
	kernel := a.kernel
	messages := a.text.Build
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		plan, err := kernel.PlanBuildTask(ctx, captured.Manifest, captured.BuildSystemID, request)
		if err != nil {
			a.post(func(a *App) { a.finishBuildError(p, err) })
			return nil
		}
		if plan.Provider == nil {
			if err := a.runCommandTask(ctx, p, captured, plan, messages); err != nil {
				a.post(func(a *App) { a.finishBuildError(p, err) })
			}
			return nil
		}
		client, err := a.buildProvider(ctx, p, captured)
		if err != nil {
			a.post(func(a *App) { a.finishBuildError(p, err) })
			return nil
		}
		a.post(func(a *App) { p.build.status = messages.Running })
		a.runProviderOperation(ctx, p, client, plan, buildOperationLabel(captured.System, request.Task, true))
		return nil
	})
	return nil
}

// runCommandTask expands a command plan through Core, resolves the build tool
// in Core's candidate order, and runs it as a host-owned process.
func (a *App) runCommandTask(ctx context.Context, p *project, instance buildInstance, plan core.BuildPlan, messages i18n.BuildMessages) error {
	execution, err := a.resolveBuildExecutable(ctx, p, instance, messages)
	if err != nil {
		return err
	}
	workingDirectory := filepath.Join(p.root, filepath.FromSlash(plan.WorkingDirectory))
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Executable:       execution.Executable,
		Arguments:        plan.Arguments,
		WorkingDirectory: workingDirectory,
		Environment:      applyToolchainSelection(plan.Environment, execution.selection()),
	}, func(_ buildprocess.Stream, text string) {
		a.post(func(a *App) { a.appendBuildOutput(p, text) })
	})
	if err != nil {
		return err
	}
	a.post(func(a *App) {
		p.build.operation = &buildOperation{label: "command", process: process}
		p.build.status = a.text.Build.Running
	})
	err = process.Wait()
	a.post(func(a *App) { a.finishBuildRun(p, err) })
	return nil
}

// resolveBuildExecutable asks Core for the ordered candidates, checks them in
// that order, and probes the declared minimum version. It never falls back to
// a guessed tool name.
func (a *App) resolveBuildExecutable(ctx context.Context, p *project, instance buildInstance, messages i18n.BuildMessages) (buildExecution, error) {
	settings, err := a.loadPluginPreferenceSources(ctx, instance.Manifest, p.root)
	if err != nil {
		return buildExecution{}, err
	}
	invocation, err := a.kernel.PlanBuildInvocation(ctx, instance.Manifest, instance.BuildSystemID, core.BuildInvocationRequest{Root: instance.Root, Platform: buildPlatform(), Settings: settings.State.Settings})
	if err != nil {
		return buildExecution{}, err
	}
	execution := buildExecution{}
	for _, candidate := range invocation.Executables {
		switch candidate.Kind {
		case "projectFile":
			path := filepath.Join(p.root, filepath.FromSlash(candidate.Path))
			if !buildRequiresPresent(path, candidate.Requires, p.root) {
				continue
			}
			if info, statErr := os.Stat(path); statErr == nil && info.Mode().IsRegular() && (runtime.GOOS == "windows" || info.Mode().Perm()&0o111 != 0) {
				execution.Executable = path
			}
		case "environment":
			base := os.Getenv(candidate.Variable)
			if base == "" {
				continue
			}
			path := filepath.Join(base, filepath.FromSlash(candidate.Path))
			if info, statErr := os.Stat(path); statErr == nil && info.Mode().IsRegular() {
				execution.Executable = path
			}
		case "setting":
			if candidate.Path == "" {
				continue
			}
			// An explicit setting is terminal: native lookup failure must not
			// silently select a different installed program.
			path, lookupErr := exec.LookPath(candidate.Path)
			if lookupErr != nil {
				return buildExecution{}, lookupErr
			}
			execution.Executable = path
			execution.PathPrepend = []string{filepath.Dir(path)}
		case "command":
			if path, lookupErr := exec.LookPath(candidate.Command); lookupErr == nil {
				execution.Executable = path
			}
		case "runtime":
			if path, lookupErr := exec.LookPath(candidate.Runtime); lookupErr == nil {
				execution.Executable = path
			}
		case "toolchain":
			selection, selectErr := a.resolveToolchainSelection(ctx, p.root, instance.Root, candidate.ToolchainID, invocation.MinimumVersion)
			if selectErr != nil {
				var unavailable *toolchain.UnavailableError
				if errors.As(selectErr, &unavailable) {
					continue
				}
				return buildExecution{}, selectErr
			}
			execution.Executable = selection.Executable
			execution.Environment = selection.Environment
			execution.PathPrepend = selection.PathPrepend
		}
		if execution.Executable != "" {
			break
		}
	}
	if execution.Executable == "" {
		return buildExecution{}, errors.New(messages.ExecutableMissing)
	}
	if invocation.MinimumVersion != "" && invocation.Version != nil {
		output, probeErr := probeBuildTool(ctx, execution.Executable, invocation.Version.Arguments, p.root, applyToolchainSelection(nil, execution.selection()))
		if probeErr != nil {
			return buildExecution{}, probeErr
		}
		version, checkErr := a.kernel.CheckBuildToolVersion(ctx, instance.Manifest, instance.BuildSystemID, "", output)
		if checkErr != nil {
			return buildExecution{}, checkErr
		}
		if !version.Satisfied {
			return buildExecution{}, errors.New(messages.VersionTooOld(invocation.MinimumVersion, version.Version))
		}
	}
	return execution, nil
}

func buildRequiresPresent(path string, required []string, root string) bool {
	for _, name := range required {
		candidate := filepath.Join(root, filepath.FromSlash(name))
		if info, err := os.Stat(candidate); err != nil || !info.Mode().IsRegular() {
			return false
		}
	}
	_, err := os.Stat(path)
	return err == nil
}

func probeBuildTool(ctx context.Context, executable string, arguments []string, workingDirectory string, environment map[string]string) (string, error) {
	output, waitErr := captureBuildProcess(ctx, executable, arguments, workingDirectory, environment)
	if output == "" {
		return "", waitErr
	}
	return output, nil
}

func captureBuildProcess(ctx context.Context, executable string, arguments []string, workingDirectory string, environment map[string]string) (string, error) {
	var output strings.Builder
	var outputMu sync.Mutex
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Executable:       executable,
		Arguments:        arguments,
		WorkingDirectory: workingDirectory,
		Environment:      environment,
	}, func(_ buildprocess.Stream, text string) {
		outputMu.Lock()
		if output.Len() < 4<<20 {
			output.WriteString(text)
		}
		outputMu.Unlock()
	})
	if err != nil {
		return "", err
	}
	waitErr := process.Wait()
	outputMu.Lock()
	defer outputMu.Unlock()
	return output.String(), waitErr
}

func buildPlatform() string {
	switch runtime.GOOS {
	case "darwin":
		return "macos"
	case "windows":
		return "windows"
	default:
		return "linux"
	}
}

// runBuildTarget prepares and starts one provider application target.
func (a *App) runBuildTarget(p *project, targetID, runID string) {
	instance := p.selectedBuildInstance()
	if instance == nil || p.build.operation != nil {
		return
	}
	projectID := p.build.projectID
	project, ok := buildProjectByID(instance.Model, projectID)
	if !ok {
		a.notify(a.text.Build.ProjectMissing)
		return
	}
	target, ok := buildTargetByID(instance.Model, targetID)
	if !ok {
		a.notify(a.text.Build.TargetMissing)
		return
	}
	captured := *instance
	kernel := a.kernel
	messages := a.text.Build
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "build.runTarget", "surface": "build"})
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		plan, err := kernel.PlanBuildRun(ctx, captured.Manifest, captured.BuildSystemID, core.BuildPlanRequest{
			Root:          captured.Root,
			Options:       captured.Options,
			WorkspaceRoot: p.root,
			Run:           runID,
			Project:       &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties},
			Target:        &core.BuildSelection{Name: target.Name, Path: target.Path, Tags: target.Tags, Properties: target.Properties},
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		if plan.Provider == nil {
			return func(a *App) { a.finishBuildError(p, errors.New(messages.CommandUnsupported)) }
		}
		client, err := a.buildProvider(ctx, p, captured)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		a.post(func(a *App) { p.build.status = messages.Preparing })
		operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		a.post(func(a *App) { p.build.operation = &buildOperation{label: runID, provider: client, request: operation} })
		result, err := operation.Wait(ctx)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		launch, err := kernel.DecodeBuildRun(ctx, captured.Manifest, captured.BuildSystemID, core.BuildDecodeRunRequest{
			WorkspaceRoot: p.root,
			Root:          captured.Root,
			Result:        result,
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		execution := buildExecution{}
		switch launch.Executable.Kind {
		case "command":
			executable, lookupErr := exec.LookPath(launch.Executable.Value)
			if lookupErr != nil {
				return func(a *App) { a.finishBuildError(p, lookupErr) }
			}
			execution.Executable = executable
		case "toolchain":
			selection, selectErr := a.resolveToolchainSelection(ctx, p.root, captured.Root, launch.Executable.Value, "")
			if selectErr != nil {
				return func(a *App) { a.finishBuildError(p, selectErr) }
			}
			execution.Executable = selection.Executable
			execution.Environment = selection.Environment
			execution.PathPrepend = selection.PathPrepend
		default:
			return func(a *App) {
				a.finishBuildError(p, errors.New(messages.ToolchainGap(launch.Executable.Value)))
			}
		}
		workingDirectory := filepath.Join(p.root, filepath.FromSlash(launch.WorkingDirectory))
		process, err := buildprocess.Start(ctx, buildprocess.Spec{
			Executable:       execution.Executable,
			Arguments:        launch.Arguments,
			WorkingDirectory: workingDirectory,
			Environment:      applyToolchainSelection(launch.Environment, execution.selection()),
		}, func(_ buildprocess.Stream, text string) {
			a.post(func(a *App) { a.appendBuildOutput(p, text) })
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, err) }
		}
		a.post(func(a *App) {
			if p.build.operation != nil {
				p.build.operation.process = process
			}
			p.build.status = a.text.Build.Running
		})
		err = process.Wait()
		return func(a *App) { a.finishBuildRun(p, err) }
	})
}

// runProviderOperation sends one provider task and forwards progress and its
// final output into the bounded window output.
func (a *App) runProviderOperation(ctx context.Context, p *project, client *buildprovider.Client, plan core.BuildPlan, label string) {
	operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
	if err != nil {
		a.post(func(a *App) { a.finishBuildError(p, err) })
		return
	}
	a.post(func(a *App) {
		p.build.operation = &buildOperation{label: label, provider: client, request: operation}
	})
	sawProgress := false
	for {
		select {
		case progress, ok := <-operation.Progress():
			if !ok {
				goto done
			}
			if progress.Output != "" {
				sawProgress = true
				a.post(func(a *App) { a.appendBuildOutput(p, progress.Output) })
			}
			if progress.Message != "" {
				a.post(func(a *App) { p.build.status = progress.Message })
			}
		case <-ctx.Done():
			a.post(func(a *App) { a.finishBuildError(p, ctx.Err()) })
			return
		}
	}
done:
	result, err := operation.Wait(ctx)
	if err != nil {
		a.post(func(a *App) { a.finishBuildError(p, err) })
		return
	}
	if !sawProgress {
		var execution struct {
			Output string `json:"output"`
		}
		if json.Unmarshal(result, &execution) == nil && execution.Output != "" {
			a.post(func(a *App) { a.appendBuildOutput(p, execution.Output) })
		}
	}
	a.post(func(a *App) { a.finishBuildTask(p, result) })
}

func (a *App) finishBuildTask(p *project, result json.RawMessage) {
	if a.project != p {
		return
	}
	p.build.operation = nil
	var execution struct {
		ExitCode int `json:"exitCode"`
	}
	exitCode := 0
	decoded := json.Unmarshal(result, &execution) == nil
	if decoded {
		exitCode = execution.ExitCode
	}
	state := "succeeded"
	if decoded && execution.ExitCode != 0 {
		state = "failed"
		p.build.status = a.text.Build.Exited(execution.ExitCode)
		p.settleIDEOperations(state, &exitCode)
		return
	}
	p.build.status = a.text.Build.Succeeded
	p.settleIDEOperations(state, &exitCode)
}

func (a *App) finishBuildRun(p *project, err error) {
	if a.project != p {
		return
	}
	cancelled := p.build.operation != nil && p.build.operation.cancelled
	p.build.operation = nil
	if cancelled {
		p.build.status = a.text.Build.Cancelled
		p.settleIDEOperations("cancelled", nil)
		return
	}
	if err != nil {
		p.build.status = a.text.Build.ProcessFailed(err.Error())
		p.settleIDEOperations("failed", nil)
		return
	}
	exitCode := 0
	p.build.status = a.text.Build.Succeeded
	p.settleIDEOperations("succeeded", &exitCode)
}

func (a *App) finishBuildError(p *project, err error) {
	if a.project != p || err == nil {
		return
	}
	cancelled := p.build.operation != nil && p.build.operation.cancelled
	p.build.operation = nil
	if cancelled || errors.Is(err, context.Canceled) {
		p.build.status = a.text.Build.Cancelled
		p.settleIDEOperations("cancelled", nil)
		return
	}
	p.build.status = err.Error()
	p.settleIDEOperations("failed", nil)
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("build", err))
}

// stopBuildOperation stops the current process and asks the provider to cancel
// its request. The terminal event still clears the operation, so a replacement
// cannot start until Core answers.
func (a *App) stopBuildOperation(p *project) {
	if p == nil || p.build.operation == nil {
		return
	}
	operation := p.build.operation
	operation.stop()
	p.build.status = a.text.Build.Cancelled
	p.settleIDEOperations("cancelled", nil)
	if operation.provider != nil && operation.request != nil {
		client, request := operation.provider, operation.request
		a.background(p, buildStopTimeout, func(ctx context.Context) func(*App) {
			_ = client.Cancel(ctx, request)
			return nil
		})
	}
}

// stopBuild cancels the current operation and stops every provider this project
// started. The sessions are stopped on a background task with a bounded wait.
func (a *App) stopBuild(p *project) {
	if p == nil {
		return
	}
	operation := p.build.operation
	runtime := &p.build.runtime
	p.build.operation = nil
	if operation != nil {
		operation.stop()
	}
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		ctx, cancel := context.WithTimeout(context.Background(), buildStopTimeout)
		defer cancel()
		if operation != nil && operation.request != nil && operation.provider != nil {
			_ = operation.provider.Cancel(ctx, operation.request)
		}
		runtime.close(ctx)
	}()
}

// invalidateBuild drops a project's detected models and provider sessions after
// an install, enablement or uninstall changed the build plugins.
func (a *App) invalidateBuild(p *project) {
	if p == nil {
		return
	}
	a.stopTestsForProject(p)
	a.stopBuild(p)
	// stopBuild captured the old runtime; replacing it lets the next detection
	// start fresh sessions without waiting for the old close.
	p.build = buildState{}
}

// appendBuildOutput adds text to the bounded output, splitting it into lines.
func (a *App) appendBuildOutput(p *project, text string) {
	if p == nil || a.project != p || text == "" {
		return
	}
	for len(text) > 0 {
		line := text
		if index := strings.IndexByte(line, '\n'); index >= 0 {
			line = text[:index+1]
			text = text[index+1:]
		} else {
			text = ""
		}
		if len(line) > buildOutputLineSize {
			line = line[:buildOutputLineSize] + "\n"
		}
		p.build.output = append(p.build.output, line)
		p.build.outputBytes += len(line)
		p.build.outputSequence++
	}
	for len(p.build.output) > buildOutputMaxLines || p.build.outputBytes > buildOutputBytes {
		if len(p.build.output) == 0 {
			break
		}
		p.build.outputBytes -= len(p.build.output[0])
		p.build.output = p.build.output[1:]
		p.build.outputStart++
	}
}

func buildProjectByID(model core.BuildModel, id string) (core.BuildProject, bool) {
	for _, project := range model.Projects {
		if project.ID == id {
			return project, true
		}
	}
	return core.BuildProject{}, false
}

func buildTargetByID(model core.BuildModel, id string) (core.BuildTarget, bool) {
	for _, target := range model.Targets {
		if target.ID == id {
			return target, true
		}
	}
	return core.BuildTarget{}, false
}

func buildTaskByID(instance *buildInstance, id string) (*pluginservice.BuildTaskDeclaration, *core.BuildTask) {
	for index := range instance.System.Tasks {
		task := &instance.System.Tasks[index]
		if task.ID == id && !task.FromModel {
			return task, nil
		}
	}
	for index := range instance.Model.Tasks {
		task := &instance.Model.Tasks[index]
		if task.ID == id {
			return nil, task
		}
	}
	return nil, nil
}

func buildOperationLabel(system pluginservice.BuildSystemDeclaration, task string, provider bool) string {
	if provider {
		return system.DisplayName + ": " + task
	}
	return task
}
