package workbench

import (
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/bundledfont"
	"github.com/vivaui/viva/app"
)

// bundled is the set of fonts the packaged build carries, registered once per process for this
// process only. A build without them (development, tests, other platforms) has an empty set and
// the system's fonts apply.
var bundled = sync.OnceValue(func() bundledfont.Set {
	return bundledfont.Register(bundledfont.Files(), app.RegisterFont)
})

// bundledInterfaceFamily applies the bundled interface font when there is one. It runs once,
// before the first paint, because a family looked up before it is registered is drawn in the
// platform's stand-in.
func bundledInterfaceFamily() {
	if family := bundled().UI; family != "" {
		app.SetInterfaceFontFamily(family)
	}
}
