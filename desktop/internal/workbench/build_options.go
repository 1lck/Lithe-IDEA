package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Build options are stored in two documents. The team document is .lithe/build/options.json in the project,
// read only here and never rewritten by this client. The local document is this machine's own preferences for
// the project; it is kept in the application's data store, never in the project or in the application bundle.
// Core checks the two against each other (build.resolveStoredOptions), applies a change to the local document
// (build.editStoredOption), and detection then reads the merged values back into each instance. The
// documents also hold the project's ignored paths, the directories detection does not enter: Core picks the
// local list, else the team's, else its default of every dot-named directory (build.resolveStoredOptions),
// and replaces or removes the local list (build.editIgnoredPaths).

const buildTeamOptionsFile = buildprefs.TeamFile
const buildLocalOptionsFile = buildprefs.LocalFile

type buildOptionDocuments struct {
	team, local json.RawMessage
}

func (a *App) readBuildOptionDocuments(ctx context.Context, root string) (buildOptionDocuments, error) {
	docs, err := buildprefs.Read(ctx, a.store, root)
	return buildOptionDocuments{team: docs.Team, local: docs.Local}, err
}

// detectBuildSystemsWithStoredOptions resolves the stored documents and detects the instances with the merged
// values. Only Core merges documents; this function maps the merged document onto the detection inputs.
func detectBuildSystemsWithStoredOptions(ctx context.Context, kernel Kernel, root string, manifests []json.RawMessage, docs buildOptionDocuments) (core.BuildDetection, error) {
	storage, err := kernel.ResolveStoredBuildOptions(ctx, docs.team, docs.local)
	if err != nil {
		return core.BuildDetection{}, err
	}
	inputs, err := buildDetectOptions(storage)
	if err != nil {
		return core.BuildDetection{}, err
	}
	return kernel.DetectBuildSystemsWithOptions(ctx, root, manifests, inputs)
}

// buildDetectOptions maps the merged document onto build.detect's inputs: each system's values, its instance
// defaults, the values of each root, the explicit empty selections and the ignored paths Core picked.
func buildDetectOptions(storage core.BuildStoredOptions) (core.BuildDetectOptions, error) {
	var document struct {
		Systems map[string]struct {
			Options          map[string]json.RawMessage            `json:"options"`
			InstanceDefaults map[string]json.RawMessage            `json:"instanceDefaults"`
			Instances        map[string]map[string]json.RawMessage `json:"instances"`
		} `json:"systems"`
	}
	if err := json.Unmarshal(storage.Document, &document); err != nil {
		return core.BuildDetectOptions{}, err
	}
	inputs := core.BuildDetectOptions{
		Options:          map[string]map[string]json.RawMessage{},
		InstanceOptions:  map[string]map[string]map[string]json.RawMessage{},
		InstanceDefaults: map[string]map[string]json.RawMessage{},
		EmptySelections:  storage.EmptySelections,
		IgnoredPaths:     storage.IgnoredPaths.Patterns,
	}
	for id, system := range document.Systems {
		if len(system.Options) > 0 {
			inputs.Options[id] = system.Options
		}
		if len(system.InstanceDefaults) > 0 {
			inputs.InstanceDefaults[id] = system.InstanceDefaults
		}
		if len(system.Instances) > 0 {
			inputs.InstanceOptions[id] = system.Instances
		}
	}
	return inputs, nil
}

// buildOptionsEditor is the Build options dialog. Its Detection section edits the project's ignored paths;
// opened from a build system it also edits the options that instance declares. instance is the ID of that
// instance, empty when the dialog was opened from the window's header. session tells this opening of the
// dialog from earlier ones, so an answer that arrives after it was closed or opened again is dropped.
type buildOptionsEditor struct {
	open     bool
	session  int
	instance string
	// name and root name the instance above its options.
	name, root string
	fields     []runOptionField
	ignored    buildIgnoredPathsEditor
	// loading keeps the initial read from replacing fields that the user has started to edit.
	loading bool
	saving  bool
	failure string
	// runtimes are the Runtime section's rows, read in the background when the dialog opens on an
	// instance; runtimesLoaded says they arrived.
	runtimes       []buildRuntimeView
	runtimesLoaded bool
	// dropped are the saved options the build system no longer declares, with their saved values.
	dropped []buildDroppedOption
}

