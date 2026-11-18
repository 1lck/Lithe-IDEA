package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// runConfigState is the Run tool window's run configurations: the built-in process runs
// and the build provider runs Core resolved from the detected, project
// (`.lithe/run/configurations.yaml`), local (`.lithe/run/local.yaml`) and plugin
// (`.lithe/run/plugin/*.toml`) layers, and the one the user picked. Only the window
// thread reads or writes it.
type runConfigState struct {
	// generation rejects the answer of a refresh another one replaced.
	generation uint64
	loading    bool
	list       []core.RunConfiguration
	selected   string
	failure    string
	// hidden counts the saved configurations left out of list because nothing here starts
	// them, so an empty list can say so: user entries of another provider, and saved entries
	// Core reports as orphaned because they no longer match a generated configuration, such as
	// the java.main entries an earlier version generated.
	hidden int
	// ignored are the saved documents Core left out, workspace-relative, each once: a plugin
	// document that cannot be read or holds a configuration saved twice, and an earlier
	// release's JSON document its YAML replacement wins over. The built-in configurations
	// still list; the run menu names each file so its configurations do not vanish silently.
	ignored []string
	// types are the kinds a user can create, in display order, each with the reason this
	// platform cannot run it, if any: the built-in ones, then the ones enabled plugins
	// declare. typePlugins are the plugins that declare them, as requests about those kinds
	// send them, nil when none does; both are replaced, never changed, by the next read.
	// typesLoading is set while they are asked for, and typesStale says to read them again
	// once that answers (loadRunConfigTypes).
	types                    []core.RunConfigurationType
	typePlugins              *core.RunTypePlugins
	typesLoading, typesStale bool
	// manualOrder says list is in the order the user gave it on this machine rather than by
	// name; Core keeps the choice locally and lists the configurations in that order.
	manualOrder bool
	// dialog is the Run/Debug Configurations window that creates, edits and removes
	// configurations (runconfig_dialog.go).
	dialog runConfigDialog
	// reveal is the configuration a save just wrote, selected once the next refresh lists it.
	reveal string
	// deleting is the user configuration whose delete waits for confirmation.
	deleting *runConfigDeletion
	// beforeLaunch is the start that waits for the user to allow the steps a project file
	// names before it (runconfig_before_launch.go).
	beforeLaunch *beforeLaunchConfirmation
	// start is the configuration a save asked to run, started once the next refresh lists it
	// so the run reads what was saved.
	start string
	// findingEntrypoint says Run on Current File is asking the build providers for the open
	// file's entrypoint (title_run_entrypoints.go), so another press does not ask again.
	findingEntrypoint bool
	// browser is the list that shows the configurations by scope and build system.
	browser runConfigBrowser
	// currentFile says the user chose Current File in the title bar, so its Run and Debug act
	// on the open file instead of the selected configuration (title_run.go).
	currentFile bool
	// pending is the title bar's Run or Debug waiting for the configurations to be read.
	pending titleAction
	// wanted says the title bar asked for the configurations, so every detected instance
	// loads its model and not only the one the Build window shows.
	wanted bool
}

// configuration is the listed configuration id, or nil.
func (s *runConfigState) configuration(id string) *core.RunConfiguration {
	for index := range s.list {
		if s.list[index].ID == id {
			return &s.list[index]
		}
	}
	return nil
}

// providerRuns is the providerRuns snapshot of the instances whose model has loaded:
// each target a run declaration applies to, under its workspace-relative project path.
// ok is false while no model has loaded, so a refresh does not withdraw every detected
// run before the models answer.
func providerRuns(instances []buildInstance) ([]core.RunProviderRun, bool) {
	runs := []core.RunProviderRun{}
	loaded := false
	for index := range instances {
		instance := &instances[index]
		if !instance.modelLoaded {
			continue
		}
		loaded = true
		for _, target := range instance.Model.Targets {
			project, ok := buildProjectByID(instance.Model, target.ProjectID)
			if !ok {
				continue
			}
			for _, run := range instance.System.Runs {
				if !buildRunApplies(run, target) {
					continue
				}
				runs = append(runs, core.RunProviderRun{
					ProjectPath: path.Clean(path.Join(instance.Root, project.Path)),
					Name:        run.EntryName(target.Name),
					Reference: core.RunProviderReference{
						PluginID: instance.PluginID, BuildSystemID: instance.BuildSystemID, Root: instance.Root,
						Run: run.ID, ProjectID: project.ID, TargetID: target.ID, Execution: run.Execution, UserArguments: []string{},
					},
				})
			}
		}
	}
	return runs, loaded
}

