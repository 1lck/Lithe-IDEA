package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Build options are stored in two documents. The team document is .lithe/build/options.json in the project,
// read only here and never rewritten by this client. The local document is this machine's own preferences for
// the project; it is kept in the application's data store, never in the project or in the application bundle.
// Core checks the two against each other (build.resolveStoredOptions), applies a change to the local document
// (build.editStoredOption), and detection then reads the merged values back into each instance.

// buildTeamOptionsFile is the team Build options document, relative to the project root.
const buildTeamOptionsFile = ".lithe/build/options.json"

// buildLocalOptionsFile is the data-store file of the local documents, keyed by project root.
const buildLocalOptionsFile = "build-local-options.json"

// buildOptionsMaximumBytes bounds the team document the host reads.
const buildOptionsMaximumBytes = 1 << 20

// emptyBuildOptionDocument and emptyBuildLocalDocument are what a project without stored options reads as.
var (
	emptyBuildOptionDocument = json.RawMessage(`{"version":1,"systems":{}}`)
	emptyBuildLocalDocument  = json.RawMessage(`{"version":1,"document":{"version":1,"systems":{}}}`)
)

// buildOptionDocuments are the team and local documents of one project as they are stored.
type buildOptionDocuments struct {
	team, local json.RawMessage
}

// readBuildOptionDocuments reads the team document from the project and the local document from the data
// store. A document that exists but is not valid JSON is an error, not an empty document.
func (a *App) readBuildOptionDocuments(ctx context.Context, root string) (buildOptionDocuments, error) {
	docs := buildOptionDocuments{team: emptyBuildOptionDocument, local: emptyBuildLocalDocument}
	snapshot, err := configfile.Capture(ctx, root, buildTeamOptionsFile, buildOptionsMaximumBytes)
	if err != nil {
		return docs, err
	}
	if snapshot.Exists() {
		team := snapshot.Bytes()
		if !json.Valid(team) {
			return docs, errors.New(buildTeamOptionsFile + ": invalid JSON")
		}
		docs.team = team
	}
	if a.store == nil {
		return docs, nil
	}
	all := map[string]json.RawMessage{}
	found, err := a.store.Load(buildLocalOptionsFile, &all)
	if err != nil {
		return docs, err
	}
	if found {
		if local, ok := all[root]; ok && len(local) > 0 {
			docs.local = local
		}
	}
	return docs, nil
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
// defaults, the values of each root and the explicit empty selections.
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

// buildOptionsEditor is the Build options dialog of the selected instance: its fields, and the instance they
// were read from, so an answer for another instance is dropped.
type buildOptionsEditor struct {
	open     bool
	instance string
	fields   []runOptionField
	saving   bool
	failure  string
}

// openBuildOptions opens the options dialog on the selected instance, from its effective values.
func (a *App) openBuildOptions(p *project) {
	instance := p.selectedBuildInstance()
	if instance == nil {
		return
	}
	p.build.options = buildOptionsEditor{
		open:     true,
		instance: instance.ID,
		fields:   declaredOptionFields(instance.Manifest, instance.BuildSystemID, instance.Options),
	}
}

// saveBuildOptions writes the changed fields of the dialog to the local document, one Core edit each, then
// detects the instances again so they show what was read back.
func (a *App) saveBuildOptions(p *project) {
	e := &p.build.options
	if !e.open || e.saving {
		return
	}
	var changes []buildOptionChange
	for _, field := range e.fields {
		if value, changed := changedOptionValue(field); changed {
			changes = append(changes, buildOptionChange{optionID: field.id, value: value})
		}
	}
	instance := p.buildInstanceByID(e.instance)
	if instance == nil || len(changes) == 0 {
		e.open = false
		return
	}
	e.saving, e.failure = true, ""
	a.saveBuildOptionChanges(p, *instance, changes, func(_ json.RawMessage, err error) {
		if e := &p.build.options; e.open {
			e.saving = false
			if err != nil {
				e.failure = err.Error()
				return
			}
			e.open = false
		}
	})
}

// buildOptionChange is one option the user set; a nil value removes the local override.
type buildOptionChange struct {
	optionID string
	value    any
}

// saveBuildOptionChanges applies changes to one instance's local document. Core checks each edit; the host
// writes the local document only when every edit succeeded, atomically, and then detects the instances again.
// done receives the outcome on the window thread: the option states Core read back from the
// edited documents, or why the edit was refused or could not be stored.
func (a *App) saveBuildOptionChanges(p *project, instance buildInstance, changes []buildOptionChange, done func(options json.RawMessage, err error)) {
	docs, err := a.readBuildOptionDocuments(context.Background(), p.root)
	if err != nil {
		done(nil, err)
		return
	}
	kernel, root := a.kernel, p.root
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		local := docs.local
		var options json.RawMessage
		for _, change := range changes {
			edit, err := kernel.EditStoredBuildOption(ctx, instance.Manifest, instance.BuildSystemID, core.BuildOptionEditRequest{
				Document: docs.team, Local: local, Root: instance.Root, OptionID: change.optionID, Value: change.value,
			})
			if err != nil {
				return func(a *App) { done(nil, err) }
			}
			local, options = edit.Local, edit.Options
		}
		return func(a *App) {
			if err := a.storeBuildLocalOptions(root, local); err != nil {
				done(nil, err)
				return
			}
			done(options, nil)
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
	if slices.Equal(local, emptyBuildLocalDocument) {
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

// buildOptionsDialog declares the Build options dialog while it is open.
func (a *App) buildOptionsDialog(c ui.C, p *project) {
	e := &p.build.options
	if !e.open {
		return
	}
	language := a.language()
	ready := !e.saving
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(language, "desktop.build.optionsTitle"), ui.ModalSpec{Width: 460}, func() {
		ui.Column(c.Part("build-options")).FillWidth().Gap(10).Children(func() {
			if len(e.fields) == 0 {
				a.panelMessage(c, i18n.Shared(language, "desktop.build.noOptions"), a.colors.Subtle)
			}
			for index := range e.fields {
				a.drawRunOptionField(c.KeyInt(index), language, &e.fields[index], ready)
			}
			if e.failure != "" {
				ui.Paragraph(c, e.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
		})
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
			c.After(func() { p.build.options = buildOptionsEditor{} })
		}
		if ui.Button(c, i18n.Shared(language, "ui.save")).Disabled(!ready).Clicked() {
			c.After(func() { a.saveBuildOptions(p) })
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
