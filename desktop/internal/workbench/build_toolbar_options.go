package workbench

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginicons"
	"github.com/vivaui/viva/ui"
)

// A boolean build option a plugin declares with presentation "toolbar" is a toggle on the Build
// window's toolbar, as IDEA's Maven tool window has Toggle Offline Mode and Toggle 'Skip Tests'
// Mode: it shows the plugin's icon, stays pressed while the option is on, and a click stores the
// other value through the same Core edit as the Build options dialog, which then detects the
// instances again so the next run uses it. The toggles are the selected instance's.

// buildToolbarOption is one toolbar toggle a build system declares.
type buildToolbarOption struct {
	id, title string
	icon      pluginicons.Declaration
}

// buildToolbarOptions are the toolbar toggles the build system buildSystemID of manifest
// declares, in declaration order. Only a boolean option with an icon can be one.
func buildToolbarOptions(manifest json.RawMessage, buildSystemID string) []buildToolbarOption {
	var declared struct {
		BuildSystems []struct {
			ID      string `json:"id"`
			Options []struct {
				ID           string `json:"id"`
				DisplayName  string `json:"displayName"`
				Kind         string `json:"kind"`
				Presentation string `json:"presentation"`
				Icon         *struct {
					Path     string `json:"path"`
					DarkPath string `json:"darkPath"`
					Mode     string `json:"mode"`
				} `json:"icon"`
			} `json:"options"`
		} `json:"buildSystems"`
	}
	if json.Unmarshal(manifest, &declared) != nil {
		return nil
	}
	var options []buildToolbarOption
	for _, system := range declared.BuildSystems {
		if system.ID != buildSystemID {
			continue
		}
		for _, option := range system.Options {
			if option.Presentation != "toolbar" || option.Kind != "boolean" || option.Icon == nil || option.Icon.Path == "" {
				continue
			}
			title := option.DisplayName
			if title == "" {
				title = option.ID
			}
			options = append(options, buildToolbarOption{id: option.ID, title: title, icon: pluginicons.Declaration{
				Path: option.Icon.Path, DarkPath: option.Icon.DarkPath, Mode: option.Icon.Mode,
			}})
		}
	}
	return options
}

// optionOn reports whether the boolean option id of instance is on in its stored options.
func (instance *buildInstance) optionOn(id string) bool {
	var on bool
	return json.Unmarshal(instance.Options[id], &on) == nil && on
}

// buildToolbarToggles declares the toolbar toggles of the selected instance. An icon not read yet
// is read off the window thread once; until then, or when it cannot be read, the toggle shows a
// generic icon.
func (a *App) buildToolbarToggles(c ui.C, p *project) {
	instance := p.selectedBuildInstance()
	if instance == nil {
		return
	}
	b := &p.build
	busy := b.optionSaving || b.loading || b.operation != nil
	for index, option := range buildToolbarOptions(instance.Manifest, instance.BuildSystemID) {
		icon := icons.Settings
		if found, ok := a.pluginIcons.Lookup(instance.PluginID, option.icon); ok {
			icon = found.For(a.colors.Dark)
		} else {
			a.readBuildToolbarIcon(p, instance.PluginID, instance.PackageDirectory, option.icon)
		}
		on := instance.optionOn(option.id)
		state := i18n.Shared(a.language(), "desktop.build.toggleOff")
		if on {
			state = i18n.Shared(a.language(), "desktop.build.toggleOn")
		}
		label := i18n.SharedFormat(a.language(), "desktop.build.toggleOption", map[string]string{"option": option.title, "state": state})
		if _, hit := a.toolIconButton(c.KeyInt(index), label, icon, on, busy); hit {
			instanceID, optionID := instance.ID, option.id
			c.After(func() {
				a.performed("build.toolbarOption.toggle", surfaceButton)
				a.toggleBuildToolbarOption(p, instanceID, optionID)
			})
		}
	}
}

// readBuildToolbarIcon reads the package icon of a toolbar toggle off the window thread, once per
// plugin and icon; a broken icon is logged and keeps the generic one.
func (a *App) readBuildToolbarIcon(p *project, pluginID, directory string, icon pluginicons.Declaration) {
	key := pluginID + "\x00" + icon.Path + "\x00" + icon.DarkPath
	if directory == "" || p.build.toolbarIconsRead[key] {
		return
	}
	if p.build.toolbarIconsRead == nil {
		p.build.toolbarIconsRead = map[string]bool{}
	}
	p.build.toolbarIconsRead[key] = true
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		if err := a.pluginIcons.Read(pluginID, directory, icon); err != nil {
			a.backgroundFailedIn(ctx, "plugin_icon", fmt.Errorf("%s: %w", pluginID, err))
		}
		return nil
	})
}

// toggleBuildToolbarOption stores the other value of the boolean option optionID of the instance
// instanceID in the project's local options, as the Build options dialog does; the save detects
// the instances again, so the model, tasks and runs use it.
func (a *App) toggleBuildToolbarOption(p *project, instanceID, optionID string) {
	b := &p.build
	instance := p.buildInstanceByID(instanceID)
	if instance == nil || b.optionSaving || b.loading || b.operation != nil {
		return
	}
	b.optionSaving = true
	change := buildOptionChange{optionID: optionID, value: !instance.optionOn(optionID)}
	a.saveBuildOptionChanges(p, instance, []buildOptionChange{change}, nil, func(_ json.RawMessage, err error) {
		p.build.optionSaving = false
		if err != nil {
			a.operationFailed("build_toolbar_option", err)
			a.notifyError(a.launchFailureText(err))
		}
	})
}
