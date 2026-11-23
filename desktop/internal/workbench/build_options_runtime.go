package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/ui"
)

// A build system's options dialog also shows what its options do not: the build tool and the runtimes it
// runs on, as they resolve now (IntelliJ IDEA shows the Maven home and the runner's JRE the same way). A
// build runs on the runtime its invocation names, and a launch prepared by the plugin names the same
// toolchain, so the project has one runtime for both: the section says so and leads to the Toolchains page
// where it is chosen, instead of an option that would change the build's runtime alone.
//
// A plugin update may stop declaring an option the user had saved. Detection then names it in the
// instance's droppedOptions and ignores its value. The dialog lists those options with the value saved, so
// the user can move the value where it now belongs, and removes this machine's values on request; a value
// in the project's shared file is only pointed at, since this client never rewrites that file.

// buildRuntimeView is one row of the Runtime section: the build tool or a runtime it runs on, with the
// executable it resolves to and where that came from, or why none was found.
type buildRuntimeView struct {
	name       string
	executable string
	source     buildExecutionSource
	failure    string
}

// buildDroppedOption is a saved option the build system no longer declares: the value this machine saved
// for it and the value saved in the project's shared file, either of which may be absent.
type buildDroppedOption struct {
	id          string
	local, team string
	hasLocal    bool
	hasTeam     bool
}

// droppedBuildOptionIDs are the instance's dropped options that its manifest no longer declares. A
// declared option whose value was refused is in droppedOptions too, but its field is in the dialog, where
// the user sets it again.
func droppedBuildOptionIDs(instance *buildInstance, fields []runOptionField) []string {
	var ids []string
	for _, id := range instance.DroppedOptions {
		if !slices.ContainsFunc(fields, func(field runOptionField) bool { return field.id == id }) {
			ids = append(ids, id)
		}
	}
	return ids
}

// readBuildInstanceDetails fills the dialog's Runtime section and the values of its dropped options in the
// background. Both are read for this opening of the dialog only; nothing is stored.
func (a *App) readBuildInstanceDetails(p *project, instance buildInstance, dropped []string) {
	session, root, messages := p.build.options.session, p.root, a.text.Build
	tool := buildSystemName(&instance)
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		var values []buildDroppedOption
		var readErr error
		if len(dropped) > 0 {
			values, readErr = a.readDroppedBuildOptions(ctx, root, instance, dropped)
		}
		runtimes, planErr := a.resolveBuildRuntimes(ctx, p, instance, tool, messages)
		if readErr != nil {
			a.backgroundFailedIn(ctx, "build_options_dropped", readErr)
		}
		if planErr != nil {
			a.backgroundFailedIn(ctx, "build_options_runtime", planErr)
		}
		return func(a *App) {
			e := &p.build.options
			if !e.open || e.session != session {
				return
			}
			if readErr == nil {
				e.dropped = values
			}
			e.runtimes, e.runtimesLoaded = runtimes, true
			if planErr != nil {
				e.runtimes = []buildRuntimeView{{name: tool, failure: planErr.Error()}}
			}
		}
	})
}

// resolveBuildRuntimes is the build tool, named tool, and each runtime it runs on, resolved through the
// candidates Core orders for the instance, the same lookup a build makes but without its version probes.
func (a *App) resolveBuildRuntimes(ctx context.Context, p *project, instance buildInstance, tool string, messages i18n.BuildMessages) ([]buildRuntimeView, error) {
	settings, err := a.loadPluginPreferenceSources(ctx, instance.Manifest, p.root)
	if err != nil {
		return nil, err
	}
	invocation, err := a.kernel.PlanBuildInvocation(ctx, instance.Manifest, instance.BuildSystemID, core.BuildInvocationRequest{Root: instance.Root, Platform: buildPlatform(), Settings: settings.State.Settings})
	if err != nil {
		return nil, err
	}
	runtimes := make(map[string]buildExecution, len(invocation.RuntimeDependencies))
	views := make([]buildRuntimeView, 0, len(invocation.RuntimeDependencies)+1)
	resolve := func(name string, candidates []core.BuildExecutableCandidate, minimum string) (buildExecution, bool) {
		view := buildRuntimeView{name: name}
		resolved, err := a.resolveBuildCandidates(ctx, p, instance.Root, candidates, minimum, messages, runtimes)
		if err != nil {
			view.failure = err.Error()
		} else {
			view.executable, view.source = resolved.Executable, resolved.Source
		}
		views = append(views, view)
		return resolved, err == nil
	}
	for _, requirement := range invocation.RuntimeDependencies {
		name := requirement.DisplayName
		if name == "" {
			name = requirement.ID
		}
		if resolved, ok := resolve(name, requirement.Executables, requirement.MinimumVersion); ok {
			runtimes[requirement.ID] = resolved
		}
	}
	// The tool comes first in the section, as the thing the runtimes serve.
	resolve(tool, invocation.Executables, invocation.MinimumVersion)
	views = append(views[len(views)-1:], views[:len(views)-1]...)
	return views, nil
}

