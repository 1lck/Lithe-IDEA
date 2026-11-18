package workbench

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
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

// runConfigKinds is one read of the kinds: the kinds in display order, and the plugins that
// declare one, nil when none does. Once published, neither is changed; a later read replaces
// them.
type runConfigKinds struct {
	types   []core.RunConfigurationType
	plugins *core.RunTypePlugins
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
	// Only the plugins that declare a kind go on; Core lists each declared kind under its
	// plugin, so the host never interprets a manifest itself.
	declaring := []pluginservice.ToolchainPlugin{}
	for _, plugin := range enabled {
		if slices.ContainsFunc(types, func(kind core.RunConfigurationType) bool {
			return kind.RunType != nil && kind.RunType.PluginID == plugin.PluginID
		}) {
			declaring = append(declaring, plugin)
		}
	}
	if len(declaring) == 0 {
		return runConfigKinds{types: types}, nil
	}
	plugins := &core.RunTypePlugins{Language: language, Plugins: make([]core.RunTypePlugin, len(declaring))}
	read := false
	for index, plugin := range declaring {
		plugins.Plugins[index].Manifest = plugin.Manifest
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
	return runConfigKinds{types: types, plugins: plugins}, nil
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

// runTypePlugins is the `runTypePlugins` a request about a declared kind sends: the plugins
// the last read of the kinds kept, else, before any read answered, a read of its own. It runs
// off the window thread; kinds is what the window held when the request was made.
func (a *App) runTypePlugins(ctx context.Context, kernel Kernel, kinds runConfigKinds, language string) *core.RunTypePlugins {
	if kinds.plugins != nil {
		return kinds.plugins
	}
	read, err := a.readRunConfigKinds(ctx, kernel, language)
	if err != nil {
		a.backgroundFailedIn(ctx, "run_config_types", err)
		return nil
	}
	return read.plugins
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
	return runConfigKinds{types: s.types, plugins: s.typePlugins}
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
	a.background(p, 0, func(ctx context.Context) func(*App) {
		bounded, cancel := context.WithTimeout(ctx, runPreparationTimeout)
		defer cancel()
		prepare, release := op.bind(bounded)
		defer release()
		spec, err := a.declaredRunSpec(prepare, p, kernel, root, pluginRoot, id, key, instances, messages)
		if err == nil {
			err = prepare.Err()
		}
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		process, err := buildprocess.Start(ctx, spec, func(_ buildprocess.Stream, text string) {
			a.streamBuildOutput(p, op, text)
		})
		if err != nil {
			return func(a *App) { a.finishBuildError(p, op, err) }
		}
		a.post(func(a *App) { a.attachProcess(p, op, process) })
		err = process.Wait()
		return func(a *App) { a.finishBuildRun(p, op, err) }
	})
}

// declaredRunSpec is the process a configuration of a declared kind starts: Core's plan
// (`build.runConfigurationPlan`) of the build system's command, run by the build tool the
// chosen instance resolves, at the configuration's working directory under the project. The
// plugin package is read-only, so the writable state directory the plan may name is the
// plugin's per-workspace state, outside it.
func (a *App) declaredRunSpec(ctx context.Context, p *project, kernel Kernel, root, pluginRoot, id string, key core.RunTypeKey, instances []buildInstance, messages i18n.BuildMessages) (buildprocess.Spec, error) {
	first := instances[0]
	state := buildStateDirectory(pluginRoot, root, first)
	if err := os.MkdirAll(state, 0o700); err != nil {
		return buildprocess.Spec{}, err
	}
	request := core.RunConfigurationPlanRequest{
		ConfigurationID: id, PluginDirectory: first.PackageDirectory, WorkspaceStateDirectory: state,
		Instances: make([]core.RunTypeInstance, 0, len(instances)),
	}
	for _, instance := range instances {
		request.Instances = append(request.Instances, core.RunTypeInstance{Root: instance.Root, Options: instance.Options})
	}
	plan, err := kernel.PlanRunConfiguration(ctx, first.Manifest, key.BuildSystemID, root, request)
	if err != nil {
		return buildprocess.Spec{}, err
	}
	if plan.Provider != nil {
		return buildprocess.Spec{}, errors.New("the run configuration plan names a provider request")
	}
	index := slices.IndexFunc(instances, func(instance buildInstance) bool { return instance.Root == plan.Root })
	if index < 0 {
		return buildprocess.Spec{}, fmt.Errorf("the run configuration plan names no detected instance: %s", plan.Root)
	}
	directory, err := projectRunDirectory(root, plan.WorkingDirectory)
	if err != nil {
		return buildprocess.Spec{}, err
	}
	execution, err := a.resolveBuildExecutable(ctx, p, instances[index], messages)
	if err != nil {
		return buildprocess.Spec{}, err
	}
	return buildprocess.Spec{
		Kind:             processledger.KindRun,
		Executable:       execution.Executable,
		Arguments:        plan.Arguments,
		WorkingDirectory: directory,
		Environment:      applyToolchainSelection(plan.Environment, execution.selection()),
	}, nil
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

// kindIcon is the icon of kind k: a built-in kind's file icon, the host icon a declared kind
// names, else the icon of its execution. A package image a kind names is not drawn yet, so
// such a kind shows its execution's icon too.
func (s *runConfigState) kindIcon(k runConfigKind, dark bool) gfx.Icon {
	if !k.declared() {
		return runConfigTypeIcon(k.provider, dark)
	}
	kind := s.runTypeKind(k.runType)
	if kind == nil {
		return icons.Play
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
