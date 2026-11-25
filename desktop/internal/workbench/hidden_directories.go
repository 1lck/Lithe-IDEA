package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// This file hands Core the folder names the enabled plugins hide (workspace.configureVisibility).
// Core hides only its own folders, such as .git, by itself; a build system's output and cache
// folders and a VCS's metadata folder are hidden because the plugin providing it says so. Core
// keeps one list for the process, which every tree listing, search, file event and local history
// check obeys, so the list is sent again with the plugin languages: as a workbench starts and
// after a plugin is installed, enabled, disabled or removed. A changed list re-lists the folders
// every tab's tree shows, and its names take the excluded-folder icon.
//
// Note: 隐藏目录由插件声明的决策见 .agents/notes/implemented/architecture/2026-11-16-plugin-declared-hidden-directories.md

// visibilityKernel is the part of Core the hidden folders use.
type visibilityKernel interface {
	ConfigureVisibility(ctx context.Context, manifests []json.RawMessage) (core.VisibilityConfiguration, error)
}

// hiddenDirectories is what configureVisibility did: the names Core now hides, valid when
// answered, and every failure on the way, which may come with an answer for the plugins
// that could be read.
type hiddenDirectories struct {
	names    []string
	answered bool
	err      error
}

// configureVisibility sends Core the manifests of the enabled plugins that can declare hidden
// folders: those with build systems, whose layouts name them, and those with VCS providers,
// whose directory markers do. vcs is read from the same snapshot as the tool windows,
// whose failures are reported there. A plugin whose manifest could not be read hides nothing,
// as its build system is not detected either. This blocks on Core; call it from
// a background goroutine.
func (a *App) configureVisibility(ctx context.Context, snapshot pluginservice.InstalledSnapshot, vcs []pluginservice.VcsPlugin) hiddenDirectories {
	kernel, ok := a.kernel.(visibilityKernel)
	if !ok {
		return hiddenDirectories{}
	}
	builds, readErr := snapshot.BuildPlugins()
	var manifests []json.RawMessage
	sent := make(map[string]bool, len(builds)+len(vcs))
	add := func(pluginID string, manifest json.RawMessage) {
		// A plugin with both build systems and VCS providers is sent once.
		if !sent[pluginID] {
			sent[pluginID] = true
			manifests = append(manifests, manifest)
		}
	}
	for _, plugin := range builds {
		add(plugin.PluginID, plugin.Manifest)
	}
	for _, plugin := range vcs {
		add(plugin.PluginID, plugin.Manifest)
	}
	configuration, err := kernel.ConfigureVisibility(ctx, manifests)
	if err != nil {
		return hiddenDirectories{err: errors.Join(readErr, err)}
	}
	if len(configuration.Rejected) > 0 {
		readErr = errors.Join(readErr, fmt.Errorf("%d plugin manifests were rejected", len(configuration.Rejected)))
	}
	return hiddenDirectories{names: configuration.HiddenDirectoryNames, answered: true, err: readErr}
}

// applyHiddenDirectories shows what configureVisibility did. When Core took a new list, the
// tree of every open tab lists the folders it shows again, keeping what is open and selected,
// and a listing still in flight under the old list is dropped for the new one. The host watch of
// every remote workspace starts again to leave out the new names as they are written, which the
// host compares by case. The list is the same for every tab, so the tabs reloading after one
// plugin change find it unchanged after the first and list nothing again.
func (a *App) applyHiddenDirectories(hidden hiddenDirectories) {
	if hidden.err != nil {
		a.backgroundFailed("workspace_visibility", hidden.err)
	}
	if !hidden.answered {
		return
	}
	excludes := setRemoteWatchExcludes(hidden.names)
	icons := fileicons.SetHiddenDirectoryNames(hidden.names)
	for _, tab := range a.openTabs() {
		p := tab.project
		if p == nil {
			continue
		}
		if excludes {
			tab.restartRemoteWatch(p)
		}
		if icons && p.tree.root != nil && p.tree.failed == "" {
			tab.resyncTreeListings(p)
		}
	}
}
