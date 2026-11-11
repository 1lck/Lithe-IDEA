package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/projectgen"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

var ()

// emptyProjectKey names the host's own entry in the generator list.
const emptyProjectKey = "empty"

// projectChoice is one entry of the New Project list: the host's empty project
// or a generator a plugin declared. Nothing in the window branches on its ID.
type projectChoice struct {
	key     string
	name    string
	section string
	entry   *core.ProjectGeneratorEntry
	plugin  pluginservice.GeneratorPlugin
}

// catalogResult is what the catalog load found.
type catalogResult struct {
	plugins map[string]pluginservice.GeneratorPlugin
	catalog core.ProjectGeneratorCatalog
}

// precheck is the result of validating the name and the location off the window thread.
type precheck struct {
	key      string
	problem  string
	absolute string
}

// runProgress is what a running generation reports. It is written from the run's
// goroutine and read while painting, so it has its own lock.
type runProgress struct {
	mu          sync.Mutex
	step, steps int
	kind        string
	lines       []string
}

// progressLines bounds the output the window keeps.
const progressLines = 200

func (p *runProgress) observe(event projectgen.Event) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch event.Kind {
	case projectgen.EventStep:
		p.step, p.steps, p.kind = event.Step, event.Steps, event.Text
	case projectgen.EventOutput:
		p.lines = append(p.lines, event.Text)
		if len(p.lines) > progressLines {
			p.lines = append(p.lines[:0], p.lines[len(p.lines)-progressLines:]...)
		}
	}
}

// snapshot copies the state for painting.
func (p *runProgress) snapshot() (step, steps int, lines []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.step, p.steps, append([]string(nil), p.lines...)
}

// newProjectState is window-owned: an unfinished operation must not be attached
// to the project it may replace. created records a directory that was created
// successfully even if a later part (Git, pins) failed.
type newProjectState struct {
	name, parent, search string
	open, busy, git      bool
	cancelling           bool
	generation           uint64
	cancel               context.CancelFunc
	err, created         string

	list ui.ListState
	// choice is the selected entry's key.
	choice  string
	choices []projectChoice
	// forms keep what the user entered while they look at another entry.
	forms map[string]*generatorForm
	// revision counts plugin changes, so the catalog and tool lists are read again.
	revision      int
	catalogLoaded bool
	catalogFailed bool
	issues        []core.ProjectGeneratorIssue
	// visible is the search's answer by key; nil shows everything.
	visible map[string]bool
	check   precheck
	checked bool
	// progress is the last run's step and output, kept so a failure stays explained.
	progress *runProgress

	catalogFx *keyedEffect[catalogResult, struct{}]
	toolsFx   *keyedEffect[map[string]toolList, []string]
	formFx    *keyedEffect[core.ProjectGeneratorForm, formRequest]
	checkFx   *keyedEffect[precheck, checkRequest]
	searchFx  *keyedEffect[[]int, searchRequest]
	toolsFor  string
	// advancedOpen expands the "Advanced Settings" group of a generator form.
	advancedOpen bool
}

type formRequest struct {
	manifest    []byte
	generatorID string
	input       core.ProjectGeneratorFormInput
}

type checkRequest struct {
	key, parent, name string
}

type searchRequest struct {
	query      string
	candidates []core.RankCandidate
}

func (a *App) openNewProject(surface string) {
	n := &a.newProject
	if n.open {
		return
	}
	n.generation++
	n.open, n.busy, n.git, n.cancelling = true, false, false, false
	n.err, n.created = "", ""
	n.name = i18n.Shared(a.language(), "desktop.newProject.defaultName")
	n.parent = filepath.Join("~", "LitheProjects")
	n.search = ""
	n.choice = emptyProjectKey
	n.choices = []projectChoice{{key: emptyProjectKey, name: i18n.Shared(a.language(), "desktop.newProject.empty"), section: "project"}}
	n.forms = map[string]*generatorForm{}
	n.list = ui.ListState{}
	n.catalogLoaded, n.catalogFailed, n.issues = false, false, nil
	n.visible, n.checked, n.progress, n.toolsFor = nil, false, nil, ""
	n.newEffects(a)
	a.performed("workspace.new", surface)
}

// newEffects makes the effects that belong to the dialog. They are declared by the window's
// page while the dialog is open, so they end when it closes.
func (n *newProjectState) newEffects(a *App) {
	n.catalogFx = newKeyedEffect(a.loadProjectCatalog)
	n.toolsFx = newKeyedEffect(a.loadProjectTools)
	n.formFx = newKeyedEffect(a.evaluateProjectForm)
	n.checkFx = newKeyedEffect(a.checkProjectLocation)
	n.searchFx = newKeyedEffect(a.rankProjectChoices)
}

