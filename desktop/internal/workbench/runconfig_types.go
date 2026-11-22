package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/vivaui/viva/gfx"
)

// This file reads the run configuration kinds a user can create: the built-in ones, and the
// ones enabled plugins declare for their build systems (buildSystems[].runConfigurationTypes).
// Core reads every manifest, lists the kinds they declare and says which translation files of
// each declaring package to read for the interface language; the host only reads those files
// from the installed package, which stays read-only, and asks again with them. The plugins that
// declare a kind, with the files read, are kept as the `runTypePlugins` the editor, the save
// and the run of those kinds send, so they show the same translated text.

// runConfigKinds is one read of the kinds: the kinds in display order, the plugins that
// declare one, nil when none does, and their package directories by plugin ID, where the
// icons they name are read. Once published, none is changed; a later read replaces them.
type runConfigKinds struct {
	types       []core.RunConfigurationType
	plugins     *core.RunTypePlugins
	directories map[string]string
}

// readRunConfigKinds asks Core for the kinds off the window thread, in language. A plugin
// whose manifest cannot be read adds no kind and is logged; a translation that cannot be read
// or that Core refuses falls back to the next candidate or the manifest's text, so the kinds
// still list.
func (a *App) readRunConfigKinds(ctx context.Context, kernel Kernel, language string) (runConfigKinds, error) {
	enabled := a.runTypeCandidates(ctx)
	if len(enabled) == 0 {
		types, _, err := kernel.RunConfigurationTypes(ctx, nil)
		return runConfigKinds{types: types}, err
	}
	request := &core.RunTypePlugins{Language: language, Plugins: make([]core.RunTypePlugin, 0, len(enabled))}
	for _, plugin := range enabled {
		request.Plugins = append(request.Plugins, core.RunTypePlugin{Manifest: plugin.Manifest})
	}
	types, reports, err := kernel.RunConfigurationTypes(ctx, request)
	if err != nil {
		return runConfigKinds{}, err
	}
	// Only the plugins that declare a kind or a before-launch task go on. Core lists each
	// declared kind under its plugin and reports the translations of every plugin that
	// declares either, so the host never interprets a manifest itself.
	declaring := []pluginservice.ToolchainPlugin{}
	for _, plugin := range enabled {
		if slices.ContainsFunc(types, func(kind core.RunConfigurationType) bool {
			return kind.RunType != nil && kind.RunType.PluginID == plugin.PluginID
		}) || slices.ContainsFunc(reports, func(report core.RunTypeLocalization) bool {
			return report.PluginID == plugin.PluginID
		}) {
			declaring = append(declaring, plugin)
		}
	}
	if len(declaring) == 0 {
		return runConfigKinds{types: types}, nil
	}
	plugins := &core.RunTypePlugins{Language: language, Plugins: make([]core.RunTypePlugin, len(declaring))}
	directories := make(map[string]string, len(declaring))
	read := false
	for index, plugin := range declaring {
		plugins.Plugins[index].Manifest = plugin.Manifest
		directories[plugin.PluginID] = plugin.Directory
		report := slices.IndexFunc(reports, func(report core.RunTypeLocalization) bool { return report.PluginID == plugin.PluginID })
		if report < 0 || !reports[report].ReadRequired {
			continue
		}
		files, unreadable, err := pluginsettings.ReadTranslations(ctx, plugin.Directory, reports[report].PluginSettingsLocalization)
		if err != nil {
			return runConfigKinds{}, err
		}
		if len(unreadable) > 0 {
			a.operationRejectedIn(ctx, "run_config_types", "localization_unreadable")
		}
		// A read that found no file is an empty map, so Core does not ask for it again.
		plugins.Plugins[index].Localizations = files
		read = true
	}
	if read {
		types, reports, err = kernel.RunConfigurationTypes(ctx, plugins)
		if err != nil {
			return runConfigKinds{}, err
		}
		if slices.ContainsFunc(reports, func(report core.RunTypeLocalization) bool { return len(report.Rejected) > 0 }) {
			a.operationRejectedIn(ctx, "run_config_types", "invalid_localization")
		}
	}
	for _, kind := range types {
		if kind.RunType != nil {
			a.readRunTypeIcon(ctx, directories, kind.RunType.PluginID, kind.Icon)
		}
	}
	return runConfigKinds{types: types, plugins: plugins, directories: directories}, nil
}

