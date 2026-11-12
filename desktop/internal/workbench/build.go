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
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
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
	// options is the Build options editor of the selected instance (build_options.go).
	options buildOptionsEditor
	// reloadPending says a stored option changed while a detection was running, so the instances are
	// detected again when that detection ends.
	reloadPending bool
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
	// runs are the plugin-started runs the panel keeps beside the build console,
	// and view is the one it shows: "" for the build console, else a run's ID.
	runs []*runEntry
	view string
	// generation rejects a detection or model load that a newer one replaced.
	generation uint64
	// dependencies are the loaded dependency trees by instance and project
	// (build_dependencies.go).
	dependencies map[string]*buildDependencies
	// discovered are the discovered tests by instance (build_tests.go).
	discovered map[string]*buildDiscoveredTests
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

// buildOperation is the one Build execution the window runs: a task or a run, from the
// moment its start is accepted until it ends. beginBuildOperation takes it before the plan,
// the saves and the provider request, so a second start is refused and Stop works while the
// execution is still being prepared; the provider request or host process it started is
// attached once it exists. Its fields belong to the window thread; the goroutine preparing it
// reads only stopped, through bind.
type buildOperation struct {
	// configuration is the run configuration the operation runs, "" for anything else.
	configuration string
	provider      *buildprovider.Client
	request       *buildprovider.Operation
	process       *buildprocess.Process
	cancelled     bool
	// stopped is closed by stop.
	stopped chan struct{}
	// ide is the execution's IDE API identity and state (ide_api_dispatch.go).
	ide *ideAPIOperation
}

// beginBuildOperation makes a new operation the window's current one and gives it the IDE
// identity of the execution. kind is "build" for a task and "run" for an application run;
// label names it in the operations list. Every path that follows ends it with
// finishBuildTask, finishBuildRun or finishBuildError for this operation.
func (a *App) beginBuildOperation(p *project, kind, label, configuration string) *buildOperation {
	operation := &buildOperation{configuration: configuration, stopped: make(chan struct{})}
	operation.ide = p.recordIDEOperation(kind, label, configuration)
	p.build.operation = operation
	p.build.status = a.text.Build.Preparing
	return operation
}

// bind returns ctx ending also when the operation is stopped, so the kernel and provider calls
// that prepare the execution end at once. A host process is not started with it: Stop ends a
// process through its own termination. The preparing goroutine calls cancel when it is done.
func (o *buildOperation) bind(ctx context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-o.stopped:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, cancel
}

// stop ends the operation's preparation and its process. The first stop asks the process tree
// to stop and gives it the stop time; stopping again kills it at once. A provider request is
// cancelled by the caller, which owns the bounded wait for the provider's answer.
func (o *buildOperation) stop() {
	if o == nil {
		return
	}
	again := o.cancelled
	if !again && o.stopped != nil {
		close(o.stopped)
	}
	o.cancelled = true
	if o.process == nil {
		return
	}
	if again {
		o.process.Kill()
	} else {
		o.process.Stop()
	}
}

// buildRefusal is a start the window refused before it reserved an operation. code is the
// IDE API failure code a tool call reports for it; the Build window shows nothing for one,
// because its controls never offer the refused start.
type buildRefusal struct {
	code, message string
}

func (r *buildRefusal) Error() string { return r.message }

// The IDE API failure codes a refused start maps to (shared/contracts/ide-api/v1.md).
const (
	refusalInvalid      = "INVALID_ARGUMENTS"
	refusalNotFound     = "NOT_FOUND"
	refusalNotReady     = "NOT_READY"
	refusalNotSupported = "NOT_SUPPORTED"
	refusalBusy         = "BUSY"
)

// refuseBuild returns the refusal of a start with the IDE API code and message.
func refuseBuild(code, message string) error { return &buildRefusal{code: code, message: message} }

// errBuildBusy refuses a start while the window runs another execution.
var errBuildBusy = refuseBuild(refusalBusy, "the Build window is already running an operation")

