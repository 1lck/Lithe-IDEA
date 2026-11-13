package workbench

import "github.com/vivaui/viva/ui"

// runPanels is the view state of the Run, Tests and Debug tool windows of one project. The
// model they show (build, tests, debug) stays in the project, so this holds only what the
// user is doing to them: which list is scrolled where and which popup is open.
type runPanels struct {
	// buildOpen holds the groups and sections of the build tree the user opened or closed, by
	// buildOpenKey; one not in it shows as it does by default (build_tree.go). buildFilter is
	// the text the tree's filter field edits in place.
	buildOpen   map[string]bool
	buildFilter string
	// choices is the Build window's tree of every build system, and output the Run window's
	// console of what the Build window runs.
	choices, output ui.ListState
	// testResults is the grouped result list, testOutput the console of a run that
	// failed before reporting results.
	testResults, testOutput ui.ListState
	// breakpoints, frames and console are the Debug tool window's lists, debugSplit the
	// divider between its call stack and its variables, and consoleSeen the output additions
	// the console has shown (see debugSessionView.outputCount).
	breakpoints, frames, console ui.ListState
	debugSplit                   ui.SplitterState
	consoleSeen                  int
	// remoteOpen shows the confirmation of an attach to a non-local endpoint, breakpointsOpen
	// the dialog of every breakpoint, and debugMoreOpen the Debug toolbar's More menu.
	remoteOpen, breakpointsOpen, debugMoreOpen bool
}