// buildIgnoredPathsEditor is the ignored-paths field of the dialog, one pattern a line, filled with the list
// Core picked from the stored documents.
type buildIgnoredPathsEditor struct {
	// loaded says Core answered; until then the field cannot be edited.
	loaded bool
	text   string
	// shown is the list the field was filled with and source the layer it came from.
	shown  []string
	source string
	// inherit says the field shows the list that applies without the local one, after Restore Default;
	// saving it unchanged removes the local list.
	inherit bool
	// restoring says Core is working out what Restore Default shows.
	restoring bool
	// lines are the line numbers of the patterns last saved, so a refused pattern is named by its line.
	lines []int
}

// buildIgnoredPathsChange replaces the local ignored paths with patterns, which came from the given lines of
// the field, or removes the local list when inherit is set.
type buildIgnoredPathsChange struct {
	patterns []string
	lines    []int
	inherit  bool
}

// change is what saving the field writes: nothing while it shows the list it was filled with, except after
// Restore Default, when that list is the one without the local list, which saving removes.
func (g *buildIgnoredPathsEditor) change() *buildIgnoredPathsChange {
	if !g.loaded {
		return nil
	}
	patterns, lines := ignoredPathLines(g.text)
	if slices.Equal(patterns, g.shown) {
		if g.inherit {
			return &buildIgnoredPathsChange{inherit: true}
		}
		return nil
	}
	return &buildIgnoredPathsChange{patterns: patterns, lines: lines}
}

// ignoredPathLines splits the field into its patterns, one a line, skipping blank lines; lines holds the
// line number of each pattern. Core checks the patterns themselves, so a padded one is sent as typed.
func ignoredPathLines(text string) (patterns []string, lines []int) {
	for index, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		patterns, lines = append(patterns, line), append(lines, index+1)
	}
	return patterns, lines
}

// openBuildOptions opens the options dialog on the project's ignored paths and, when instance is not nil,
// on that instance's effective option values. The ignored paths are read from the stored documents now.
func (a *App) openBuildOptions(p *project, instance *buildInstance) {
	p.build.optionsSessions++
	editor := buildOptionsEditor{open: true, session: p.build.optionsSessions, loading: true}
	if instance != nil {
		editor.instance, editor.name, editor.root = instance.ID, buildSystemName(instance), buildRootDetail(instance)
		editor.fields = declaredOptionFields(instance.Manifest, instance.BuildSystemID, instance.Options)
	}
	p.build.options = editor
	a.readBuildIgnoredPaths(p, false)
	if instance != nil {
		a.readBuildInstanceDetails(p, *instance, droppedBuildOptionIDs(instance, editor.fields))
	}
}