// attachProcess makes process the operation's process once it started. It reports false, and
// stops the process, when the operation was stopped or replaced while the process started.
func (a *App) attachProcess(p *project, op *buildOperation, process *buildprocess.Process) bool {
	if op.cancelled || p.build.operation != op {
		process.Stop()
		return false
	}
	op.process = process
	op.ide.start()
	p.build.status = a.text.Build.Running
	return true
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
	// detached counts detaches: a start that began before one belongs to the sessions it took
	// and is stopped instead of kept.
	detached uint64
}

// provider is the running provider of instance, started when there is none. The process starts
// outside the lock, so detaching on the window thread never waits for a start; a start that lost
// to another one or to a detach is stopped again.
func (r *buildRuntime) provider(ctx context.Context, runner *pluginbackend.Runner, pluginRoot, root, rootURI string, instance buildInstance, settings core.PluginSettingsState) (*buildprovider.Client, error) {
	key := instance.PluginID + "\x00" + instance.BuildSystemID
	errClosing := errors.New("the project is closing")
	r.mu.Lock()
	closed, client, detached := r.closed, r.providers[key], r.detached
	r.mu.Unlock()
	if closed {
		return nil, errClosing
	}
	if client != nil && !client.Closed() {
		return client, nil
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
	started, err := buildprovider.Start(ctx, runner, pluginbackend.StartRequest{
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
	r.mu.Lock()
	current := !r.closed && r.detached == detached
	client = r.providers[key]
	if current && (client == nil || client.Closed()) {
		if r.providers == nil {
			r.providers = make(map[string]*buildprovider.Client)
		}
		r.providers[key] = started
		r.mu.Unlock()
		return started, nil
	}
	r.mu.Unlock()
	_ = started.Close(ctx)
	if !current {
		return nil, errClosing
	}
	return client, nil
}

// detach takes every session the runtime holds, its own providers before the clients attached to
// language servers, and leaves it empty. With closing set the runtime refuses new sessions, as for
// a project that closes; without it the next detection starts fresh ones, as after the build
// plugins changed.
func (r *buildRuntime) detach(closing bool) []*buildprovider.Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	clients := make([]*buildprovider.Client, 0, len(r.providers)+len(r.shared))
	for _, provider := range r.providers {
		clients = append(clients, provider)
	}
	for _, provider := range r.shared {
		clients = append(clients, provider)
	}
	r.providers, r.shared = nil, nil
	r.detached++
	if closing {
		r.closed = true
	}
	return clients
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
	client, err := p.buildSessions.provider(ctx, a.plugins.Backend, a.plugins.Root, p.root, rootURI, instance, settings.State)
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
	p.buildSessions.mu.Lock()
	detached := p.buildSessions.detached
	if client := p.buildSessions.shared[key]; client != nil && !client.Closed() {
		p.buildSessions.mu.Unlock()
		return client, nil
	}
	p.buildSessions.mu.Unlock()

	a.pluginServerMu.Lock()
	if server := a.pluginServers[instance.PluginID]; server != nil && server.project == p {
		a.pluginServerMu.Unlock()
		return a.attachSharedBuildClient(ctx, p, instance, key, server, detached)
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
		return a.attachSharedBuildClient(ctx, p, instance, key, existing, detached)
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
	return a.attachSharedBuildClient(ctx, p, instance, key, server, detached)
}

// attachSharedBuildClient waits for the session's real ready event before it
// returns. A language server that is already ready is recorded by pluginServer,
// so Attach can mark this client ready without inventing a ready state. detached
// is the runtime's detach count when the caller began: a client attached after
// another detach belongs to the sessions it took and is dropped.
func (a *App) attachSharedBuildClient(ctx context.Context, p *project, instance buildInstance, key string, server *pluginServer, detached uint64) (*buildprovider.Client, error) {
	client := server.attachBuild(a.plugins.Backend, server.session.Session)
	if err := client.WaitReady(ctx); err != nil {
		server.detachBuild(client)
		_ = client.Close(context.Background())
		return nil, err
	}
	p.buildSessions.mu.Lock()
	if p.buildSessions.closed || p.buildSessions.detached != detached || ctx.Err() != nil || p.ctx.Err() != nil {
		p.buildSessions.mu.Unlock()
		server.detachBuild(client)
		_ = client.Close(context.Background())
		return nil, buildprovider.ErrClosed
	}
	if p.buildSessions.shared == nil {
		p.buildSessions.shared = make(map[string]*buildprovider.Client)
	}
	p.buildSessions.shared[key] = client
	p.buildSessions.mu.Unlock()
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
	// The team and local option documents are read here, on the window thread, and resolved and detected
	// with the instances below; a document that cannot be read fails the detection instead of emptying it.
	docs, docsErr := a.readBuildOptionDocuments(context.Background(), p.root)
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishBuildDetection(p, generation, nil, err) }
		}
		if docsErr != nil {
			return func(a *App) { a.finishBuildDetection(p, generation, nil, docsErr) }
		}
		plugins, pluginErr := a.plugins.BuildPlugins(ctx, entries)
		manifests := make([]json.RawMessage, 0, len(plugins))
		byPlugin := make(map[string]pluginservice.BuildPlugin, len(plugins))
		for _, plugin := range plugins {
			manifests = append(manifests, plugin.Manifest)
			byPlugin[plugin.PluginID] = plugin
		}
		detection, detectErr := detectBuildSystemsWithStoredOptions(ctx, kernel, p.root, manifests, docs)
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
	if p.build.reloadPending {
		p.build.reloadPending = false
		defer a.loadBuildSystems(p)
	}
	p.build.loaded = true
	p.build.instances = instances
	p.revokeAllBuildTests()
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
	a.loadBuildModelWith(p, index, false)
}

// loadBuildModelWith loads the model of one instance. refresh tells a provider the load is a
// reload the user or the files asked for, so it re-reads what it caches.
func (a *App) loadBuildModelWith(p *project, index int, refresh bool) {
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
		model, err := a.providerModel(ctx, p, captured, kernel, refresh)
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
	p.reloadBuildDependencies()
	p.revokeBuildTests(instance.ID)
	a.loadBuildModelWith(p, index, true)
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

func (a *App) providerModel(ctx context.Context, p *project, instance buildInstance, kernel Kernel, refresh bool) (core.BuildModel, error) {
	// The host resolves the build tool the provider runs with, so the provider never searches
	// for it; an explicit tool setting that does not exist fails here, as it does for commands.
	var tool *core.BuildTool
	execution, err := a.resolveBuildExecutable(ctx, p, instance, a.text.Build)
	if err != nil {
		return core.BuildModel{}, err
	}
	if execution.Executable != "" {
		tool = &core.BuildTool{Executable: execution.Executable, Environment: execution.Environment}
	}
	plan, err := kernel.PlanBuildModel(ctx, instance.Manifest, instance.BuildSystemID, core.BuildPlanRequest{
		Root:                    instance.Root,
		Options:                 instance.Options,
		WorkspaceRoot:           p.root,
		WorkspaceStateDirectory: "",
		Refresh:                 refresh,
		Tool:                    tool,
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
		// The runs the model offers become run configurations.
		a.refreshRunConfigurations(p)
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
	_, _ = a.runBuildTask(p, p.build.projectID, p.build.targetID, p.build.taskID, nil)
}

// runBuildTask runs one declared or model task of the selected instance. The Build window
// passes its stored selection and no user arguments; the IDE API passes the identities a
// client chose. It returns the execution it reserved; validation refusals are returned instead
// so a tool call can report them, and the Build window keeps its notification and ignores them.
func (a *App) runBuildTask(p *project, projectID, targetID, taskID string, userArguments []string) (*buildOperation, error) {
	instance := p.selectedBuildInstance()
	if instance == nil || taskID == "" {
		a.notify(a.text.Build.ChooseTask)
		return nil, refuseBuild(refusalInvalid, "choose a build task")
	}
	if p.build.operation != nil {
		return nil, errBuildBusy
	}
	task, modelTask := buildTaskByID(instance, taskID)
	if task == nil && modelTask == nil {
		return nil, refuseBuild(refusalNotFound, "unknown build task")
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
			a.notifyError(a.text.Build.ProjectMissing)
			return nil, refuseBuild(refusalNotFound, "unknown build project")
		}
		request.Project = &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties}
	}
	if targetID != "" {
		target, ok := buildTargetByID(instance.Model, targetID)
		if !ok {
			a.notifyError(a.text.Build.TargetMissing)
			return nil, refuseBuild(refusalNotFound, "unknown build target")
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
			return nil, refuseBuild(refusalInvalid, "this task requires user arguments")
		}
	}
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "build.runTask", "surface": "build"})
	captured := *instance
	kernel := a.kernel
	messages := a.text.Build
	op := a.beginBuildOperation(p, "build", ideAPIBuildLabel(instance, taskID), "")
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		prepare, release := op.bind(ctx)
		defer release()
		plan, err := kernel.PlanBuildTask(prepare, captured.Manifest, captured.BuildSystemID, request)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		if plan.Provider == nil {
			if err := a.runCommandTask(ctx, prepare, p, op, captured, plan, messages); err != nil {
				return func(a *App) { a.finishBuildError(p, op, err) }
			}
			return nil
		}
		client, err := a.buildProvider(prepare, p, captured)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.runProviderOperation(ctx, prepare, p, op, client, plan)
		return nil
	})
	return op, nil
}