// readDroppedBuildOptions is the value each dropped option has in the local and the team document, as the
// instance's root reads it: the root's own value, else the build system's, else its instance default. An
// option that has neither is left out.
func (a *App) readDroppedBuildOptions(ctx context.Context, root string, instance buildInstance, ids []string) ([]buildDroppedOption, error) {
	docs, err := a.readBuildOptionDocuments(ctx, root)
	if err != nil {
		return nil, err
	}
	var local struct {
		Document json.RawMessage `json:"document"`
	}
	if err := json.Unmarshal(docs.local, &local); err != nil {
		return nil, err
	}
	var options []buildDroppedOption
	for _, id := range ids {
		option := buildDroppedOption{id: id}
		option.local, option.hasLocal = storedBuildOptionValue(local.Document, instance.BuildSystemID, instance.Root, id)
		option.team, option.hasTeam = storedBuildOptionValue(docs.team, instance.BuildSystemID, instance.Root, id)
		if option.hasLocal || option.hasTeam {
			options = append(options, option)
		}
	}
	return options, nil
}

// storedBuildOptionValue is the value document holds for option id of system at root, as text: a string as
// it is, anything else as compact JSON.
func storedBuildOptionValue(document json.RawMessage, system, root, id string) (string, bool) {
	var parsed struct {
		Systems map[string]struct {
			Options          map[string]json.RawMessage            `json:"options"`
			InstanceDefaults map[string]json.RawMessage            `json:"instanceDefaults"`
			Instances        map[string]map[string]json.RawMessage `json:"instances"`
		} `json:"systems"`
	}
	if len(document) == 0 || json.Unmarshal(document, &parsed) != nil {
		return "", false
	}
	entry, ok := parsed.Systems[system]
	if !ok {
		return "", false
	}
	for _, values := range []map[string]json.RawMessage{entry.Instances[root], entry.Options, entry.InstanceDefaults} {
		raw, ok := values[id]
		if !ok {
			continue
		}
		var text string
		if json.Unmarshal(raw, &text) == nil {
			return text, true
		}
		var compact bytes.Buffer
		if json.Compact(&compact, raw) != nil {
			return string(raw), true
		}
		return compact.String(), true
	}
	return "", false
}

// clearDroppedBuildOptions removes this machine's values of the dropped options, one Core edit each, then
// reads the documents again: an option whose value is also in the project's shared file stays listed.
func (a *App) clearDroppedBuildOptions(p *project) {
	e := &p.build.options
	instance := p.buildInstanceByID(e.instance)
	if !e.open || e.saving || instance == nil {
		return
	}
	var changes []buildOptionChange
	ids := make([]string, 0, len(e.dropped))
	for _, option := range e.dropped {
		ids = append(ids, option.id)
		if option.hasLocal {
			changes = append(changes, buildOptionChange{optionID: option.id})
		}
	}
	if len(changes) == 0 {
		return
	}
	e.saving, e.failure = true, ""
	session, target := e.session, *instance
	a.saveBuildOptionChanges(p, instance, changes, nil, func(_ json.RawMessage, err error) {
		e := &p.build.options
		if !e.open || e.session != session {
			return
		}
		e.saving = false
		if err != nil {
			e.failure = err.Error()
			return
		}
		a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
			values, err := a.readDroppedBuildOptions(ctx, p.root, target, ids)
			if err != nil {
				a.backgroundFailedIn(ctx, "build_options_dropped", err)
			}
			return func(a *App) {
				if e := &p.build.options; e.open && e.session == session && err == nil {
					e.dropped = values
				}
			}
		})
	})
}

// buildRuntimeSection declares the Runtime section of a build system's options dialog.
func (a *App) buildRuntimeSection(c ui.C, language i18n.Language, e *buildOptionsEditor) {
	if !e.runtimesLoaded || len(e.runtimes) == 0 {
		return
	}
	ui.Column(c.Part("runtime")).FillWidth().Gap(6).MarginTop(6).Children(func() {
		a.buildRuntimeRows(c, language, e)
	})
}

