package workbench

import (
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// titleAction is a press on the title bar's Run or Debug button that waits for the project's
// run configurations to be read.
type titleAction uint8

const (
	titleActionNone titleAction = iota
	titleActionRun
	titleActionDebug
)

// titleConfiguration is the run configuration the title bar's Run and Debug start, nil when
// they act on the current file: the user chose Current File, or the project has no
// configuration.
func (p *project) titleConfiguration() *core.RunConfiguration {
	if p == nil || p.runConfigs.currentFile {
		return nil
	}
	return p.runConfigs.configuration(p.runConfigs.selected)
}

// titleRunLabel is what the title bar's run configuration button reads: the chosen
// configuration, or Current File.
func (a *App) titleRunLabel() string {
	if configuration := a.project.titleConfiguration(); configuration != nil {
		return configuration.Name
	}
	return a.text.Title.CurrentFile
}

// runConfigsSettled reports whether the configurations the project can offer are read: build
// detection answered, no model is on its way and Core resolved the configurations since.
func (p *project) runConfigsSettled() bool {
	if !p.build.loaded || p.build.loading || p.runConfigs.loading {
		return false
	}
	for index := range p.build.instances {
		if p.build.instances[index].modelLoading {
			return false
		}
	}
	return true
}

// loadTitleRunConfigs reads what the title bar lists. Detection runs once; after it every
// detected instance loads its model, since each offers its own runs, where the Build window
// only loads the instance it shows.
func (a *App) loadTitleRunConfigs(p *project) {
	if p == nil {
		return
	}
	p.runConfigs.wanted = true
	if !p.build.loaded {
		a.loadBuildSystems(p)
		return
	}
	for index := range p.build.instances {
		if p.build.instances[index].modelError == "" {
			a.loadBuildModel(p, index)
		}
	}
}

// openRunConfigMenu opens the run configuration menu, closes the other menus of the title bar
// and starts reading the configurations the menu lists.
func (a *App) openRunConfigMenu() {
	a.title.runConfigOpen = true
	a.title.projectOpen, a.title.gearOpen = false, false
	a.closeBranches()
	a.loadTitleRunConfigs(a.project)
}

// chooseTitleConfiguration makes configuration id what the title bar runs; the empty id is
// Current File.
func (a *App) chooseTitleConfiguration(p *project, id string) {
	if p == nil {
		return
	}
	if id == "" {
		p.runConfigs.currentFile = true
		return
	}
	if p.runConfigs.configuration(id) == nil {
		return
	}
	p.runConfigs.currentFile = false
	p.runConfigs.selected = id
}

// editRunConfigurations opens the Run window, which lists the configurations, and the editor
// of the one the title bar runs.
func (a *App) editRunConfigurations(p *project) {
	if p == nil {
		return
	}
	a.openToolWindow(itemRun)
	if configuration := p.titleConfiguration(); configuration != nil {
		a.openRunConfigEditor(p, configuration.ID)
	}
}

// openToolWindow shows tool window id, leaving it open when it already is.
func (a *App) openToolWindow(id string) {
	if !a.chrome.isOpen(catalogIndex[id]) {
		a.reduceChrome(core.ToggleChrome(id))
	}
}

// titleRun is a press on the title bar's Run button: it opens the Run window and runs the
// chosen configuration.
func (a *App) titleRun(p *project) {
	if p == nil {
		return
	}
	a.performed("title.run", surfaceButton)
	a.openToolWindow(itemRun)
	a.titleStart(p, titleActionRun)
}

// titleDebug is a press on the title bar's Debug button: it opens the Debug window and debugs
// the chosen configuration, or the current file under the selected adapter.
func (a *App) titleDebug(p *project) {
	if p == nil {
		return
	}
	a.performed("title.debug", surfaceButton)
	a.openToolWindow(itemDebug)
	a.titleStart(p, titleActionDebug)
}

// titleStart performs action now when the configurations are read, and otherwise reads them
// and performs it once they are. A later press replaces the waiting one.
func (a *App) titleStart(p *project, action titleAction) {
	if p.runConfigs.currentFile {
		a.performTitleAction(p, action, true)
		return
	}
	p.runConfigs.pending = action
	a.loadTitleRunConfigs(p)
	if p.runConfigs.pending == action && p.runConfigsSettled() {
		p.runConfigs.pending = titleActionNone
		a.performTitleAction(p, action, true)
	}
}

// settleTitleAction performs the press that waited for the configurations once they are read.
// It runs after every answer that can settle them: detection, a model and the configurations.
func (a *App) settleTitleAction(p *project) {
	if p == nil || a.project != p || p.runConfigs.pending == titleActionNone || !p.runConfigsSettled() {
		return
	}
	action := p.runConfigs.pending
	p.runConfigs.pending = titleActionNone
	a.performTitleAction(p, action, false)
}

// performTitleAction starts action on the title bar's choice. A configuration whose model has
// not loaded loads it first and waits again; retry says a model that failed before is loaded
// once more, which only a press asks for, so an answer that fails again does not loop.
func (a *App) performTitleAction(p *project, action titleAction, retry bool) {
	configuration := p.titleConfiguration()
	if configuration == nil {
		a.performCurrentFileAction(p, action)
		return
	}
	reference, ok := configuration.BuildReference()
	if !ok {
		return
	}
	index := p.buildInstanceIndex(reference)
	if index < 0 {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("title_run", errors.New("the configuration's build instance was not detected")))
		a.notifyError(a.text.Build.TargetMissing)
		return
	}
	instance := &p.build.instances[index]
	if !instance.modelLoaded {
		if instance.modelError != "" && !retry {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("title_run", errors.New(instance.modelError)))
			a.notifyError(instance.modelError)
			return
		}
		p.runConfigs.pending = action
		a.loadBuildModel(p, index)
		return
	}
	switch action {
	case titleActionRun:
		if _, err := a.startRunConfiguration(p, configuration.ID); errors.Is(err, errBuildBusy) {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.title.runBusy"))
		}
	case titleActionDebug:
		run, ok := buildRunDeclaration(instance.System, reference.Run)
		if !ok || run.DebugAdapter == "" {
			a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.title.notDebuggable", map[string]string{"name": configuration.Name}))
			return
		}
		a.debugProviderTarget(p, index, reference.ProjectID, reference.TargetID, reference.Run)
	}
}

// performCurrentFileAction is Run or Debug on Current File. The Debug window starts the open
// file under its selected adapter; nothing runs the current file outside a configuration.
func (a *App) performCurrentFileAction(p *project, action titleAction) {
	if action == titleActionDebug {
		a.whenDebugAdaptersLoaded(p, func() { a.startDebug(p) })
		return
	}
	a.notifyInfo(i18n.Shared(a.language(), "desktop.title.currentFileNotRunnable"))
}