// runCommandTask expands a command plan through Core, resolves the build tool
// in Core's candidate order, and runs it as a host-owned process. prepare is ctx ending also
// when the operation is stopped; the process runs under ctx and ends through Stop.
func (a *App) runCommandTask(ctx, prepare context.Context, p *project, op *buildOperation, instance buildInstance, plan core.BuildPlan, messages i18n.BuildMessages) error {
	execution, err := a.resolveBuildExecutable(prepare, p, instance, messages)
	if err != nil {
		return err
	}
	workingDirectory := filepath.Join(p.root, filepath.FromSlash(plan.WorkingDirectory))
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Kind:             processledger.KindBuild,
		Executable:       execution.Executable,
		Arguments:        plan.Arguments,
		WorkingDirectory: workingDirectory,
		Environment:      applyToolchainSelection(plan.Environment, execution.selection()),
	}, func(_ buildprocess.Stream, text string) {
		a.post(func(a *App) { a.appendBuildOutput(p, op, text) })
	})
	if err != nil {
		return err
	}
	a.post(func(a *App) { a.attachProcess(p, op, process) })
	err = process.Wait()
	a.post(func(a *App) { a.finishBuildRun(p, op, err) })
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
		Kind:             processledger.KindBuild,
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

// runBuildTarget prepares and starts one provider application target of the selected instance.
func (a *App) runBuildTarget(p *project, targetID, runID string) {
	instance := p.selectedBuildInstance()
	if instance == nil || p.build.operation != nil {
		return
	}
	target, ok := buildTargetByID(instance.Model, targetID)
	if !ok {
		a.notifyError(a.text.Build.TargetMissing)
		return
	}
	op := a.beginBuildOperation(p, "run", target.Name, "")
	a.runBuildTargetWith(p, op, instance, p.build.projectID, targetID, runID, nil)
}