// refreshRunConfigurations has Core generate the runs the loaded models declare and
// resolve the configurations again. Nothing is written into the workspace. It runs
// without any loaded model too, so built-in process runs list and start while no
// build plugin works.
func (a *App) refreshRunConfigurations(p *project) {
	if p == nil {
		return
	}
	s := &p.runConfigs
	s.generation++
	generation := s.generation
	s.loading = true
	runs, loaded := providerRuns(p.build.instances)
	var snapshot json.RawMessage
	if loaded {
		data, err := json.Marshal(runs)
		if err != nil {
			s.loading, s.failure = false, err.Error()
			return
		}
		snapshot = data
	}
	root, kernel := p.root, a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		if snapshot != nil {
			if _, err := kernel.GenerateRunConfigurations(ctx, root, snapshot); err != nil {
				return func(a *App) { a.finishRunConfigurations(p, generation, core.RunConfigResolution{}, err) }
			}
		}
		resolved, err := kernel.ResolveRunConfigurations(ctx, root, a.runConfigPlugins(ctx))
		return func(a *App) { a.finishRunConfigurations(p, generation, resolved, err) }
	})
}

func (a *App) finishRunConfigurations(p *project, generation uint64, resolved core.RunConfigResolution, err error) {
	s := &p.runConfigs
	if generation != s.generation {
		return
	}
	s.loading = false
	defer a.settleTitleAction(p)
	a.loadRunConfigPins(p)
	a.loadRunConfigTypes(p, false)
	if err != nil {
		s.failure = err.Error()
		s.reveal, s.start = "", ""
		return
	}
	s.failure = ""
	// Built-in process runs, build provider runs and the kinds plugins declare start here;
	// the host has no launcher for the other providers Core detects. An unavailable entry
	// stays listed with its reason, so the user can fix or delete it.
	s.hidden = 0
	var ignored []string
	for _, diagnostic := range resolved.Diagnostics {
		if diagnostic.Code == "orphanedOverride" {
			s.hidden++
		}
		if diagnostic.Path != "" && !slices.Contains(ignored, diagnostic.Path) {
			ignored = append(ignored, diagnostic.Path)
			if !slices.Contains(s.ignored, diagnostic.Path) {
				a.operationRejected("run_configuration_document", diagnostic.Code)
			}
		}
	}
	s.ignored = ignored
	s.list = slices.DeleteFunc(resolved.Configurations, func(c core.RunConfiguration) bool {
		_, ok := c.BuildReference()
		_, declared := c.RunTypeReference()
		ok = ok || declared || c.IsProcess() || c.Unavailable()
		if !ok && !c.Disabled {
			s.hidden++
		}
		return !ok || c.Disabled
	})
	s.manualOrder = !resolved.SortAlphabetically
	a.settleRunConfigDialog(p)
	if s.reveal != "" && s.configuration(s.reveal) != nil {
		s.selected = s.reveal
	}
	s.reveal = ""
	if start := s.start; start != "" {
		s.start = ""
		if s.configuration(start) != nil {
			s.selected = start
			a.runConfiguration(p, start)
		}
	}
	if s.configuration(s.selected) == nil {
		s.selected = ""
		if resolved.DefaultRunConfiguration != nil && s.configuration(*resolved.DefaultRunConfiguration) != nil {
			s.selected = *resolved.DefaultRunConfiguration
		} else if len(s.list) > 0 {
			s.selected = s.list[0].ID
		}
	}
}

// runConfiguration is a press that runs configuration id, from the editor, the list of run
// configurations or a session's Rerun: it starts the run with the launch options Core
// resolves from the saved layers and brings the Run window forward on its console, since
// that is where the run prints. A refusal was already told the user or is a press on a
// button that is disabled; the IDE API reports it through startRunConfiguration, which
// leaves the windows as they are.
func (a *App) runConfiguration(p *project, id string) {
	start := func(a *App, p *project) {
		if _, err := a.startRunConfiguration(p, id); err == nil {
			a.showBuildConsole(p)
		}
	}
	// A configuration that allows several instances starts beside the ones that run; any
	// other that runs is stopped first and started again once it ended (startRun).
	if configuration := p.runConfigs.configuration(id); configuration != nil && configuration.AllowMultipleInstances {
		start(a, p)
		return
	}
	a.startRun(p, configurationRunKey(id), start)
}

