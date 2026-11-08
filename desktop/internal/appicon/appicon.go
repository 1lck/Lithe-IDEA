// Package appicon is the Lithe icon of the client's windows. A client started outside an .app
// bundle, as make run starts it, has no icon of its own, and macOS shows a generic one in the
// Dock; giving every window this icon shows Lithe's instead. A packaged client has the same
// image in its bundle.
package appicon

import (
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/assets"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/app/iconpng"
)

// windowIcon decodes once because every native window uses the same image.
var windowIcon = sync.OnceValue(func() app.WindowIcon {
	icon, err := iconpng.Decode(assets.Icon)
	if err != nil {
		panic("appicon: could not decode the embedded desktop icon: " + err.Error())
	}
	return icon
})

// Window returns the decoded application icon shared by every native window.
func Window() app.WindowIcon { return windowIcon() }