// buildRuntimeRows declares the Runtime section's heading, its rows and its help.
func (a *App) buildRuntimeRows(c ui.C, language i18n.Language, e *buildOptionsEditor) {
	ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
		a.buildOptionsHeading(c, i18n.Shared(language, "desktop.build.runtimeHeading"))
		ui.Spacer(c)
		if ui.Button(c.Part("toolchains"), i18n.Shared(language, "desktop.build.openToolchains")).Ghost().Small().Clicked() {
			c.After(func() { a.openSettingsPage(surfaceButton, settingsToolchainsPage) })
		}
	})
	for index, runtime := range e.runtimes {
		k := c.KeyInt(index)
		ui.Row(k).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, runtime.name).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Shrink(0).MaxWidth(120)
			if runtime.failure != "" {
				ui.Text(c, runtime.failure).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger).Ellipsis().Shrink(1).MinWidth(0)
				return
			}
			ui.Text(c, runtime.executable).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis().Shrink(1).MinWidth(0)
			ui.Spacer(c)
			ui.Text(c, buildExecutionSourceLabel(language, runtime.source)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(0).MaxWidth(160)
		})
	}
	ui.Wrap(c, i18n.Shared(language, "desktop.build.runtimeHelp")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
}

// buildExecutionSourceLabel names where an executable was found: the toolchain's version and resolver
// layer, the environment variable, the system PATH, the plugin's setting or the project's wrapper.
func buildExecutionSourceLabel(language i18n.Language, source buildExecutionSource) string {
	switch source.Kind {
	case "toolchain":
		parts := []string{}
		if source.Version != "" {
			parts = append(parts, source.Version)
		}
		if source.Layer != "" {
			parts = append(parts, settingswindow.ToolchainLayerLabel(language, source.Layer))
		}
		return strings.Join(parts, " · ")
	case "environment":
		return i18n.SharedFormat(language, "desktop.build.sourceEnvironment", map[string]string{"variable": source.Variable})
	case "command":
		return i18n.Shared(language, "desktop.build.sourcePath")
	case "setting":
		return i18n.Shared(language, "desktop.build.sourceSetting")
	case "projectFile":
		return i18n.Shared(language, "desktop.build.sourceProjectFile")
	default:
		return ""
	}
}

// buildDroppedOptionsSection declares the notice of saved options the build system no longer declares.
func (a *App) buildDroppedOptionsSection(c ui.C, language i18n.Language, p *project, ready bool) {
	e := &p.build.options
	if len(e.dropped) == 0 {
		return
	}
	ui.Column(c.Part("dropped")).FillWidth().Gap(6).MarginTop(6).Children(func() {
		a.buildDroppedOptionRows(c, language, p, ready)
	})
}

// buildDroppedOptionRows declares the notice, one row a dropped option, and Clear when this machine
// holds a value.
func (a *App) buildDroppedOptionRows(c ui.C, language i18n.Language, p *project, ready bool) {
	e := &p.build.options
	ui.Row(c).FillWidth().Items(ui.Start).Gap(6).Children(func() {
		ui.Icon(c, icons.Info).Size(14, 14).Color(a.colors.Warning).Shrink(0)
		ui.Wrap(c, i18n.Shared(language, "desktop.build.droppedOptions")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Shrink(1).MinWidth(0)
	})
	local := false
	for index, option := range e.dropped {
		k := c.KeyInt(index)
		value := option.local
		if !option.hasLocal {
			value = option.team
		}
		ui.Column(k).FillWidth().Gap(2).Children(func() {
			ui.Text(c, option.id+" = "+value).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis()
			if option.hasTeam {
				ui.Text(c, i18n.SharedFormat(language, "desktop.build.droppedInTeam", map[string]string{"file": buildTeamOptionsFile})).
					FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis()
			}
		})
		local = local || option.hasLocal
	}
	if !local {
		return
	}
	ui.Row(c).FillWidth().Children(func() {
		ui.Spacer(c)
		if ui.Button(c.Part("clear-dropped"), i18n.Shared(language, "desktop.build.clearDropped")).Outline().Small().Disabled(!ready).Clicked() {
			c.After(func() {
				a.performed("build.options.clearDropped", surfaceButton)
				a.clearDroppedBuildOptions(p)
			})
		}
	})
}