// runTypeCandidates is every enabled plugin with its manifest and package directory, nil while
// the plugin host is not assembled. A manifest that cannot be read leaves that plugin out.
func (a *App) runTypeCandidates(ctx context.Context) []pluginservice.ToolchainPlugin {
	if a.plugins == nil {
		return nil
	}
	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		a.backgroundFailedIn(ctx, "run_config_types", err)
		return nil
	}
	plugins, err := a.plugins.ToolchainPlugins(ctx, entries)
	if err != nil {
		a.backgroundFailedIn(ctx, "run_config_types", err)
	}
	return plugins
}

// runTypePlugins is the `runTypePlugins` a request about declared kinds or before-launch tasks
// sends: the plugins the last read of the kinds kept, nil when none declares one, else, before
// any read answered, a read of its own. It runs off the window thread; kinds is what the window
// held when the request was made.
func (a *App) runTypePlugins(ctx context.Context, kernel Kernel, kinds runConfigKinds, language string) *core.RunTypePlugins {
	return a.runTypeRead(ctx, kernel, kinds, language).plugins
}

// runTypeRead is kinds when a read answered, else a read of its own, empty when it fails. It
// runs off the window thread.
func (a *App) runTypeRead(ctx context.Context, kernel Kernel, kinds runConfigKinds, language string) runConfigKinds {
	// A read lists the built-in kinds at least, so its types are never nil.
	if kinds.types != nil {
		return kinds
	}
	read, err := a.readRunConfigKinds(ctx, kernel, language)
	if err != nil {
		a.backgroundFailedIn(ctx, "run_config_types", err)
		return runConfigKinds{}
	}
	return read
}

// readRunTaskIcons reads the package icons of the task kinds an answer about before-launch
// steps lists, off the window thread, from the packages of the read of the kinds the request
// sent.
func (a *App) readRunTaskIcons(ctx context.Context, kinds runConfigKinds, tasks []core.RunTaskKind) {
	for _, task := range tasks {
		a.readRunTypeIcon(ctx, kinds.directories, task.RunType.PluginID, task.Icon)
	}
}

// readRunTypeIcon reads the package icon a kind or task kind of pluginID names, off the window
// thread, so drawing only looks it up. A broken icon is logged once, with its package-relative
// path, and leaves the kind its fallback icon.
func (a *App) readRunTypeIcon(ctx context.Context, directories map[string]string, pluginID string, icon *core.RunTypeIcon) {
	directory, ok := directories[pluginID]
	if icon == nil || icon.Path == "" || !ok {
		return
	}
	if err := a.pluginIcons.Read(pluginID, directory, runTypeIconDeclaration(icon)); err != nil {
		a.backgroundFailedIn(ctx, "plugin_icon", fmt.Errorf("%s: %w", pluginID, err))
	}
}

// runTypePackageIcon is the package icon a kind or task kind of pluginID names, once read.
func runTypePackageIcon(cache *pluginicons.Cache, pluginID string, icon *core.RunTypeIcon, dark bool) (gfx.Icon, bool) {
	if icon == nil || icon.Path == "" {
		return gfx.Icon{}, false
	}
	found, ok := cache.Lookup(pluginID, runTypeIconDeclaration(icon))
	return found.For(dark), ok
}

func runTypeIconDeclaration(icon *core.RunTypeIcon) pluginicons.Declaration {
	return pluginicons.Declaration{Path: icon.Path, DarkPath: icon.DarkPath, Mode: icon.Mode}
}

// runTypeKind is the declared kind key names among the kinds read, or nil.
func (s *runConfigState) runTypeKind(key core.RunTypeKey) *core.RunConfigurationType {
	index := slices.IndexFunc(s.types, func(kind core.RunConfigurationType) bool {
		return kind.RunType != nil && *kind.RunType == key
	})
	if index < 0 {
		return nil
	}
	return &s.types[index]
}

