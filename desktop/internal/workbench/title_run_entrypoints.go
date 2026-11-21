package workbench

import (
	"context"
	"errors"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Run and Debug on Current File start the entrypoint a build provider finds in the open file, such as a
// Java class with a main method that no build file names (#2104). A build system that declares
// a run with entrypoints (buildProviders 1) answers lithe/build/runEntrypoints for a file; Core
// plans the request and checks the answer. The first entrypoint is saved as a local run
// configuration named after it, selected in the title bar and started like any provider run,
// so the user edits its arguments and runs it again from the run configuration menu. Saving
// the same entrypoint again reuses the saved configuration.

// entrypointCandidate is one detected instance that may find an entrypoint in the file.
type entrypointCandidate struct {
	index    int
	instance buildInstance
}

// entrypointFound is the entrypoint a candidate found, with the model project it starts in.
type entrypointFound struct {
	instance buildInstance
	entry    core.BuildRunEntrypoint
	project  core.BuildProject
}

// performCurrentFileAction asks the build providers whose instance holds the open file for its
// entrypoints, innermost instance first, and starts the first that supports the action. An instance's model is
// loaded first, since the configuration names the model's project; a press waits for it as a
// press on a configuration does.
func (a *App) performCurrentFileAction(p *project, action titleAction) {
	if a.refuseRemote(p, "run_current_file") {
		return
	}
	if p.safeMode() {
		a.askToTrustProject(p, func() { a.performCurrentFileAction(p, action) })
		return
	}
	s := &p.runConfigs
	if s.findingEntrypoint {
		return
	}
	doc := p.selectedDocument(p.docs.group)
	if doc == nil || doc.path == "" {
		a.runCurrentFileEditorAction(p, doc, action, nil)
		return
	}
	relative, err := filepath.Rel(p.root, doc.path)
	if err != nil || relative == "." || strings.HasPrefix(relative, "..") {
		a.runCurrentFileEditorAction(p, doc, action, nil)
		return
	}
	file := filepath.ToSlash(relative)
	if !p.build.loaded {
		s.pending = action
		a.loadBuildSystems(p)
		return
	}
	candidates := entrypointCandidates(p.build.instances, file, action)
	for _, candidate := range candidates {
		instance := &p.build.instances[candidate.index]
		if instance.modelLoading || (!instance.modelLoaded && instance.modelError == "") {
			s.pending = action
			if !instance.modelLoading {
				a.loadBuildModel(p, candidate.index)
			}
			return
		}
	}
	candidates = slices.DeleteFunc(candidates, func(c entrypointCandidate) bool { return !c.instance.modelLoaded })
	if len(candidates) == 0 {
		a.runCurrentFileEditorAction(p, doc, action, nil)
		return
	}
	if doc.dirty() || doc.saving || doc.conflicted {
		s.findingEntrypoint = true
		a.saveBeforeClose(p, doc, func(ok bool) {
			s.findingEntrypoint = false
			if ok && a.project == p && p.selectedDocument(p.docs.group) == doc {
				a.performCurrentFileAction(p, action)
			}
		})
		return
	}
	if action == titleActionRun {
		a.performed("title.run.currentFile", surfaceToolbar)
	}
	s.findingEntrypoint = true
	kernel := a.kernel
	documentPath, revision := doc.path, doc.view.Revision()
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		found, err := a.findEntrypoint(ctx, p, kernel, candidates, file, action)
		cancelled := errors.Is(ctx.Err(), context.Canceled)
		return func(a *App) {
			s.findingEntrypoint = false
			// log-exempt: 用户取消：项目关闭或请求取消后没有入口需要启动。
			if cancelled {
				return
			}
			if p.selectedDocument(p.docs.group) != doc || doc.path != documentPath || doc.view.Revision() != revision {
				if err != nil {
					a.backgroundFailed("title_run_current_file", err)
				}
				return
			}
			if found != nil {
				s.findingEntrypoint = true
				a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
					id, err := a.saveEntrypointConfiguration(ctx, p, kernel, *found)
					return func(a *App) { a.startEntrypointConfiguration(p, id, action, err) }
				})
				return
			}
			if err != nil && action != titleActionDebug {
				a.operationFailed("title_run_current_file", err)
				a.notifyError(err.Error())
				return
			}
			if err != nil {
				a.backgroundFailed("title_run_current_file", err)
			}
			a.runCurrentFileEditorAction(p, doc, action, err)
		}
	})
}

