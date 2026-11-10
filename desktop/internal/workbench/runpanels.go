package workbench

import "github.com/vivaui/viva/ui"

// runPanels is the page state of the Run, Tests and Debug tool windows of one
// project. Each tool window is a Page of its own, drawn into the Frame slot of the
// tool window area; the model they show (build, tests, debug) stays in the
// project, so the pages hold only what the user is doing to them: which list is
// scrolled where and which popup is open. A page is made when its tool window is
// first shown and closed with the project, which ends the work it declared.
type runPanels struct {
	build, tests, debug *ui.Page

	// instance is the build system tab the Run tool window shows, kept in step with
	// the project's selected instance.
	instance int
	// choices is the list of projects, targets and tasks of the selected build
	// system, and output the console under it.
	choices, output ui.ListState
	// testResults is the grouped result list, testOutput the console of a run that
	// failed before reporting results.
	testResults, testOutput ui.ListState
	// breakpoints and frames are the Debug tool window's lists.
	breakpoints, frames ui.ListState
	// remoteOpen shows the confirmation of an attach to a non-local endpoint.
	remoteOpen bool
}

// close ends the pages and with them the effects they declared.
func (r *runPanels) close() {
	for _, page := range []**ui.Page{&r.build, &r.tests, &r.debug} {
		if *page != nil {
			(*page).Close()
			*page = nil
		}
	}
}

// buildPage, testsPage and debugPage make the tool window's page on first use.
func (a *App) buildPage(p *project) *ui.Page {
	if p.panels.build == nil {
		p.panels.build = a.newHostedPage("run-panel")
	}
	return p.panels.build
}

func (a *App) testsPage(p *project) *ui.Page {
	if p.panels.tests == nil {
		p.panels.tests = a.newHostedPage("tests-panel")
	}
	return p.panels.tests
}

func (a *App) debugPage(p *project) *ui.Page {
	if p.panels.debug == nil {
		p.panels.debug = a.newHostedPage("debug-panel")
	}
	return p.panels.debug
}