// debugBuildTarget prepares one provider application target for debugging and starts the
// plugin's own debug adapter on the program the provider prepared. The adapter comes from the
// same plugin as the build system: the first one that serves launch.
func (a *App) debugBuildTarget(p *project, targetID, runID string) {
	instance := p.selectedBuildInstance()
	if instance == nil || p.build.operation != nil {
		return
	}
	project, ok := buildProjectByID(instance.Model, p.build.projectID)
	if !ok {
		a.notifyError(a.text.Build.ProjectMissing)
		return
	}
	target, ok := buildTargetByID(instance.Model, targetID)
	if !ok {
		a.notifyError(a.text.Build.TargetMissing)
		return
	}
	captured := *instance
	kernel := a.kernel
	messages := a.text.Build
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "build.debugTarget", "surface": "build"})
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		plan, err := kernel.PlanBuildDebug(ctx, captured.Manifest, captured.BuildSystemID, core.BuildPlanRequest{
			Root:          captured.Root,
			Options:       captured.Options,
			WorkspaceRoot: p.root,
			Run:           runID,
			Project:       &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties},
			Target:        &core.BuildSelection{Name: target.Name, Path: target.Path, Tags: target.Tags, Properties: target.Properties},
		})
		if err != nil {
			return func(a *App) { a.notifyError(err.Error()) }
		}
		if plan.Provider == nil {
			return func(a *App) { a.notifyError(messages.CommandUnsupported) }
		}
		client, err := a.buildProvider(ctx, p, captured)
		if err != nil {
			return func(a *App) { a.notifyError(err.Error()) }
		}
		operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
		if err != nil {
			return func(a *App) { a.notifyError(err.Error()) }
		}
		result, err := operation.Wait(ctx)
		if err != nil {
			return func(a *App) { a.notifyError(err.Error()) }
		}
		launch, err := kernel.DecodeBuildDebug(ctx, captured.Manifest, captured.BuildSystemID, core.BuildDecodeDebugRequest{
			WorkspaceRoot: p.root,
			Root:          captured.Root,
			Result:        result,
		})
		if err != nil {
			return func(a *App) { a.notifyError(err.Error()) }
		}
		return func(a *App) { a.startProviderDebug(p, captured.PluginID, launch) }
	})
}

