package workbench

import "github.com/vivaui/viva/ui"

// The identity tree of the client. Each screen is a feature; each file declares the
// identities of the controls it paints next to its code, in its own var block, so
// the shared names below are only the ones more than one file uses.
var (
	tree = ui.Tree{}

	// welcomePage is the start screen, shown while no project is open.
	welcomePage = tree.Feature("welcome")
	// shellPage is the workbench of an open project.
	shellPage = tree.Feature("workbench")

	// chromeButtons identifies the rearrangeable buttons: chromeButtons.At(i) is
	// catalog[i], wherever it currently sits.
	chromeButtons = tree.Sub(shellPage, tree.Name("chrome"))
	// panelHide identifies the hide button of the tool window in each panel slot:
	// panelHide.At(int(slot)).
	panelHide = tree.Sub(shellPage, tree.Name("panel-hide"))

	// noticeDismiss closes the notice banner on either screen.
	noticeDismiss = tree.ID(welcomePage, "notice-dismiss")
)
