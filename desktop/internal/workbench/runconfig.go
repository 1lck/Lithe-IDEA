package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"path"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// runConfigState is the Run tool window's run configurations: the build provider
// runs Core resolved from the detected, team (`.lithe/run/configurations.json`) and
// local (`.lithe/run/local.json`) layers, and the one the user picked. Only the
// window thread reads or writes it.
type runConfigState struct {
	// generation rejects the answer of a refresh another one replaced.
	generation uint64
	loading    bool
	list       []core.RunConfiguration
	selected   string
	failure    string
	// hidden counts the saved configurations left out of list because no build plugin starts
	// them, so an empty list can say so: user entries of another provider, and saved entries
	// Core reports as orphaned because they no longer match a generated configuration, such as
	// the java.main entries an earlier version generated.
	hidden int
	// editor is the dialog that edits one configuration's saved options.
	editor runConfigEditor
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
// resolve the configurations again. Nothing is written into the workspace.
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
		resolved, err := kernel.ResolveRunConfigurations(ctx, root)
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
	if err != nil {
		s.failure = err.Error()
		return
	}
	s.failure = ""
	// Only build provider runs can start here; the host has no launcher for the other
	// providers Core detects.
	s.hidden = 0
	for _, diagnostic := range resolved.Diagnostics {
		if diagnostic.Code == "orphanedOverride" {
			s.hidden++
		}
	}
	s.list = slices.DeleteFunc(resolved.Configurations, func(c core.RunConfiguration) bool {
		_, ok := c.BuildReference()
		if !ok && !c.Disabled {
			s.hidden++
		}
		return !ok || c.Disabled
	})
	if s.configuration(s.selected) == nil {
		s.selected = ""
		if resolved.DefaultRunConfiguration != nil && s.configuration(*resolved.DefaultRunConfiguration) != nil {
			s.selected = *resolved.DefaultRunConfiguration
		} else if len(s.list) > 0 {
			s.selected = s.list[0].ID
		}
	}
}

// runConfiguration starts configuration id through its build provider with the launch
// options Core resolves from the saved layers. The Run window ignores the refusal; the IDE
// API reports it through startRunConfiguration.
func (a *App) runConfiguration(p *project, id string) {
	a.startRun(p, configurationRunKey(id), func(a *App, p *project) {
		// log-exempt: reported：a refusal already told the user why, and the Run window has no tool call to answer.
		_, _ = a.startRunConfiguration(p, id)
	})
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
	if p.build.runOf(configurationRunKey(id)) != nil {
		return nil, errRunRunning
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
	})
	return op, nil
}

// buildInstanceIndex returns the detected build instance a provider reference names, or -1.
func (p *project) buildInstanceIndex(reference core.RunProviderReference) int {
	return slices.IndexFunc(p.build.instances, func(i buildInstance) bool {
		return i.PluginID == reference.PluginID && i.BuildSystemID == reference.BuildSystemID && i.Root == reference.Root
	})
}

// runConfigurationReady reports whether a configuration can start now: its build instance
// has a loaded model.
func (p *project) runConfigurationReady(configuration core.RunConfiguration) bool {
	reference, ok := configuration.BuildReference()
	if !ok {
		return false
	}
	index := p.buildInstanceIndex(reference)
	return index >= 0 && p.build.instances[index].modelLoaded
}