// startProviderDebug starts the prepared program under the first adapter its own plugin
// declares for launch, and reports it when the plugin declares none.
func (a *App) startProviderDebug(p *project, pluginID string, launch core.BuildLaunch) {
	if launch.Executable.Value == "" {
		return
	}
	for _, adapter := range p.debug.adapters {
		if adapter.PluginID != pluginID || !adapter.Declaration.Serves("launch") {
			continue
		}
		executable := launch.Executable.Value
		if launch.Executable.Kind == "command" {
			if resolved, err := exec.LookPath(executable); err == nil {
				executable = resolved
			}
		}
		arguments := launch.Arguments
		if arguments == nil {
			arguments = []string{}
		}
		environment := launch.Environment
		if environment == nil {
			environment = map[string]string{}
		}
		a.beginDebug(p, debugStart{
			adapter: adapter, request: "launch", ended: make(chan *int, 1),
			launchTarget: &core.DebugTargetFacts{
				Kind: "executable", Path: executable, Executable: executable,
				WorkingDirectory: filepath.Join(p.root, filepath.FromSlash(launch.WorkingDirectory)),
				Arguments:        arguments, Environment: environment,
			},
		})
		return
	}
	a.notifyError(i18n.Shared(a.language(), "desktop.build.noDebugAdapter"))
}