// readBuildIgnoredPaths fills the ignored-paths field with the list Core picks from the stored documents or,
// for Restore Default, with the list that applies once the local one is removed. The documents are read in
// the background with Core's answer; neither stores anything.
func (a *App) readBuildIgnoredPaths(p *project, inherit bool) {
	e := &p.build.options
	e.ignored.restoring = inherit
	kernel, root, session := a.kernel, p.root, e.session
	var captured *buildInstance
	if !inherit && e.instance != "" {
		if instance := p.buildInstanceByID(e.instance); instance != nil {
			copyInstance := *instance
			captured = &copyInstance
		}
	}
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		var resolvedFields []runOptionField
		if captured != nil {
			resolved, err := resolveInstanceOptionFields(ctx, kernel, *captured, nil)
			if err != nil {
				a.backgroundFailedIn(ctx, "build_options_resolve", err)
			} else {
				resolvedFields = resolved
			}
		}
		ignored, err := func() (core.BuildIgnoredPaths, error) {
			docs, err := a.readBuildOptionDocuments(ctx, root)
			if err != nil {
				return core.BuildIgnoredPaths{}, err
			}
			if inherit {
				edit, err := kernel.EditBuildIgnoredPaths(ctx, core.BuildIgnoredPathsEditRequest{Document: docs.team, Local: docs.local, Inherit: true})
				return edit.IgnoredPaths, err
			}
			storage, err := kernel.ResolveStoredBuildOptions(ctx, docs.team, docs.local)
			return storage.IgnoredPaths, err
		}()
		return func(a *App) {
			e := &p.build.options
			if !e.open || e.session != session {
				return
			}
			e.loading = false
			e.ignored.restoring = false
			if len(resolvedFields) != 0 {
				e.fields = resolvedFields
			}
			if err != nil {
				e.failure = err.Error()
				return
			}
			e.failure = ""
			e.ignored = buildIgnoredPathsEditor{
				loaded: true, text: strings.Join(ignored.Patterns, "\n"),
				shown: ignored.Patterns, source: ignored.Source, inherit: inherit,
			}
		}
	})
}

// saveBuildOptions writes the changed fields of the dialog to the local document, one Core edit each, then
// detects the instances again so they show what was read back.
func (a *App) saveBuildOptions(p *project) {
	e := &p.build.options
	if !e.open || e.loading || e.saving || e.ignored.restoring {
		return
	}
	instance := p.buildInstanceByID(e.instance)
	var changes []buildOptionChange
	if instance != nil {
		for _, field := range e.fields {
			if selected, changed := changedSelectedChoices(field); changed {
				changes = append(changes, buildOptionChange{
					optionID: field.id, selectedChoices: selected, hasSelectedChoices: true,
				})
				continue
			}
			if value, changed := changedOptionValue(field); changed {
				changes = append(changes, buildOptionChange{optionID: field.id, value: value})
			}
		}
	}
	ignored := e.ignored.change()
	if len(changes) == 0 && ignored == nil {
		e.open = false
		return
	}
	if ignored != nil {
		e.ignored.lines = ignored.lines
	}
	e.saving, e.failure = true, ""
	session := e.session
	a.saveBuildOptionChanges(p, instance, changes, ignored, func(_ json.RawMessage, err error) {
		if e := &p.build.options; e.open && e.session == session {
			e.saving = false
			if err != nil {
				e.failure = buildOptionsFailure(a.language(), err, e.ignored.lines)
				return
			}
			e.open = false
		}
	})
}

// buildOptionsFailure is the message of a save that Core refused or the host could not store. A refused
// ignored path is named by its line in the field.
func buildOptionsFailure(language i18n.Language, err error, lines []int) string {
	var rejection *core.MarketplaceRejection
	if !errors.As(err, &rejection) || rejection.Code != "plugin.build.invalidIgnoredPath" {
		return err.Error()
	}
	index, found := strings.CutPrefix(rejection.Field, "ignoredPaths[")
	index, closed := strings.CutSuffix(index, "]")
	if at, err := strconv.Atoi(index); found && closed && err == nil && at >= 0 && at < len(lines) {
		return i18n.SharedFormat(language, "desktop.build.invalidIgnoredPath", map[string]string{"line": strconv.Itoa(lines[at])})
	}
	return i18n.Shared(language, "desktop.build.invalidIgnoredPaths")
}

// buildOptionChange is one option the user set; a nil value (without hasSelectedChoices) removes the local
// override, while hasSelectedChoices sends the checked choice list for Core to encode against defaults.
type buildOptionChange struct {
	optionID           string
	value              any
	selectedChoices    []string
	hasSelectedChoices bool
}