// configurationRunKey is the run key of run configuration id.
func configurationRunKey(id string) string { return "config:" + id }

// startRunConfiguration checks the request on the window thread, reserves the run as the
// window's operation and starts it once unsaved documents are saved, so the run reads the files
// on disk. The instance must be loaded, since the target is taken from its current model. A
// refused start returns a *buildRefusal and reserves nothing; a reserved run that cannot launch
// ends as failed with the reason, which the returned operation's IDE record keeps.
func (a *App) startRunConfiguration(p *project, id string) (*buildOperation, error) {
	return a.startRunConfigurationWith(p, id, nil)
}

// startRunConfigurationWith is startRunConfiguration; debug, when set, prepares the service
// suspended for the adapter the host selected (debugRunConfiguration), and Rerun debugs again.
func (a *App) startRunConfigurationWith(p *project, id string, debug *connectionDebug) (*buildOperation, error) {
	configuration := p.runConfigs.configuration(id)
	if configuration == nil {
		return nil, refuseBuild(refusalNotFound, "unknown run configuration")
	}
	// Only a run, never a debug session, starts beside one of the same configuration.
	if p.build.runOf(configurationRunKey(id)) != nil && (debug != nil || !configuration.AllowMultipleInstances) {
		return nil, errRunRunning
	}
	if configuration.Unavailable() {
		message := a.runConfigUnavailableText(*configuration)
		a.operationRejected("run_configuration", "unavailable")
		a.notifyError(message)
		return nil, refuseBuild(refusalNotReady, message)
	}
	if configuration.IsProcess() {
		if debug != nil {
			return nil, refuseBuild(refusalNotSupported, "a built-in process run has no debugger")
		}
		return a.startProcessRun(p, *configuration), nil
	}
	if key, ok := configuration.RunTypeReference(); ok {
		if debug != nil {
			return nil, refuseBuild(refusalNotSupported, "a run configuration a plugin declares has no debugger")
		}
		if !p.hasRunTypeInstance(key) {
			a.operationRejected("run_configuration", "target_missing")
			a.notifyError(a.text.Build.TargetMissing)
			return nil, refuseBuild(refusalNotReady, a.text.Build.TargetMissing)
		}
		return a.startProcessRun(p, *configuration), nil
	}
	reference, ok := configuration.BuildReference()
	if !ok {
		return nil, refuseBuild(refusalNotSupported, "this configuration does not start through a build provider")
	}
	index := p.buildInstanceIndex(reference)
	if index < 0 || !p.build.instances[index].modelLoaded {
		a.operationRejected("run_configuration", "target_missing")
		a.notifyError(a.text.Build.TargetMissing)
		return nil, refuseBuild(refusalNotReady, a.text.Build.TargetMissing)
	}
	configurationType := ""
	if debug != nil {
		configurationType = debug.launch.ConfigurationType
	}
	op := a.beginRunOperation(p, configuration.Name, id, configurationRunKey(id), func(a *App, p *project) {
		if debug != nil {
			a.debugRunConfiguration(p, id, configurationType)
			return
		}
		a.runConfiguration(p, id)
	})
	op.debug = debug
	// The run starts a process on the files on disk, so unsaved documents are saved first,
	// as a rerun does; a failed save keeps the run from starting. The save reports its own
	// failure, so the window's status only drops the preparation.
	a.saveProjectDocuments(p, func(ok bool) {
		if op.cancelled {
			a.finishBuildError(p, op, context.Canceled)
			return
		}
		if !ok {
			a.endBuildOperation(p, op, "failed", nil, "unsaved documents could not be saved", "")
			return
		}
		// The steps a configuration names run first; Run and Debug both run them.
		a.runBeforeLaunch(p, op, id, func() { a.prepareConfiguredRun(p, op, id, reference, index, debug) })
	})
	return op, nil
}