// runBuildTargetWith runs one target of instance through the provider's run declaration runID
// as the reserved operation op. options are the run configuration's launch choices, nil for a
// launch without any. A project or target the model no longer has ends op as failed.
func (a *App) runBuildTargetWith(p *project, op *buildOperation, instance *buildInstance, projectID, targetID, runID string, options *core.RunLaunchOptions) {
	project, ok := buildProjectByID(instance.Model, projectID)
	if !ok {
		a.notifyError(a.text.Build.ProjectMissing)
		a.finishBuildError(p, op, errors.New(a.text.Build.ProjectMissing))
		return
	}
	target, ok := buildTargetByID(instance.Model, targetID)
	if !ok {
		a.notifyError(a.text.Build.TargetMissing)
		a.finishBuildError(p, op, errors.New(a.text.Build.TargetMissing))
		return
	}
	captured := *instance
	kernel := a.kernel
	messages := a.text.Build
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "build.runTarget", "surface": "build"})
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		prepare, release := op.bind(ctx)
		defer release()
		plan, err := kernel.PlanBuildRun(prepare, captured.Manifest, captured.BuildSystemID, core.BuildPlanRequest{
			Root:          captured.Root,
			Options:       captured.Options,
			WorkspaceRoot: p.root,
			Run:           runID,
			Project:       &core.BuildSelection{Name: project.Name, Path: project.Path, Properties: project.Properties},
			Target:        &core.BuildSelection{Name: target.Name, Path: target.Path, Tags: target.Tags, Properties: target.Properties},
			LaunchOptions: options,
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		if plan.Provider == nil {
			return func(a *App) { a.finishBuildError(p, op, errors.New(messages.CommandUnsupported)) }
		}
		client, err := a.buildProvider(prepare, p, captured)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		operation, err := client.Execute(prepare, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.post(func(a *App) { a.attachRequest(p, op, client, operation, false) })
		result, err := operation.Wait(prepare)
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		launch, err := kernel.DecodeBuildRun(prepare, captured.Manifest, captured.BuildSystemID, core.BuildDecodeRunRequest{
			WorkspaceRoot: p.root,
			Root:          captured.Root,
			Result:        result,
			LaunchOptions: options,
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		execution := buildExecution{}
		switch launch.Executable.Kind {
		case "command":
			executable, lookupErr := exec.LookPath(launch.Executable.Value)
			if lookupErr != nil {
				return func(a *App) { a.finishBuildError(p, op, lookupErr) }
			}
			execution.Executable = executable
		case "toolchain":
			selection, selectErr := a.resolveToolchainSelection(prepare, p.root, captured.Root, launch.Executable.Value, "")
			if selectErr != nil {
				return func(a *App) { a.finishBuildError(p, op, selectErr) }
			}
			execution.Executable = selection.Executable
			execution.Environment = selection.Environment
			execution.PathPrepend = selection.PathPrepend
		default:
			return func(a *App) {
				a.finishBuildError(p, op, errors.New(messages.ToolchainGap(launch.Executable.Value)))
			}
		}
		if prepare.Err() != nil {
			return func(a *App) { a.finishBuildError(p, op, prepare.Err()) }
		}
		workingDirectory := filepath.Join(p.root, filepath.FromSlash(launch.WorkingDirectory))
		process, err := buildprocess.Start(ctx, buildprocess.Spec{
			Kind:             processledger.KindBuild,
			Executable:       execution.Executable,
			Arguments:        launch.Arguments,
			WorkingDirectory: workingDirectory,
			Environment:      applyToolchainSelection(launch.Environment, execution.selection()),
		}, func(_ buildprocess.Stream, text string) {
			a.post(func(a *App) { a.appendBuildOutput(p, op, text) })
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.post(func(a *App) { a.attachProcess(p, op, process) })
		err = process.Wait()
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// attachRequest makes the accepted provider request the operation's request, so Stop cancels
// it. execution says the request is the execution itself, a task, rather than the plan of a
// run's process. A request accepted after the operation was stopped or replaced is cancelled.
func (a *App) attachRequest(p *project, op *buildOperation, client *buildprovider.Client, request *buildprovider.Operation, execution bool) {
	if op.cancelled || p.build.operation != op {
		a.background(p, buildStopTimeout, func(ctx context.Context) func(*App) {
			_ = client.Cancel(ctx, request)
			return nil
		})
		return
	}
	op.provider, op.request = client, request
	if execution {
		op.ide.start()
		p.build.status = a.text.Build.Running
	}
}

// runProviderOperation sends one provider task and forwards progress and its final output into
// the bounded window output. prepare ends also when the operation is stopped and bounds only the
// request's start; once the provider accepted it, a stop cancels it and the terminal answer
// still ends the operation, so a replacement cannot start before the provider answered.
func (a *App) runProviderOperation(ctx, prepare context.Context, p *project, op *buildOperation, client *buildprovider.Client, plan core.BuildPlan) {
	operation, err := client.Execute(prepare, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
	if err != nil {
		a.post(func(a *App) { a.finishBuildError(p, op, err) })
		return
	}
	a.post(func(a *App) { a.attachRequest(p, op, client, operation, true) })
	sawProgress := false
	for {
		select {
		case progress, ok := <-operation.Progress():
			if !ok {
				goto done
			}
			if progress.Output != "" {
				sawProgress = true
				a.post(func(a *App) { a.appendBuildOutput(p, op, progress.Output) })
			}
			if progress.Message != "" {
				a.post(func(a *App) {
					if p.build.operation == op && !op.cancelled {
						p.build.status = progress.Message
					}
				})
			}
		case <-ctx.Done():
			a.post(func(a *App) { a.finishBuildError(p, op, ctx.Err()) })
			return
		}
	}
done:
	result, err := operation.Wait(ctx)
	if err != nil {
		a.post(func(a *App) { a.finishBuildError(p, op, err) })
		return
	}
	if !sawProgress {
		var execution struct {
			Output string `json:"output"`
		}
		if json.Unmarshal(result, &execution) == nil && execution.Output != "" {
			a.post(func(a *App) { a.appendBuildOutput(p, op, execution.Output) })
		}
	}
	a.post(func(a *App) { a.finishBuildTask(p, op, result) })
}

// endBuildOperation clears op as the window's operation and settles its IDE state. It reports
// false when op is no longer the window's operation: a closed project or a plugin change already
// detached and settled it, and its late terminal event changes nothing.
func (a *App) endBuildOperation(p *project, op *buildOperation, state string, exitCode *int, failure string) bool {
	if a.project != p || p.build.operation != op {
		return false
	}
	p.build.operation = nil
	op.ide.settle(state, exitCode, p.build.outputSequence, failure)
	return true
}

// finishBuildTask ends a provider task with its result. A stopped task is cancelled whatever
// the provider answered; a result without an exit code completes with a null one.
func (a *App) finishBuildTask(p *project, op *buildOperation, result json.RawMessage) {
	var execution struct {
		ExitCode *int `json:"exitCode"`
	}
	_ = json.Unmarshal(result, &execution)
	code := execution.ExitCode
	switch {
	case op.cancelled:
		if a.endBuildOperation(p, op, "cancelled", code, "") {
			p.build.status = a.text.Build.Cancelled
		}
	case code != nil && *code != 0:
		if a.endBuildOperation(p, op, "failed", code, "") {
			p.build.status = a.text.Build.Exited(*code)
		}
	default:
		if a.endBuildOperation(p, op, "completed", code, "") {
			p.build.status = a.text.Build.Succeeded
		}
	}
}

// finishBuildRun ends a host process with how it exited: a non-zero exit fails with its code,
// and a process that could not be waited for or ended on a signal fails without one.
func (a *App) finishBuildRun(p *project, op *buildOperation, err error) {
	var exit *exec.ExitError
	switch {
	case op.cancelled:
		if a.endBuildOperation(p, op, "cancelled", nil, "") {
			p.build.status = a.text.Build.Cancelled
		}
	case errors.As(err, &exit) && exit.ExitCode() > 0:
		code := exit.ExitCode()
		if a.endBuildOperation(p, op, "failed", &code, "") {
			p.build.status = a.text.Build.Exited(code)
		}
	case err != nil:
		if a.endBuildOperation(p, op, "failed", nil, "") {
			p.build.status = a.text.Build.ProcessFailed(err.Error())
		}
	default:
		code := 0
		if a.endBuildOperation(p, op, "completed", &code, "") {
			p.build.status = a.text.Build.Succeeded
		}
	}
}

// finishBuildError ends op with err. A stopped operation is cancelled; an execution that failed
// before it launched keeps err as the reason its start failed.
func (a *App) finishBuildError(p *project, op *buildOperation, err error) {
	if err == nil {
		return
	}
	if op.cancelled || errors.Is(err, context.Canceled) {
		if a.endBuildOperation(p, op, "cancelled", nil, "") {
			p.build.status = a.text.Build.Cancelled
		}
		return
	}
	failure := ""
	if op.ide != nil && op.ide.State == "preparing" {
		failure = err.Error()
	}
	if a.endBuildOperation(p, op, "failed", nil, failure) {
		p.build.status = err.Error()
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("build", err))
	}
}

// stopBuildOperation stops the current execution: its preparation ends, its process is asked
// to stop and the provider is asked to cancel its request. Stopping an execution that is already
// stopping kills its process at once instead of waiting out the stop time. The terminal event
// still clears the operation, so a replacement cannot start until the execution really ended.
func (a *App) stopBuildOperation(p *project) {
	if p == nil || p.build.operation == nil {
		return
	}
	operation := p.build.operation
	if operation.cancelled {
		operation.stop()
		return
	}
	operation.stop()
	operation.ide.stopping()
	p.build.status = a.text.Build.Stopping
	if operation.provider != nil && operation.request != nil {
		client, request := operation.provider, operation.request
		a.background(p, buildStopTimeout, func(ctx context.Context) func(*App) {
			_ = client.Cancel(ctx, request)
			return nil
		})
	}
}

// stopBuild cancels the current operation and stops every provider this project started, for a
// project that closes.
func (a *App) stopBuild(p *project) {
	a.stopBuildSessions(p, true)
}

// stopBuildSessions cancels the current operation and stops the sessions the project holds on a
// background task with a bounded wait. The sessions are detached from the project first, so the
// task closes exactly them whatever the project starts next; with closing set the project starts no
// session again.
func (a *App) stopBuildSessions(p *project, closing bool) {
	if p == nil {
		return
	}
	operation := p.build.operation
	p.build.operation = nil
	if operation != nil {
		// Its terminal event finds the operation detached, so it settles here.
		operation.stop()
		operation.ide.settle("cancelled", nil, p.build.outputSequence, "")
	}
	clients := p.buildSessions.detach(closing)
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		ctx, cancel := context.WithTimeout(context.Background(), buildStopTimeout)
		defer cancel()
		if operation != nil && operation.request != nil && operation.provider != nil {
			_ = operation.provider.Cancel(ctx, operation.request)
		}
		for _, client := range clients {
			_ = client.Close(ctx)
		}
	}()
}

// invalidateBuild drops a project's detected models and provider sessions after
// an install, enablement or uninstall changed the build plugins.
func (a *App) invalidateBuild(p *project) {
	if p == nil {
		return
	}
	a.stopTestsForProject(p)
	a.stopBuildSessions(p, false)
	// The output is gone, but its sequence keeps counting: an IDE operation's cursor then
	// reports the discontinuity instead of reading lines written after it.
	sequence := p.build.outputSequence
	p.build = buildState{outputStart: sequence, outputSequence: sequence}
}

// appendBuildOutput adds text op wrote to the bounded output, splitting it into lines. Output
// of an operation the window no longer runs is dropped, so it never lands in the next
// execution's output.
func (a *App) appendBuildOutput(p *project, op *buildOperation, text string) {
	if p == nil || a.project != p || p.build.operation != op || text == "" {
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
			// Cut at a character boundary, so the kept text stays valid UTF-8 for the IDE output pages.
			cut := buildOutputLineSize
			for cut > 0 && !utf8.RuneStart(line[cut]) {
				cut--
			}
			line = line[:cut] + "\n"
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