// saveBuildOptionChanges applies changes to one instance's options, and the ignored-path change when it is
// not nil, to the project's local document; instance may be nil when there are no option changes. Core checks
// each edit; the host writes the local document only when every edit succeeded, atomically, and then detects
// the instances again. done receives the outcome on the window thread: the option states Core read back from
// the edited documents, or why an edit was refused or could not be stored.
func (a *App) saveBuildOptionChanges(p *project, instance *buildInstance, changes []buildOptionChange, ignored *buildIgnoredPathsChange, done func(options json.RawMessage, err error)) {
	docs, err := a.readBuildOptionDocuments(context.Background(), p.root)
	if err != nil {
		done(nil, err)
		return
	}
	kernel, root := a.kernel, p.root
	var target buildInstance
	if instance != nil {
		target = *instance
	}
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		local := docs.local
		var options json.RawMessage
		for _, change := range changes {
			req := core.BuildOptionEditRequest{
				Document:           docs.team,
				Local:              local,
				Root:               target.Root,
				OptionID:           change.optionID,
				Value:              change.value,
				SelectedChoices:    change.selectedChoices,
				HasSelectedChoices: change.hasSelectedChoices,
			}
			if target.modelLoaded {
				req.ModelValues = target.Model.OptionValues
				req.ModelDefaults = target.Model.OptionDefaults
				req.ModelExcludePrefixes = target.Model.OptionExcludePrefixes
				req.ModelSelection = target.Model.OptionSelection
			}
			edit, err := kernel.EditStoredBuildOption(ctx, target.Manifest, target.BuildSystemID, req)
			if err != nil {
				return func(a *App) { done(nil, err) }
			}
			local, options = edit.Local, edit.Options
		}
		if ignored != nil {
			edit, err := kernel.EditBuildIgnoredPaths(ctx, core.BuildIgnoredPathsEditRequest{
				Document: docs.team, Local: local, Patterns: ignored.patterns, Inherit: ignored.inherit,
			})
			if err != nil {
				return func(a *App) { done(nil, err) }
			}
			local = edit.Local
		}
		return func(a *App) {
			if err := a.storeBuildLocalOptions(root, local); err != nil {
				done(nil, err)
				return
			}
			done(options, nil)
			p.reloadBuildDependencies()
			a.requestBuildReload(p)
		}
	})
}

// requestBuildReload detects the instances again now, or when the detection in progress ends, since a
// detection that started before the change read the old values.
func (a *App) requestBuildReload(p *project) {
	if p.build.loading {
		p.build.reloadPending = true
		return
	}
	a.loadBuildSystems(p)
}

// storeBuildLocalOptions writes the local document of a project into the data store.
func (a *App) storeBuildLocalOptions(root string, local json.RawMessage) error {
	all := map[string]json.RawMessage{}
	if _, err := a.store.Load(buildLocalOptionsFile, &all); err != nil {
		return err
	}
	if slices.Equal(local, buildprefs.EmptyLocal) {
		delete(all, root)
	} else {
		all[root] = local
	}
	return a.store.Save(buildLocalOptionsFile, all)
}

// buildInstanceByID finds a detected instance of the project by ID.
func (p *project) buildInstanceByID(id string) *buildInstance {
	for index := range p.build.instances {
		if p.build.instances[index].ID == id {
			return &p.build.instances[index]
		}
	}
	return nil
}

