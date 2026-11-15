package workbench

import "github.com/vivaui/viva/ui"

// overlayHost is the state of what the window shows over the workbench besides the dialogs'
// own: the toasts a notice raises.
type overlayHost struct {
	toaster ui.Toaster
}
