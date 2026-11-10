package workbench

import "github.com/vivaui/viva/ui"

// runPanels is the view state of the Run, Tests and Debug tool windows of one project. The
// model they show (build, tests, debug) stays in the project, so this holds only what the
// user is doing to them: which list is scrolled where and which popup is open.
type runPanels struct {
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

