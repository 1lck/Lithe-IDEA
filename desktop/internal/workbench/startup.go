package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/ai"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// DesktopOptions assembles the production Core consumers. Tests may still use
// explicit Options to isolate a surface, but the executable shares one Core
// client between application, logging, plugin and AI adapters.
func DesktopOptions(client *core.Client, preferences *store.Store, version string) Options {
	return Options{Kernel: client, PluginKernel: client, Store: preferences, LogKernel: client, Version: version, AIKernel: ai.NewClient(client)}
}