func (a *App) closeNewProject() {
	n := &a.newProject
	n.generation++
	if n.cancel != nil {
		n.cancel()
		n.cancel = nil
	}
	n.open, n.busy, n.cancelling = false, false, false
}

func (a *App) dismissNewProject() {
	if a.newProject.busy {
		return
	}
	a.closeNewProject()
}

// cancelNewProject waits for the worker to return, so a second attempt cannot
// race filesystem or Git operations still finishing from the first.
func (a *App) cancelNewProject() {
	n := &a.newProject
	if n.busy {
		n.cancelling = true
		if n.cancel != nil {
			n.cancel()
		}
		return
	}
	a.dismissNewProject()
}

func (a *App) chooseNewProjectParent() {
	n := &a.newProject
	generation := n.generation
	title := i18n.Shared(a.language(), "desktop.newProject.location")
	a.background(nil, 0, func(context.Context) func(*App) {
		path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
		return func(a *App) {
			n := &a.newProject
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：未选择目录。
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_choose_directory", documentLogError(err)))
				if n.open && n.generation == generation {
					n.err = i18n.Shared(a.language(), "desktop.newProject.chooseFailed")
				}
				return
			}
			if n.open && n.generation == generation && !n.busy && n.created == "" {
				n.parent = path
				n.err = ""
			}
		}
	})
}

// projectParent expands the conventional home shorthand without interpreting
// any other shell syntax. Only an absolute path can be a destination.
func projectParent(path, home string) string {
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") || strings.HasPrefix(path, "~\\") {
		return filepath.Join(home, path[2:])
	}
	return path
}

type newProjectResult struct {
	path, reason string
	err          error
	created      bool
}

// createEmptyProject reserves the final directory with a single mkdir. It
// never replaces or removes a user's existing directory, including after a
// failed or cancelled Git initialization.
func createEmptyProject(ctx context.Context, kernel Kernel, parent, name string, git bool) newProjectResult {
	problem, err := kernel.CheckProjectName(ctx, name)
	if err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if problem != "" {
		return newProjectResult{reason: "invalidName", err: errors.New("invalid project name")}
	}
	destination, valid := cloneDestination(parent, name)
	if !valid {
		return newProjectResult{reason: "invalidLocation", err: errors.New("invalid project location")}
	}
	if err := ctx.Err(); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := ctx.Err(); err != nil {
		return newProjectResult{reason: "failed", err: err}
	}
	if err := os.Mkdir(destination, 0o755); err != nil {
		reason := "failed"
		if errors.Is(err, os.ErrExist) {
			reason = "exists"
		}
		return newProjectResult{reason: reason, err: err}
	}
	result := newProjectResult{path: destination, created: true}
	if err := ctx.Err(); err != nil {
		result.reason, result.err = "createdInterrupted", err
		return result
	}
	if git {
		if err := kernel.InitializeGit(ctx, destination); err != nil {
			result.reason, result.err = "gitFailed", err
		}
	}
	return result
}

// loadProjectCatalog reads the installed plugins and asks Core for their
// generators. It runs off the window thread as a page effect.
func (a *App) loadProjectCatalog(ctx context.Context, _ struct{}) (catalogResult, error) {
	var plugins []pluginservice.GeneratorPlugin
	var readErr error
	switch {
	case a.generatorPlugins != nil:
		plugins, readErr = a.generatorPlugins(ctx)
	case a.plugins != nil:
		plugins, readErr = a.plugins.GeneratorPlugins(ctx)
	}
	if readErr != nil && len(plugins) == 0 {
		return catalogResult{}, readErr
	}
	result := catalogResult{plugins: make(map[string]pluginservice.GeneratorPlugin, len(plugins))}
	request := make([]core.ProjectGeneratorPlugin, 0, len(plugins))
	for _, plugin := range plugins {
		result.plugins[plugin.PluginID] = plugin
		request = append(request, core.ProjectGeneratorPlugin{Manifest: plugin.Manifest, Enabled: plugin.Enabled})
	}
	catalog, err := a.kernel.ProjectGeneratorCatalogOf(ctx, request)
	if err != nil {
		return catalogResult{}, err
	}
	result.catalog = catalog
	return result, readErr
}

