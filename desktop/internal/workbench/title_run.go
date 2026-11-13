package workbench

import (
	"context"
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

// titleStart is a press on Run or Debug. Unless the user chose Current File, the press waits
// while the configurations are read, and an answer that settles them while they are asked for
// performs it; otherwise Core decides what the press does now.
func (a *App) titleStart(p *project, action titleAction) {
	if !p.runConfigs.currentFile {
		p.runConfigs.pending = action
		a.loadTitleRunConfigs(p)
		if p.runConfigs.pending != action {
			return
		}
	}
	a.decideTitleAction(p, action, "press")
}

// settleTitleAction asks again for the press that waited, after every answer that can settle
// the configurations: detection, a model and the configurations.
func (a *App) settleTitleAction(p *project) {
	if p == nil || a.project != p || p.runConfigs.pending == titleActionNone {
		return
	}
	a.decideTitleAction(p, p.runConfigs.pending, "settled")
}

// decideTitleAction reports the facts a press depends on to Core and does what Core decides:
// keep the press until the configurations are read, load the configuration's model first, start
// it, or end with a notice. A model that failed before is loaded again only on a press, so an
// answer that fails again ends instead of looping.
func (a *App) decideTitleAction(p *project, action titleAction, trigger string) {
	facts := core.TitleActionFacts{
		Action: "run", Trigger: trigger,
		CurrentFileChosen: p.runConfigs.currentFile, Settled: p.runConfigsSettled(),
	}
	if action == titleActionDebug {
		facts.Action = "debug"
	}
	configuration := p.titleConfiguration()
	var reference core.RunProviderReference
	index := -1
	if configuration != nil {
		facts.Configuration = &core.TitleConfiguration{Kind: "unsupported"}
		var ok bool
		if reference, ok = configuration.BuildReference(); ok {
			index = p.buildInstanceIndex(reference)
			facts.Configuration = p.titleConfigurationFacts(index, reference)
		}
	}
	ctx, cancel := context.WithTimeout(p.ctx, kernelCallTimeout)
	decision, err := a.kernel.DecideTitleAction(ctx, facts)
	cancel()
	p.runConfigs.pending = titleActionNone
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("title_run", err))
		a.notifyError(err.Error())
		return
	}
	switch decision {
	case "wait":
		p.runConfigs.pending = action
	case "loadModel":
		p.runConfigs.pending = action
		a.loadBuildModel(p, index)
	case "currentFile":
		a.performCurrentFileAction(p, action)
	case "unsupported":
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.title.configurationNotStartable", map[string]string{"name": configuration.Name}))
	case "targetMissing":
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("title_run", errors.New("the configuration's build instance was not detected")))
		a.notifyError(a.text.Build.TargetMissing)
	case "modelFailed":
		failure := p.build.instances[index].modelError
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("title_run", errors.New(failure)))
		a.notifyError(failure)
	case "run":
		if _, err := a.startRunConfiguration(p, configuration.ID); errors.Is(err, errBuildBusy) {
			a.notifyInfo(i18n.Shared(a.language(), "desktop.title.runBusy"))
		}
	case "debug":
		a.debugProviderTarget(p, index, reference.ProjectID, reference.TargetID, reference.Run)
	case "notDebuggable":
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.title.notDebuggable", map[string]string{"name": configuration.Name}))
	}
}

// titleConfigurationFacts describes a build provider configuration for Core's decision: whether
// its instance was detected, and whether that instance's model is loaded, failed its last load,
// or declares a debug adapter for the configuration's run.
func (p *project) titleConfigurationFacts(index int, reference core.RunProviderReference) *core.TitleConfiguration {
	if index < 0 {
		return &core.TitleConfiguration{Kind: "instanceMissing"}
	}
	instance := &p.build.instances[index]
	if !instance.modelLoaded {
		failed := instance.modelError != ""
		return &core.TitleConfiguration{Kind: "modelNotLoaded", Failed: &failed}
	}
	run, ok := buildRunDeclaration(instance.System, reference.Run)
	debuggable := ok && run.DebugAdapter != ""
	return &core.TitleConfiguration{Kind: "modelLoaded", Debuggable: &debuggable}
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