// entrypointCandidates are the instances that declare an entrypoint run and whose root holds
// file, the innermost root first.
func entrypointCandidates(instances []buildInstance, file string, action titleAction) []entrypointCandidate {
	var candidates []entrypointCandidate
	for index := range instances {
		instance := instances[index]
		if len(instance.System.EntrypointRuns) == 0 || !instance.System.Provider {
			continue
		}
		if action == titleActionDebug && !slices.ContainsFunc(instance.System.EntrypointRuns, func(run pluginservice.BuildRunDeclaration) bool {
			return run.DebugConfigurationType != ""
		}) {
			continue
		}
		root := path.Clean(instance.Root)
		if root != "." && file != root && !strings.HasPrefix(file, root+"/") {
			continue
		}
		candidates = append(candidates, entrypointCandidate{index: index, instance: instance})
	}
	slices.SortStableFunc(candidates, func(left, right entrypointCandidate) int {
		return len(path.Clean(right.instance.Root)) - len(path.Clean(left.instance.Root))
	})
	return candidates
}

// findEntrypoint asks each candidate in turn and returns the first entrypoint whose project the
// candidate's model lists. A candidate that fails does not stop the others; its error is
// returned only when no candidate found anything.
func (a *App) findEntrypoint(ctx context.Context, p *project, kernel Kernel, candidates []entrypointCandidate, file string, action titleAction) (*entrypointFound, error) {
	var failures []error
	for _, candidate := range candidates {
		entries, err := a.runEntrypoints(ctx, p, kernel, candidate.instance, file)
		if err != nil {
			failures = append(failures, err)
			continue
		}
		for _, entry := range entries {
			if action == titleActionDebug {
				run, ok := buildRunDeclaration(candidate.instance.System, entry.Run)
				if !ok || run.DebugConfigurationType == "" {
					continue
				}
			}
			if project, ok := buildProjectByPath(candidate.instance.Model, entry.Project.Path); ok {
				return &entrypointFound{instance: candidate.instance, entry: entry, project: project}, nil
			}
		}
	}
	return nil, errors.Join(failures...)
}

// runEntrypoints plans, sends and decodes one instance's lithe/build/runEntrypoints request.
func (a *App) runEntrypoints(ctx context.Context, p *project, kernel Kernel, instance buildInstance, file string) ([]core.BuildRunEntrypoint, error) {
	request := core.BuildPlanRequest{Root: instance.Root, Options: instance.Options, PluginDirectory: instance.PackageDirectory, WorkspaceRoot: p.root, File: file, ProjectCodeAllowed: p.trust.allowed()}
	plan, err := kernel.PlanBuildRunEntrypoints(ctx, instance.Manifest, instance.BuildSystemID, request)
	if err != nil {
		return nil, err
	}
	if plan.Provider == nil {
		return nil, errors.New("the build system answered with a command plan")
	}
	client, err := a.buildProvider(ctx, p, instance)
	if err != nil {
		return nil, err
	}
	operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(buildRequestTimeout/time.Millisecond))
	if err != nil {
		return nil, err
	}
	result, err := operation.Wait(ctx)
	if err != nil {
		return nil, err
	}
	return kernel.DecodeBuildRunEntrypoints(ctx, instance.Manifest, instance.BuildSystemID, core.BuildDecodeRunEntrypointsRequest{
		Root: instance.Root, Options: instance.Options, PluginDirectory: instance.PackageDirectory, Result: result,
	})
}

// saveEntrypointConfiguration has Core save the local configuration that starts found and
// writes it, returning its ID.
func (a *App) saveEntrypointConfiguration(ctx context.Context, p *project, kernel Kernel, found entrypointFound) (string, error) {
	reference := core.RunProviderReference{
		PluginID: found.instance.PluginID, BuildSystemID: found.instance.BuildSystemID, Root: found.instance.Root,
		Run: found.entry.Run, ProjectID: found.project.ID, Execution: "application", UserArguments: []string{},
	}
	id, changes, err := kernel.CreateRunEntrypointConfiguration(ctx, core.RunEntrypointConfigurationRequest{
		Root: p.root, Name: found.entry.Name, Build: reference, Entrypoint: found.entry.Entrypoint,
		Plugins: a.runConfigPlugins(ctx),
	})
	if err != nil {
		return "", err
	}
	if err := applyRunConfigChanges(ctx, p.root, changes); err != nil {
		return "", err
	}
	return id, nil
}

// startEntrypointConfiguration makes the saved configuration what the title bar runs and starts
// it once the configurations are read again.
func (a *App) startEntrypointConfiguration(p *project, id string, action titleAction, err error) {
	s := &p.runConfigs
	s.findingEntrypoint = false
	if err != nil {
		a.operationFailed("title_run_current_file", err)
		a.notifyError(err.Error())
		return
	}
	s.currentFile = false
	s.reveal, s.start, s.startAction = id, id, action
	a.refreshRunConfigurations(p)
}

// buildProjectByPath is the model project at the instance-relative path, as Core names an
// entrypoint's project.
func buildProjectByPath(model core.BuildModel, projectPath string) (core.BuildProject, bool) {
	want := path.Clean(projectPath)
	for _, project := range model.Projects {
		if path.Clean(project.Path) == want {
			return project, true
		}
	}
	return core.BuildProject{}, false
}