// loadProjectTools lists the installations of each tool a generator's fields
// pick. New Project has no workspace, so discovery runs in an empty temporary
// directory: no project pin applies, exactly as the settings page shows a tool
// before a project chooses one.
func (a *App) loadProjectTools(ctx context.Context, tools []string) (map[string]toolList, error) {
	if a.projectToolLists != nil {
		return a.projectToolLists(ctx, tools)
	}
	manifests, err := a.toolchainManifests(ctx)
	if err != nil && len(manifests) == 0 {
		return nil, err
	}
	root, mkErr := os.MkdirTemp("", "lithe-new-project-tools-*")
	if mkErr != nil {
		return nil, mkErr
	}
	defer os.RemoveAll(root)
	snapshot, loadErr := toolchain.Load(ctx, a.kernel, root, ".", manifests, toolchain.Options{Platform: buildPlatform()})
	if loadErr != nil {
		return nil, loadErr
	}
	result := make(map[string]toolList, len(tools))
	for _, wanted := range tools {
		list := toolList{}
		for _, tool := range snapshot.Tools {
			if tool.ID != wanted && tool.PluginID+":"+tool.ID != wanted {
				continue
			}
			for _, installation := range tool.Installations {
				list.Installations = append(list.Installations, toolInstall{
					ProjectToolInstallation: core.ProjectToolInstallation{Home: installation.Home, Executable: installation.Executable, Version: installation.Version},
					Provider:                installation.Provider,
				})
			}
			break
		}
		result[wanted] = list
	}
	return result, nil
}

func (a *App) evaluateProjectForm(ctx context.Context, request formRequest) (core.ProjectGeneratorForm, error) {
	return a.kernel.ProjectGeneratorFormOf(ctx, request.manifest, request.generatorID, request.input)
}

// checkProjectLocation validates the name through Core and the destination on
// disk. It is the same set of checks the empty project has always run when it
// creates, moved ahead so the window can say so before the user clicks Create.
func (a *App) checkProjectLocation(ctx context.Context, request checkRequest) (precheck, error) {
	result := precheck{key: request.key}
	problem, err := a.kernel.CheckProjectName(ctx, request.name)
	if err != nil {
		return precheck{}, err
	}
	if problem != "" {
		result.problem = "invalidName"
		return result, nil
	}
	parent := request.parent
	if parent == "~" || strings.HasPrefix(parent, "~/") || strings.HasPrefix(parent, "~\\") {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil {
			result.problem = "invalidLocation"
			return result, nil
		}
		parent = projectParent(parent, home)
	}
	destination, valid := cloneDestination(parent, request.name)
	if !valid {
		result.problem = "invalidLocation"
		return result, nil
	}
	result.absolute = destination
	if _, statErr := os.Lstat(destination); statErr == nil {
		result.problem = "exists"
	}
	return result, nil
}

func (a *App) rankProjectChoices(ctx context.Context, request searchRequest) ([]int, error) {
	return a.kernel.RankNames(ctx, request.query, request.candidates)
}

// applyCatalog turns Core's catalog into the list of choices: the generators of
// enabled plugins, with the host's empty project closing the first section.
func (n *newProjectState) applyCatalog(a *App, result catalogResult) {
	n.catalogLoaded = true
	n.issues = result.catalog.Issues
	var projects, generators []projectChoice
	for index := range result.catalog.Generators {
		entry := result.catalog.Generators[index]
		if !entry.PluginEnabled {
			continue
		}
		choice := projectChoice{
			key:     entry.PluginID + "/" + entry.Generator.ID,
			name:    entry.Generator.DisplayName,
			section: entry.Generator.Section,
			entry:   &entry,
			plugin:  result.plugins[entry.PluginID],
		}
		if entry.Generator.Section == "project" {
			projects = append(projects, choice)
		} else {
			generators = append(generators, choice)
		}
	}
	empty := projectChoice{key: emptyProjectKey, name: i18n.Shared(a.language(), "desktop.newProject.empty"), section: "project"}
	n.choices = append(append(projects, empty), generators...)
	// A generator whose plugin was removed or changed cannot keep a stale form.
	for key, form := range n.forms {
		kept := false
		for _, choice := range n.choices {
			if choice.key == key && choice.entry != nil && form.entry.PluginID == choice.entry.PluginID {
				kept = true
			}
		}
		if !kept {
			delete(n.forms, key)
		}
	}
	if n.current() == nil {
		n.choice = emptyProjectKey
	}
}

// current is the selected choice, or nil when it no longer exists.
func (n *newProjectState) current() *projectChoice {
	for index := range n.choices {
		if n.choices[index].key == n.choice {
			return &n.choices[index]
		}
	}
	return nil
}

// form is the generator form of the selected choice, made on first use.
func (n *newProjectState) form() *generatorForm {
	choice := n.current()
	if choice == nil || choice.entry == nil {
		return nil
	}
	if form := n.forms[choice.key]; form != nil {
		return form
	}
	form := newGeneratorForm(choice.key, *choice.entry, choice.plugin)
	n.forms[choice.key] = form
	return form
}

