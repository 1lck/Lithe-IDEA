package workbench

import (
	"context"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// Note: 同一语言只由一个已启用插件提供语言服务器，见 .agents/notes/implemented/architecture/2026-11-14-one-enabled-plugin-per-language-server.md

// displacement is what enabling or installing plugin enabledID turned off: Core
// keeps one enabled plugin per language, so every plugin in displaced, which
// served one of the same languages, is now recorded disabled. names holds the
// display names the notice shows, by plugin ID and by language ID.
type displacement struct {
	enabledID string
	displaced []pluginmanager.Displaced
	plugins   map[string]string
	languages map[string]string
	// err is why the names could not be read; the notice then shows IDs.
	err error
}

// describeDisplacement reads the names of the plugins and languages in displaced.
// It reads the installed manifests, so it runs off the window thread, and only
// when something was displaced.
func (a *App) describeDisplacement(ctx context.Context, enabledID string, displaced []pluginmanager.Displaced) displacement {
	d := displacement{enabledID: enabledID, displaced: displaced}
	if len(displaced) == 0 {
		return d
	}
	entries, err := a.plugins.CurrentInstalled(ctx)
	d.err = err
	d.plugins = make(map[string]string, len(entries))
	d.languages = make(map[string]string)
	for _, item := range installedPluginFacts(entries, nil) {
		d.plugins[item.ID] = item.Name
		for _, capability := range item.Capabilities {
			if capability.Kind == settingswindow.CapabilityLanguageServer && capability.Title != "" {
				d.languages[capability.ID] = capability.Title
			}
		}
	}
	return d
}

// stopDisplaced stops the programs of every displaced plugin and tells the user
// which plugin was turned off and why. The choice is already recorded, so no start
// picks the plugin again; once a plugin stopped, the enabled plugin's server starts
// for the documents of the shared languages that are open.
func (a *App) stopDisplaced(d displacement) {
	if a.plugins == nil || len(d.displaced) == 0 {
		return
	}
	if d.err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_list", d.err))
	}
	p := a.project
	for _, item := range d.displaced {
		id, languages := item.PluginID, item.LanguageIDs
		server := a.detachPluginServer(id)
		a.background(nil, pluginServerStopTimeout, func(ctx context.Context) func(*App) {
			err := a.plugins.StopDisplaced(ctx, id, server)
			return func(a *App) {
				if err != nil {
					a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_displace", err))
				}
				if a.project != p || p == nil {
					return
				}
				for _, languageID := range languages {
					if p.hasDocumentOf(languageID) {
						a.startPluginServer(languageID)
					}
				}
			}
		})
		a.notifyInfo(i18n.SharedFormat(a.language(), "desktop.marketplace.languageServerDisplaced", map[string]string{
			"disabled":  displayName(d.plugins, id),
			"enabled":   displayName(d.plugins, d.enabledID),
			"languages": languageNames(d.languages, languages),
		}))
	}
}

// hasDocumentOf reports whether a document of languageID is open in the project.
func (p *project) hasDocumentOf(languageID string) bool {
	for _, d := range p.docs.list {
		if d.languageID == languageID {
			return true
		}
	}
	return false
}

// displayName is the name in names, or id when the manifest gave none.
func displayName(names map[string]string, id string) string {
	if name := names[id]; name != "" {
		return name
	}
	return id
}

// languageNames joins the display names of languageIDs, in the order given.
func languageNames(names map[string]string, languageIDs []string) string {
	shown := make([]string, len(languageIDs))
	for i, id := range languageIDs {
		shown[i] = displayName(names, id)
	}
	return strings.Join(shown, ", ")
}