// buildOptionsDialog declares the Build options dialog while it is open: the Detection section, then the
// options of the instance it was opened on.
func (a *App) buildOptionsDialog(c ui.C, p *project) {
	e := &p.build.options
	if !e.open {
		return
	}
	language := a.language()
	ready := !e.loading && !e.saving
	open := true
	// Opened on an instance the dialog is that build system's options, as the instance's button
	// says; from the toolbar it is only the scope of detection.
	title := i18n.Shared(language, "desktop.build.ignoredPaths")
	if e.instance != "" {
		title = i18n.SharedFormat(language, "desktop.build.instanceOptions", map[string]string{"name": e.name})
	}
	closed := ui.Modal(c, &open, title, ui.ModalSpec{Width: 460}, func() {
		ui.Column(c.Part("build-options")).FillWidth().Gap(10).Children(func() {
			a.buildIgnoredPathsSection(c.Part("detection"), p, ready)
			if e.instance != "" {
				k := c.Part("instance")
				ui.Row(k).FillWidth().Items(ui.Center).Gap(6).MarginTop(6).Children(func() {
					a.buildOptionsHeading(k, e.name)
					if e.root != "" {
						ui.Text(c, e.root).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
					}
				})
				if len(e.fields) == 0 && !e.loading {
					ui.Wrap(c, i18n.Shared(language, "desktop.build.noOptions")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
				}
				for index := range e.fields {
					a.drawRunOptionField(k.KeyInt(index), language, &e.fields[index], ready)
				}
				a.buildRuntimeSection(c, language, e)
				a.buildDroppedOptionsSection(c, language, p, ready)
			}
			if e.loading {
				ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
			}
			if e.failure != "" {
				ui.Paragraph(c, e.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
			c.After(func() { p.build.options = buildOptionsEditor{} })
		}
		if ui.Button(c, i18n.Shared(language, "ui.save")).Disabled(!ready || e.ignored.restoring).Clicked() {
			c.After(func() {
				a.performed("build.options.save", surfaceButton)
				a.saveBuildOptions(p)
			})
		}
	})
	if closed {
		c.After(func() {
			if !p.build.options.saving {
				p.build.options = buildOptionsEditor{}
			}
		})
	}
}

// buildOptionsHeading declares the heading of one section of the Build options dialog.
func (a *App) buildOptionsHeading(c ui.C, title string) {
	ui.Text(c, title).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Text).Ellipsis().Shrink(0)
}

// buildIgnoredPathsSection declares the Detection section of the dialog: the ignored paths, one pattern a
// line, with an ⓘ on how they are written, the layer the shown list comes from, and Restore Default while it
// comes from this machine.
func (a *App) buildIgnoredPathsSection(c ui.C, p *project, ready bool) {
	g, language := &p.build.options.ignored, a.language()
	label := i18n.Shared(language, "desktop.build.ignoredPaths")
	ui.Column(c).FillWidth().Gap(10).Children(func() {
		a.buildOptionsHeading(c, i18n.Shared(language, "desktop.build.detection"))
		ui.Row(c).FillWidth().Items(ui.Center).Gap(4).Children(func() {
			ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Shrink(0)
			ui.Button(c.Part("help"), i18n.Shared(language, "native.moreInformation")).Icon(icons.Info).IconOnly().Ghost().Size(18, 18).
				Tooltip(i18n.Shared(language, "desktop.build.ignoredPathsHelp")).TooltipOn(ui.TooltipRight)
			ui.Spacer(c)
			if g.source == core.BuildIgnoredPathsLocal && !g.inherit {
				if ui.Button(c.Part("restore"), i18n.Shared(language, "native.restoreDefault")).Ghost().Small().Disabled(!ready || g.restoring).Clicked() {
					c.After(func() {
						a.performed("build.ignoredPaths.restoreDefault", surfaceButton)
						a.readBuildIgnoredPaths(p, true)
					})
				}
			}
		})
		ui.TextArea(c.Part("patterns"), &g.text, label, "").FillWidth().Height(72).Disabled(!ready || !g.loaded || g.restoring)
		if !g.loaded {
			return
		}
		var source string
		switch g.source {
		case core.BuildIgnoredPathsLocal:
			source = i18n.Shared(language, "desktop.build.ignoredPathsLocal")
		case core.BuildIgnoredPathsTeam:
			source = i18n.SharedFormat(language, "desktop.build.ignoredPathsTeam", map[string]string{"file": buildTeamOptionsFile})
		default:
			source = i18n.Shared(language, "desktop.build.ignoredPathsDefault")
		}
		ui.Wrap(c, source).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}