// generatorFailureMessage maps why a run stopped to the localized message.
func (a *App) generatorFailureMessage(failure *projectgen.Failure) string {
	language := a.language()
	switch failure.Reason {
	case projectgen.ReasonInvalidLocation:
		return i18n.Shared(language, "desktop.newProject.invalidLocation")
	case projectgen.ReasonExists:
		return i18n.Shared(language, "desktop.newProject.exists")
	case projectgen.ReasonCommandMissing:
		return i18n.SharedFormat(language, "desktop.newProject.commandMissing", map[string]string{"command": missingCommand(failure.Err)})
	case projectgen.ReasonCommandFailed:
		return i18n.Shared(language, "desktop.newProject.commandFailed")
	case projectgen.ReasonTimedOut:
		return i18n.Shared(language, "desktop.newProject.timedOut")
	case projectgen.ReasonDownloadFailed:
		return i18n.Shared(language, "desktop.newProject.downloadFailed")
	case projectgen.ReasonArchiveInvalid:
		return i18n.Shared(language, "desktop.newProject.archiveInvalid")
	case projectgen.ReasonPinFailed:
		return i18n.Shared(language, "desktop.newProject.pinFailed")
	case projectgen.ReasonGitFailed:
		return i18n.Shared(language, "desktop.newProject.gitFailed")
	case projectgen.ReasonCancelled:
		return i18n.Shared(language, "desktop.newProject.createdInterrupted")
	}
	return i18n.Shared(language, "desktop.newProject.failed")
}

// resolveProjectCommand resolves a generator's bare command name like a build
// tool does: on the PATH the window runs with. A missing tool is reported as
// missing, never replaced by a guessed one.
func (a *App) resolveProjectCommand(ctx context.Context, command string) (projectgen.Command, error) {
	if a.projectCommand != nil {
		return a.projectCommand(ctx, command)
	}
	return projectgen.LookPathResolver(ctx, command)
}

// saveProjectPins records the tool selections of the new project through the
// same store the toolchain settings page edits. A version 1 runtime field pins
// its tool as well, so the project builds with the installation picked here.
func (a *App) saveProjectPins(ctx context.Context, form *generatorForm, root string, plan core.ProjectGenerationPlan) error {
	var edits []toolchain.Edit
	pin := func(tool, home string) {
		installation, ok := form.installation(tool, home)
		if !ok || installation.Version == "" {
			return
		}
		edits = append(edits, toolchain.Edit{Tool: tool, Pin: &core.ToolchainPin{Home: home, Version: installation.Version, Provider: installation.Provider}})
	}
	for _, p := range plan.ToolPins {
		pin(p.Tool, p.Home)
	}
	if len(edits) == 0 {
		return nil
	}
	_, _, err := toolchain.SavePins(ctx, a.kernel, root, ".", edits, nil)
	return err
}

// submitNewProject creates the selected entry: the empty project directly, a
// generator by asking Core for its plan and running it in a staging directory.
func (a *App) submitNewProject() {
	n := &a.newProject
	if !n.open || n.busy {
		return
	}
	if n.created != "" {
		path := n.created
		a.closeNewProject()
		a.openProject(path)
		return
	}
	parent := n.parent
	if parent == "~" || strings.HasPrefix(parent, "~/") || strings.HasPrefix(parent, "~\\") {
		home, err := os.UserHomeDir()
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_home", documentLogError(err)))
			n.err = i18n.Shared(a.language(), "desktop.newProject.invalidLocation")
			return
		}
		parent = projectParent(parent, home)
	}
	if n.current() != nil && n.current().entry != nil {
		a.submitGenerator(parent)
		return
	}
	name, git := n.name, n.git
	n.busy, n.cancelling, n.err = true, false, ""
	n.progress = nil
	generation := n.generation
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	n.cancel = cancel
	kernel := a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result := createEmptyProject(ctx, kernel, parent, name, git)
		return func(a *App) { a.finishNewProject(generation, result) }
	})
}

