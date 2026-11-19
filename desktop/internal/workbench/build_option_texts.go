package workbench

import (
	"context"
	"encoding/json"
	"slices"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

// Build options are named in the plugin's manifest, in the plugin's language. Before detection the build
// plugins' manifests go through Core's build.localizeOptions with the interface language: Core names the
// translation files each package may hold (l10n/<language>.json), the host reads them from the installed
// package, which stays read-only, and Core returns the manifests with the option text of their buildOptions
// section translated. The instances keep those manifests, so the option dialogs, the run configuration
// editor, the toolbar toggles and the tree's option nodes all show the translation; IDs, values and arguments
// are unchanged, so plans are the same. A file that cannot be read or that Core refuses leaves the
// manifest's wording.

// buildOptionTextCache keeps the translation files read for each plugin package and language, so a detection
// after the first reads no file and asks Core once. A package is identified by its directory and version: an
// update installs a new one.
type buildOptionTextCache struct {
	mu    sync.Mutex
	files map[string]map[string]string
}

func buildOptionTextKey(plugin pluginservice.BuildPlugin, language string) string {
	return plugin.PluginID + "\x00" + plugin.Version + "\x00" + plugin.Directory + "\x00" + language
}

func (c *buildOptionTextCache) get(key string) (map[string]string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	files, ok := c.files[key]
	return files, ok
}

func (c *buildOptionTextCache) put(key string, files map[string]string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.files == nil {
		c.files = map[string]map[string]string{}
	}
	c.files[key] = files
}

// localizeBuildManifests is the manifests of plugins, in order, with their option text in language. It runs
// off the window thread. When Core cannot answer, the manifests are used as installed and the failure is
// logged: the options then show the plugin's own wording.
func (a *App) localizeBuildManifests(ctx context.Context, kernel Kernel, language string, plugins []pluginservice.BuildPlugin) []json.RawMessage {
	manifests := make([]json.RawMessage, len(plugins))
	request := make([]core.BuildOptionPlugin, len(plugins))
	for index, plugin := range plugins {
		manifests[index] = plugin.Manifest
		request[index].Manifest = plugin.Manifest
		if files, ok := a.buildOptionTexts.get(buildOptionTextKey(plugin, language)); ok {
			request[index].Localizations = files
		}
	}
	if len(plugins) == 0 || language == "" {
		return manifests
	}
	texts, err := kernel.LocalizeBuildOptions(ctx, language, request)
	if err != nil {
		a.backgroundFailedIn(ctx, "build_option_texts", err)
		return manifests
	}
	read := false
	for index, plugin := range plugins {
		report := slices.IndexFunc(texts.Localizations, func(report core.RunTypeLocalization) bool { return report.PluginID == plugin.PluginID })
		if report < 0 || !texts.Localizations[report].ReadRequired {
			continue
		}
		files, unreadable, err := pluginsettings.ReadTranslations(ctx, plugin.Directory, texts.Localizations[report].PluginSettingsLocalization)
		if err != nil {
			a.backgroundFailedIn(ctx, "build_option_texts", err)
			return manifests
		}
		if len(unreadable) > 0 {
			a.operationRejectedIn(ctx, "build_option_texts", "localization_unreadable")
		}
		// A read that found no file is an empty map, so the next detection does not read again.
		a.buildOptionTexts.put(buildOptionTextKey(plugin, language), files)
		request[index].Localizations = files
		read = true
	}
	if read {
		if texts, err = kernel.LocalizeBuildOptions(ctx, language, request); err != nil {
			a.backgroundFailedIn(ctx, "build_option_texts", err)
			return manifests
		}
	}
	if slices.ContainsFunc(texts.Localizations, func(report core.RunTypeLocalization) bool { return len(report.Rejected) > 0 }) {
		a.operationRejectedIn(ctx, "build_option_texts", "invalid_localization")
	}
	return texts.Manifests
}