// prepareConfiguredRun asks Core for the saved launch options of configuration id and has the
// build provider prepare and start the run.
func (a *App) prepareConfiguredRun(p *project, op *buildOperation, id string, reference core.RunProviderReference, index int, debug *connectionDebug) {
	{
		root, kernel := p.root, a.kernel
		a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
			prepare, release := op.bind(ctx)
			defer release()
			inputs, err := kernel.ProviderLaunchInputs(prepare, root, id, reference.Root)
			if err != nil {
				return func(a *App) { a.finishBuildError(p, op, err) }
			}
			return func(a *App) {
				if op.cancelled || !p.build.owns(op) {
					a.finishBuildError(p, op, context.Canceled)
					return
				}
				if index >= len(p.build.instances) || p.build.instances[index].PluginID != reference.PluginID {
					a.notifyError(a.text.Build.TargetMissing)
					a.finishBuildError(p, op, errors.New(a.text.Build.TargetMissing))
					return
				}
				var options *core.RunLaunchOptions
				launch := inputs.LaunchOptions
				if debug != nil {
					launch.Debug = &debug.launch
				}
				// An application run without choices keeps the request older providers serve.
				if launch.Customized() {
					options = &launch
				}
				a.runBuildTargetWith(p, op, &p.build.instances[index], inputs.Reference.ProjectID, inputs.Reference.TargetID, inputs.Reference.Run, options)
			}
		})
	}
}

// buildInstanceIndex returns the detected build instance a provider reference names, or -1.
func (p *project) buildInstanceIndex(reference core.RunProviderReference) int {
	return slices.IndexFunc(p.build.instances, func(i buildInstance) bool {
		return i.PluginID == reference.PluginID && i.BuildSystemID == reference.BuildSystemID && i.Root == reference.Root
	})
}

// runConfigurationReady reports whether a configuration can start now: a built-in process
// run always can unless it is unavailable; one of a kind a plugin declares once its build
// system is detected; a build provider run once its build instance has a loaded model.
func (p *project) runConfigurationReady(configuration core.RunConfiguration) bool {
	if configuration.Unavailable() {
		return false
	}
	if configuration.IsProcess() {
		return true
	}
	if key, ok := configuration.RunTypeReference(); ok {
		return p.hasRunTypeInstance(key)
	}
	reference, ok := configuration.BuildReference()
	if !ok {
		return false
	}
	index := p.buildInstanceIndex(reference)
	return index >= 0 && p.build.instances[index].modelLoaded
}

// runConfigUnavailableText words why a listed configuration cannot run, from Core's
// availability code. An unknown code shows Core's own message as the reason.
func (a *App) runConfigUnavailableText(configuration core.RunConfiguration) string {
	language := a.language()
	availability := configuration.Availability
	if availability == nil {
		return ""
	}
	plugin, repository, requirement := "", "", ""
	if configuration.Plugin != nil {
		plugin, repository, requirement = configuration.Plugin.Name, configuration.Plugin.Repository, configuration.Plugin.VersionRequirement
		if plugin == "" {
			plugin = configuration.Plugin.ID
		}
	}
	switch availability.Code {
	case "pluginMissing":
		return i18n.SharedFormat(language, "desktop.runConfig.unavailablePluginMissing", map[string]string{"plugin": plugin})
	case "pluginRepositoryMismatch":
		return i18n.SharedFormat(language, "desktop.runConfig.unavailableRepositoryMismatch", map[string]string{"plugin": plugin, "repository": repository})
	case "pluginVersionUnsupported":
		return i18n.SharedFormat(language, "desktop.runConfig.unavailableVersionUnsupported", map[string]string{"plugin": plugin, "requirement": requirement})
	case "missingWorkingDirectory":
		return i18n.SharedFormat(language, "desktop.runConfig.unavailableMissingDirectory", map[string]string{"directory": configuration.Cwd})
	case "invalidConfiguration":
		return i18n.SharedFormat(language, "desktop.runConfig.unavailableInvalid", map[string]string{"reason": availability.Message})
	case "unsupportedPlatform":
		kind, _ := runConfigKindOf(configuration)
		return a.runAvailabilityText(kind, *availability)
	}
	return i18n.SharedFormat(language, "desktop.runConfig.unavailableOther", map[string]string{"reason": availability.Message})
}