// finishNewProject applies the result of creating the empty project.
func (a *App) finishNewProject(generation uint64, result newProjectResult) {
	n := &a.newProject
	if result.err != nil && !errors.Is(result.err, context.Canceled) {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_create", documentLogError(result.err)))
	}
	if !n.open || n.generation != generation {
		// log-exempt: 用户取消：窗口已关闭，保留可能已创建的目录。
		return
	}
	n.cancel, n.busy = nil, false
	if n.cancelling {
		n.cancelling = false
		if result.created {
			n.created = result.path
			n.err = i18n.Shared(a.language(), "desktop.newProject.createdInterrupted")
		} else {
			a.dismissNewProject()
		}
		return
	}
	if result.err != nil {
		if result.created {
			n.created = result.path
		}
		message := i18n.Shared(a.language(), "desktop.newProject.failed")
		switch result.reason {
		case "invalidName":
			message = i18n.Shared(a.language(), "desktop.newProject.invalidName")
		case "invalidLocation":
			message = i18n.Shared(a.language(), "desktop.newProject.invalidLocation")
		case "exists":
			message = i18n.Shared(a.language(), "desktop.newProject.exists")
		case "gitFailed":
			message = i18n.Shared(a.language(), "desktop.newProject.gitFailed")
		case "createdInterrupted":
			message = i18n.Shared(a.language(), "desktop.newProject.createdInterrupted")
		}
		n.err = message
		return
	}
	a.closeNewProject()
	a.openProject(result.path)
}

// submitGenerator asks Core for the plan of the filled-in form and runs it. The
// whole run is cancellable and its commands and downloads have their own limits.
func (a *App) submitGenerator(parent string) {
	n := &a.newProject
	choice := n.current()
	form := n.form()
	if choice == nil || form == nil || !form.ready() {
		return
	}
	name, git := n.name, n.git
	input := form.input(name)
	manifest, generatorID, packagePath := []byte(form.plugin.Manifest), form.entry.Generator.ID, form.plugin.Path
	n.busy, n.cancelling, n.err = true, false, ""
	progress := &runProgress{}
	n.progress = progress
	generation := n.generation
	ctx, cancel := context.WithCancel(context.Background())
	n.cancel = cancel
	kernel := a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result := projectgen.Result{}
		plan, err := kernel.ProjectGenerationPlanOf(ctx, manifest, generatorID, packagePath, input)
		if err != nil {
			reason := projectgen.ReasonStepFailed
			if errors.Is(err, context.Canceled) {
				reason = projectgen.ReasonCancelled
			}
			result.Failure = &projectgen.Failure{Reason: reason, Err: err}
		} else {
			result = projectgen.Run(ctx, projectgen.Request{
				Parent: parent, Name: name, Plan: plan, Git: git, Kernel: kernel,
				Resolve: func(ctx context.Context, command string) (projectgen.Command, error) {
					return a.resolveProjectCommand(ctx, command)
				},
				SavePins: func(ctx context.Context, root string, plan core.ProjectGenerationPlan) error {
					return a.saveProjectPins(ctx, form, root, plan)
				},
				Observe: func(event projectgen.Event) {
					progress.observe(event)
					a.invalidator.Invalidate()
				},
			})
		}
		return func(a *App) { a.finishGenerator(generation, result) }
	})
}

// finishGenerator applies the result of a generator run on the window thread.
func (a *App) finishGenerator(generation uint64, result projectgen.Result) {
	n := &a.newProject
	if result.Failure != nil && !errors.Is(result.Failure, context.Canceled) {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("new_project_generate", documentLogError(result.Failure.Err)))
	}
	if !n.open || n.generation != generation {
		// log-exempt: 用户取消：窗口已关闭，保留可能已创建的目录。
		return
	}
	n.cancel, n.busy = nil, false
	if n.cancelling {
		n.cancelling = false
		if result.Path != "" {
			n.created = result.Path
			n.err = i18n.Shared(a.language(), "desktop.newProject.createdInterrupted")
		} else {
			a.dismissNewProject()
		}
		return
	}
	if result.Failure != nil {
		if result.Path != "" {
			n.created = result.Path
		}
		n.err = a.generatorFailureMessage(result.Failure)
		return
	}
	a.closeNewProject()
	a.pendingOpen = pendingOpenFiles{root: result.Path, files: result.OpenFiles}
	a.openProject(result.Path)
}

// missingCommand extracts the name of the command a resolver could not find.
func missingCommand(err error) string {
	text := err.Error()
	if index := strings.LastIndex(text, ": "); index >= 0 {
		return text[index+2:]
	}
	return text
}

// pendingOpenFiles are the files a generator asked to open once its project is open.
type pendingOpenFiles struct {
	root  string
	files []string
}

// openPendingFiles opens a generator's openFiles in the project it created.
func (a *App) openPendingFiles(p *project) {
	pending := a.pendingOpen
	a.pendingOpen = pendingOpenFiles{}
	if pending.root == "" || p.root != pending.root {
		return
	}
	for _, file := range pending.files {
		a.openFile(p, filepath.Join(p.root, filepath.FromSlash(file)))
	}
}
