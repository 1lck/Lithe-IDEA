package workbench

import "github.com/vivaui/viva/gfx"

// The identity tree of the client's page. The page names its elements by their place; the
// few text fields that a dialog or a panel focuses from its model carry an identity of their
// own (ui.TextFieldID), declared next to their code in this tree.
var (
	tree = gfx.Tree{}

	// shellPage is the workbench of an open project.
	shellPage = tree.Feature("workbench")
)
