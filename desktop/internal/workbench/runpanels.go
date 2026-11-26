package workbench

import (
	"github.com/vivaui/viva/ui"
	"github.com/vivaui/viva/ui/textview"
)

// runPanels is the view state of the Run, Tests and Debug tool windows of one project. The
// model they show (build, tests, debug) stays in the project, so this holds only what the
// user is doing to them: which list is scrolled where and which popup is open.
type runPanels struct {
	// buildOpen holds the groups and nodes of the build tree the user opened or closed, by
	// buildOpenKey; one not in it shows as buildFold says for its instance, else as it does by
	// default (build_tree.go). buildFold is what opening or closing every node left each
	// instance as, by instance ID. buildFilter is the text the tree's filter field edits in
	// place, and buildRows the rows the tree showed last, a buffer each frame reuses.
	buildOpen   map[string]buildOpenState
	buildFold   map[string]bool
	buildFilter string
	buildRows   []buildRow
	// choices is the Build window's tree of every build system. runSplit is the Run window's
	// divider between its execution tree and the selected execution's console; each
	// execution keeps its own console (runEntry.console).
	choices  ui.ListState
	runSplit ui.SplitterState
	// runExpanded records which execution nodes in the Run tree the user explicitly expanded
	// or collapsed, by runEntry.id. Absent entries default to collapsed unless running with
	// live listening ports. runGroupLast remembers the last viewed session per plugin group.
	runExpanded  map[string]bool
	runGroupLast map[string]string
	// testResults is the grouped result list, testOutput the console of a run that
	// failed before reporting results.
	testResults ui.ListState
	testOutput  textview.View
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