// kinds is the kinds read last, for a request made off the window thread.
func (s *runConfigState) kinds() runConfigKinds {
	return runConfigKinds{types: s.types, plugins: s.typePlugins, directories: s.typeDirectories}
}

// runTypeInstances are the detected instances of the build system that declares kind key, in
// detection order, copied for a request off the window thread.
func (p *project) runTypeInstances(key core.RunTypeKey) []buildInstance {
	var instances []buildInstance
	for _, instance := range p.build.instances {
		if instance.PluginID == key.PluginID && instance.BuildSystemID == key.BuildSystemID {
			instances = append(instances, instance)
		}
	}
	return instances
}

// hasRunTypeInstance says the build system that declares kind key is detected, so its
// configurations can start; they need no loaded model.
func (p *project) hasRunTypeInstance(key core.RunTypeKey) bool {
	return slices.ContainsFunc(p.build.instances, func(instance buildInstance) bool {
		return instance.PluginID == key.PluginID && instance.BuildSystemID == key.BuildSystemID
	})
}

// launchDeclaredRun plans the run of configuration id, of the kind key a plugin declares, and
// starts and waits for its process off the window thread, as launchProcessRun does for a
// built-in run. Core picks the instance whose root holds the configuration's working
// directory; the host starts the build tool that instance resolves, as a build task does.
func (a *App) launchDeclaredRun(p *project, op *buildOperation, id string, key core.RunTypeKey) {
	instances := p.runTypeInstances(key)
	if len(instances) == 0 || a.plugins == nil {
		a.notifyError(a.text.Build.TargetMissing)
		a.finishBuildError(p, op, errors.New(a.text.Build.TargetMissing))
		return
	}
	root, kernel, messages, pluginRoot := p.root, a.kernel, a.text.Build, a.plugins.Root
	var host *remoteRunHost
	if p.remote != nil {
		remote := a.remoteRunHostFor(p, op)
		host = &remote
	}
	a.background(p, 0, func(ctx context.Context) func(*App) {
		ctx = attachedWorkspaceContext(ctx, op.connection)
		bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
		defer cancel()
		prepare, release := op.bind(bounded)
		defer release()
		planned, err := a.planDeclaredProcess(prepare, p, root, pluginRoot, instances, messages, func(manifest json.RawMessage, sources declaredPlanSources) (core.BuildPlan, error) {
			return kernel.PlanRunConfiguration(prepare, manifest, key.BuildSystemID, root, core.RunConfigurationPlanRequest{
				ConfigurationID: id, Instances: sources.instances,
				PluginDirectory: sources.pluginDirectory, WorkspaceStateDirectory: sources.stateDirectory,
				ProjectCodeAllowed: p.trust.allowed(),
			})
		})
		if err == nil {
			err = prepare.Err()
		}
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		if host != nil {
			host.logFailures(a, ctx)
			start, err := host.command(planned)
			if err != nil {
				return func(a *App) { a.finishBuildError(p, op, err) }
			}
			err = host.run(ctx, start, func(process *remoteProcess) {
				a.post(func(a *App) { a.attachProcess(p, op, process) })
			})
			return func(a *App) { a.finishBuildRun(p, op, err) }
		}
		process, err := planned.startLocal(ctx, root, func(text string) { a.streamBuildOutput(p, op, text) })
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.post(func(a *App) { a.attachProcess(p, op, process) })
		err = process.Wait()
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// declaredPlanSources are the build instances and directories Core needs for a declared run.
type declaredPlanSources struct {
	instances                       []core.RunTypeInstance
	pluginDirectory, stateDirectory string
}

type declaredProcess struct {
	plan      core.BuildPlan
	execution buildExecution
}

// planDeclaredProcess selects a build instance and resolves its executable on the host
// captured by ctx. Declared commands expose no package or state directory variables.
func (a *App) planDeclaredProcess(ctx context.Context, p *project, root, pluginRoot string, instances []buildInstance, messages i18n.BuildMessages, request func(json.RawMessage, declaredPlanSources) (core.BuildPlan, error)) (declaredProcess, error) {
	first := instances[0]
	sources := declaredPlanSources{instances: make([]core.RunTypeInstance, 0, len(instances))}
	if p.remote == nil {
		sources.pluginDirectory = first.PackageDirectory
		sources.stateDirectory = buildStateDirectory(pluginRoot, root, first)
		if err := os.MkdirAll(sources.stateDirectory, 0o700); err != nil {
			return declaredProcess{}, err
		}
	}
	for _, instance := range instances {
		sources.instances = append(sources.instances, core.RunTypeInstance{Root: instance.Root, Options: instance.Options})
	}
	planned, err := request(first.Manifest, sources)
	if err != nil {
		return declaredProcess{}, err
	}
	if planned.Provider != nil {
		return declaredProcess{}, errors.New("the declared plan names a provider request")
	}
	index := slices.IndexFunc(instances, func(instance buildInstance) bool { return instance.Root == planned.Root })
	if index < 0 {
		return declaredProcess{}, fmt.Errorf("the declared plan names no detected instance: %s", planned.Root)
	}
	execution, err := a.resolveBuildExecutable(ctx, p, instances[index], messages)
	if err != nil {
		return declaredProcess{}, err
	}
	return declaredProcess{plan: planned, execution: execution}, nil
}

func (p declaredProcess) startLocal(ctx context.Context, root string, output func(string)) (*buildprocess.Process, error) {
	directory, err := projectRunDirectory(root, p.plan.WorkingDirectory)
	if err != nil {
		return nil, err
	}
	return buildprocess.Start(ctx, buildprocess.Spec{
		Kind: processledger.KindRun, Executable: p.execution.Executable, Arguments: p.plan.Arguments,
		WorkingDirectory: directory, Environment: applyToolchainSelection(p.plan.Environment, p.execution.selection()),
	}, func(_ buildprocess.Stream, text string) { output(text) })
}

// kindTitle names kind k: the host's title of a built-in kind, the translated title the plugin
// declares for one of its kinds. A kind no read lists, such as one of a plugin turned off,
// shows its ID; a built-in kind this host has no title for shows as a built-in run.
func (s *runConfigState) kindTitle(language i18n.Language, k runConfigKind) string {
	if !k.declared() {
		if title, ok := runConfigTypeLabel(language, k.provider); ok {
			return title
		}
		return i18n.Shared(language, "desktop.runConfig.builtInGroup")
	}
	if kind := s.runTypeKind(k.runType); kind != nil && kind.DisplayName != "" {
		return kind.DisplayName
	}
	return k.runType.Type
}

// kindIcon is the icon of kind k: a built-in kind's file icon, the package or host icon a
// declared kind names, else the icon of its execution. A package icon not read, or that this
// host cannot draw, falls back to the execution's icon.
func (s *runConfigState) kindIcon(k runConfigKind, cache *pluginicons.Cache, dark bool) gfx.Icon {
	if !k.declared() {
		return runConfigTypeIcon(k.provider, dark)
	}
	kind := s.runTypeKind(k.runType)
	if kind == nil {
		return icons.Play
	}
	if icon, ok := runTypePackageIcon(cache, k.runType.PluginID, kind.Icon, dark); ok {
		return icon
	}
	if kind.Icon != nil && kind.Icon.Host != "" {
		if icon := pluginToolIcon(kind.Icon.Host); icon != nil {
			return *icon
		}
	}
	return runExecutionIcon(kind.Execution)
}

// kindOrder places kind k's group in the dialog: where Core lists the kind, after every listed
// kind when no read lists it.
func (s *runConfigState) kindOrder(k runConfigKind) int {
	order := slices.IndexFunc(s.types, func(kind core.RunConfigurationType) bool { return runConfigKindOfType(kind) == k })
	if order < 0 {
		return len(s.types)
	}
	return order
}
