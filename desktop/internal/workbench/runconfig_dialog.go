package workbench

import (
	"cmp"
	"encoding/json"
	"maps"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds the Run/Debug Configurations dialog, after IDEA's: the configurations as a
// tree by kind on the left under the buttons that add, remove and copy one, the editor of the
// selected one on the right, and Run, Cancel, Apply and OK under them. Every configuration the
// user selects gets its own draft, so edits to several configurations, the configurations
// added and the ones removed all wait for Apply or OK, and Cancel drops them together.
// Drawing is in runconfig_dialog_view.go.

// runConfigNewKey starts the draft key of a configuration created in the dialog and not saved
// yet. No configuration ID starts with it, since Core's IDs start with their layer.
const runConfigNewKey = "new:"

// runConfigDialog is the state of the Run/Debug Configurations dialog. Only the window thread
// reads or writes it.
type runConfigDialog struct {
	open bool
	// generation rejects the answer of a save chain whose dialog was closed or reopened since.
	generation uint64
	// selected is the draft key of the selected configuration, and group the key of the
	// selected group row while a group rather than a configuration is selected.
	selected, group string
	// drafts are the editors of the configurations the user selected, by configuration ID, or
	// by a runConfigNewKey key until a new configuration's first save names it.
	drafts map[string]*runConfigDraft
	// added are the keys of the configurations created in the dialog, in creation order. A
	// saved one stays until the list shows it, so it does not vanish while the list refreshes.
	added []string
	// removed are the listed configurations to delete on Apply, and hidden the IDs a save
	// replaced, such as by renaming, kept out of the tree until the list stops showing them.
	removed, hidden map[string]bool
	// next numbers the next new configuration's key.
	next int
	// newMenu says the menu of kinds the + button opens is showing.
	newMenu bool
	// saving says Apply, OK or Run is saving the drafts; failure is a removal that failed.
	saving  bool
	failure string
	// closed are the groups the user closed, by key. They stay closed across openings.
	closed map[string]bool
	// groups, rows and ids are the tree as it shows, collected on each paint; ids give every
	// draft key a row key of its own for the list's state.
	groups []runConfigDialogGroup
	rows   []runConfigDialogRow
	ids    map[string]int
	view   ui.ListState
}

// runConfigDraft is the editor of one configuration in the dialog: the form of a built-in
// process run, or the options editor of a build provider run. A provider run whose plugin
// cannot resolve has neither, and the dialog says why it cannot be edited.
type runConfigDraft struct {
	key    string
	form   *runConfigForm
	editor *runConfigEditor
}

// runConfigDialogGroup is one kind of configuration in the tree: a built-in kind, or the build
// system that provides runs.
type runConfigDialogGroup struct {
	key, title string
	icon       gfx.Icon
	// order places the built-in kinds first, in the order Core lists them.
	order int
	keys  []string
}

// runConfigDialogRow is one row of the tree: a group's, with an empty key, or a configuration
// under it.
type runConfigDialogRow struct {
	group int
	key   string
}

// runConfigDialogStep is the button that saves the drafts.
type runConfigDialogStep int

const (
	// runConfigDialogApply saves and keeps the dialog open.
	runConfigDialogApply runConfigDialogStep = iota
	// runConfigDialogOK saves and closes the dialog.
	runConfigDialogOK
	// runConfigDialogRun saves, closes the dialog and runs the selected configuration once the
	// list shows what was saved.
	runConfigDialogRun
)

// runProcessKindKey is the group of the built-in runs of provider.
func runProcessKindKey(provider string) string { return runProcessGroupKey + ":" + provider }

// openRunConfigDialog opens the dialog with configuration id selected, or nothing selected
// when id is empty or not listed. It asks for what the tree lists: the build models, whose
// runs it shows, and the built-in kinds.
func (a *App) openRunConfigDialog(p *project, id string) {
	if p == nil {
		return
	}
	d := &p.runConfigs.dialog
	d.dropDrafts()
	*d = runConfigDialog{
		open: true, generation: d.generation + 1, closed: d.closed,
		drafts: map[string]*runConfigDraft{}, removed: map[string]bool{}, hidden: map[string]bool{}, ids: map[string]int{},
	}
	a.title.runConfigOpen = false
	a.loadTitleRunConfigs(p)
	a.loadRunConfigTypes(p)
	if configuration := p.runConfigs.configuration(id); configuration != nil {
		a.selectRunConfigDraft(p, id)
		delete(d.closed, p.runConfigDialogGroupKey(id))
	}
}

// closeRunConfigDialog closes the dialog and drops every draft; answers still out are ignored.
func (a *App) closeRunConfigDialog(p *project) {
	d := &p.runConfigs.dialog
	d.dropDrafts()
	d.generation++
	d.open, d.saving, d.newMenu = false, false, false
}

// dropDrafts closes every draft's editor.
func (d *runConfigDialog) dropDrafts() {
	for _, draft := range d.drafts {
		draft.close()
	}
	d.drafts = nil
}

// close closes the draft's editor.
func (draft *runConfigDraft) close() {
	if draft.form != nil {
		draft.form.close()
	}
	if draft.editor != nil {
		draft.editor.close()
	}
}

// dirty says the draft holds something Apply would save: an edited configuration, or a new
// one not saved yet.
func (draft *runConfigDraft) dirty() bool {
	switch {
	case draft.form != nil:
		return draft.form.open && (draft.form.dirty || draft.form.id == "")
	case draft.editor != nil:
		return draft.editor.dirty()
	}
	return false
}

// busy says the draft is being read or saved, so Apply cannot save it yet.
func (draft *runConfigDraft) busy() bool {
	switch {
	case draft.form != nil:
		return draft.form.loading || draft.form.saving
	case draft.editor != nil:
		return draft.editor.loading || draft.editor.saving
	}
	return false
}

// selectRunConfigDraft selects configuration key and reads its editor the first time.
func (a *App) selectRunConfigDraft(p *project, key string) {
	d := &p.runConfigs.dialog
	d.selected, d.group, d.newMenu = key, "", false
	if d.drafts[key] != nil {
		return
	}
	configuration := p.runConfigs.configuration(key)
	if configuration == nil {
		return
	}
	draft := &runConfigDraft{key: key}
	switch {
	case configuration.IsProcess():
		draft.form = a.openRunConfigForm(p, configuration.Provider, key, nil)
	case runConfigEditable(*configuration):
		draft.editor = a.openRunConfigEditor(p, key)
	}
	d.drafts[key] = draft
}

// addRunConfigDraft creates a new configuration of provider, seeded with values when they are
// set, opens its group and selects it.
func (a *App) addRunConfigDraft(p *project, provider string, values map[string]json.RawMessage) {
	d := &p.runConfigs.dialog
	d.next++
	key := runConfigNewKey + strconv.Itoa(d.next)
	draft := &runConfigDraft{key: key, form: a.openRunConfigForm(p, provider, "", values)}
	d.drafts[key] = draft
	d.added = append(d.added, key)
	delete(d.closed, runProcessKindKey(provider))
	d.selected, d.group, d.newMenu, d.failure = key, "", false, ""
}

// copyRunConfigDraft creates a copy of the selected built-in run with the values its form shows,
// named as a copy.
func (a *App) copyRunConfigDraft(p *project) {
	d := &p.runConfigs.dialog
	draft := d.drafts[d.selected]
	if draft == nil || draft.form == nil || !draft.form.ready() {
		return
	}
	values := draft.form.collect()
	name, _ := json.Marshal(i18n.SharedFormat(a.language(), "desktop.runConfig.copyName", map[string]string{"name": a.runConfigDraftLabel(p, d.selected)}))
	values["name"] = name
	a.addRunConfigDraft(p, draft.form.provider, values)
}

// removeRunConfigDraft takes the selected configuration out of the tree: a new one is dropped,
// a saved one is deleted on Apply. The selection moves to the row that takes its place.
func (a *App) removeRunConfigDraft(p *project) {
	d := &p.runConfigs.dialog
	key := d.selected
	if !p.runConfigRemovable(key) {
		return
	}
	at := slices.IndexFunc(d.rows, func(row runConfigDialogRow) bool { return row.key == key })
	if draft := d.drafts[key]; draft != nil {
		draft.close()
		delete(d.drafts, key)
	}
	d.added = slices.DeleteFunc(d.added, func(added string) bool { return added == key })
	if !strings.HasPrefix(key, runConfigNewKey) {
		d.removed[key] = true
	}
	d.selected, d.failure = "", ""
	p.collectRunConfigDialogRows(a)
	for index := min(at, len(d.rows)-1); index >= 0; index-- {
		if index < len(d.rows) && d.rows[index].key != "" {
			a.selectRunConfigDraft(p, d.rows[index].key)
			return
		}
	}
	for _, row := range d.rows {
		if row.key != "" {
			a.selectRunConfigDraft(p, row.key)
			return
		}
	}
}

// runConfigRemovable says − can take configuration key out: a new one, or a saved user
// configuration that does not run. Generated configurations come back on the next detection,
// so they are never removed.
func (p *project) runConfigRemovable(key string) bool {
	d := &p.runConfigs.dialog
	switch {
	case key == "" || d.saving:
		return false
	case strings.HasPrefix(key, runConfigNewKey):
		return true
	case p.build.runOf(configurationRunKey(key)) != nil:
		return false
	}
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		return configuration.UserDefined()
	}
	// A configuration saved in the dialog and not listed yet was created as a user one.
	return slices.Contains(d.added, key)
}

// runConfigDialogGroupKey is the tree group of configuration or draft key.
func (p *project) runConfigDialogGroupKey(key string) string {
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		if configuration.IsProcess() {
			return runProcessKindKey(configuration.Provider)
		}
		return runConfigGroupKey(configuration)
	}
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil && draft.form != nil {
		return runProcessKindKey(draft.form.provider)
	}
	return ""
}

// collectRunConfigDialogRows lists the tree as it shows: the listed configurations the user did
// not remove and the ones created in the dialog, each under its kind, the built-in kinds first
// in Core's order and the build systems by title, the configurations of a kind by name. A
// closed group shows its row only.
func (p *project) collectRunConfigDialogRows(a *App) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	d.groups, d.rows = d.groups[:0], d.rows[:0]
	place := func(key, group, title string, icon gfx.Icon, order int) {
		g := slices.IndexFunc(d.groups, func(existing runConfigDialogGroup) bool { return existing.key == group })
		if g < 0 {
			g = len(d.groups)
			d.groups = append(d.groups, runConfigDialogGroup{key: group, title: title, icon: icon, order: order})
		}
		d.groups[g].keys = append(d.groups[g].keys, key)
	}
	processGroup := func(provider string) (string, string, gfx.Icon, int) {
		title, ok := runConfigTypeLabel(language, provider)
		if !ok {
			title = i18n.Shared(language, "desktop.runConfig.builtInGroup")
		}
		order := slices.IndexFunc(s.types, func(kind core.RunConfigurationType) bool { return kind.Provider == provider })
		if order < 0 {
			order = len(s.types)
		}
		return runProcessKindKey(provider), title, runConfigTypeIcon(provider), order
	}
	listed := map[string]bool{}
	for index := range s.list {
		configuration := &s.list[index]
		listed[configuration.ID] = true
		if d.removed[configuration.ID] || d.hidden[configuration.ID] {
			continue
		}
		if configuration.IsProcess() {
			group, title, icon, order := processGroup(configuration.Provider)
			place(configuration.ID, group, title, icon, order)
			continue
		}
		place(configuration.ID, runConfigGroupKey(configuration), p.runConfigGroupTitle(language, configuration), icons.Wrench, len(s.types)+1)
	}
	for _, key := range d.added {
		draft := d.drafts[key]
		if listed[key] || draft == nil || draft.form == nil {
			continue
		}
		group, title, icon, order := processGroup(draft.form.provider)
		place(key, group, title, icon, order)
	}
	slices.SortStableFunc(d.groups, func(x, y runConfigDialogGroup) int {
		return cmp.Or(cmp.Compare(x.order, y.order), strings.Compare(strings.ToLower(x.title), strings.ToLower(y.title)), strings.Compare(x.key, y.key))
	})
	for g := range d.groups {
		group := &d.groups[g]
		labels := make(map[string]string, len(group.keys))
		for _, key := range group.keys {
			labels[key] = strings.ToLower(a.runConfigDraftLabel(p, key))
		}
		slices.SortStableFunc(group.keys, func(x, y string) int {
			return cmp.Or(strings.Compare(labels[x], labels[y]), strings.Compare(x, y))
		})
		d.rows = append(d.rows, runConfigDialogRow{group: g})
		if d.closed[group.key] {
			continue
		}
		for _, key := range group.keys {
			d.rows = append(d.rows, runConfigDialogRow{group: g, key: key})
		}
	}
}

// runConfigDraftLabel is the name a configuration shows in the tree: the name its form holds,
// else the name it gets while the field is empty, else its saved name.
func (a *App) runConfigDraftLabel(p *project, key string) string {
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil && draft.form != nil {
		f := draft.form
		if name := f.texts["name"]; name != nil && strings.TrimSpace(*name) != "" {
			return strings.TrimSpace(*name)
		}
		for _, field := range f.fields {
			if field.ID == "name" && field.Automatic != nil && *field.Automatic != "" {
				return *field.Automatic
			}
		}
		if f.name != "" {
			return f.name
		}
	}
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		return configuration.Name
	}
	return i18n.Shared(a.language(), "desktop.runConfig.unnamed")
}

// runConfigDraftUnavailable words why configuration key cannot run here, "" when it can. A
// form says what its kind needs, such as Windows for a batch script; a configuration whose
// form is edited is judged by its edits, so a listed failure such as a missing working
// directory no longer counts once the user changed it.
func (a *App) runConfigDraftUnavailable(p *project, key string) string {
	draft := p.runConfigs.dialog.drafts[key]
	if draft != nil && draft.form != nil {
		if availability := draft.form.availability; availability != nil && availability.Status == "unavailable" {
			return a.runAvailabilityText(draft.form.provider, *availability)
		}
		if draft.form.dirty {
			return ""
		}
	}
	if configuration := p.runConfigs.configuration(key); configuration != nil && configuration.Unavailable() {
		return a.runConfigUnavailableText(*configuration)
	}
	return ""
}

// runConfigDialogRunnable says Run can run the selected configuration once it is saved.
func (a *App) runConfigDialogRunnable(p *project) bool {
	d := &p.runConfigs.dialog
	draft := d.drafts[d.selected]
	if draft == nil || a.runConfigDraftUnavailable(p, d.selected) != "" {
		return false
	}
	if draft.form != nil {
		return true
	}
	configuration := p.runConfigs.configuration(d.selected)
	return configuration != nil && p.runConfigurationReady(*configuration)
}

// runConfigDialogDirty says Apply has something to save.
func (d *runConfigDialog) dirty() bool {
	if len(d.removed) > 0 {
		return true
	}
	for _, draft := range d.drafts {
		if draft.dirty() {
			return true
		}
	}
	return false
}

// busy says a save runs, or a draft with something to save is still being read or saved.
func (d *runConfigDialog) busy() bool {
	if d.saving {
		return true
	}
	for _, draft := range d.drafts {
		if draft.busy() {
			return true
		}
	}
	return false
}

// runConfigDialogTask is one save of the chain Apply runs; done gets whether it succeeded.
type runConfigDialogTask func(done func(ok bool))

// applyRunConfigDialog saves what the dialog holds, one file change after another: the
// removals, then every draft with something to save. The first failure stops the chain and
// selects the configuration it belongs to, whose editor shows the reason. When every save
// succeeded, the selected configuration becomes the one the title bar runs; OK then closes the
// dialog, and Run closes it and runs the configuration once the list shows what was saved. The
// configurations are resolved again either way, so what was saved before a failure shows.
func (a *App) applyRunConfigDialog(p *project, step runConfigDialogStep) {
	d := &p.runConfigs.dialog
	if !d.open || d.busy() {
		return
	}
	// The save order follows the tree, so a configuration added since the last paint saves too.
	p.collectRunConfigDialogRows(a)
	d.saving, d.failure = true, ""
	generation := d.generation
	var tasks []runConfigDialogTask
	for _, id := range slices.Sorted(maps.Keys(d.removed)) {
		tasks = append(tasks, func(done func(bool)) {
			a.removeRunConfiguration(p, id, func(err error) {
				if err != nil {
					if d.generation == generation {
						d.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.deleteFailed", map[string]string{"reason": err.Error()})
					}
					done(false)
					return
				}
				delete(d.removed, id)
				done(true)
			})
		})
	}
	for _, key := range p.runConfigDialogSaveOrder() {
		draft := d.drafts[key]
		tasks = append(tasks, func(done func(bool)) {
			failed := func() {
				if d.generation == generation {
					d.selected, d.group = draft.key, ""
					delete(d.closed, p.runConfigDialogGroupKey(draft.key))
				}
				done(false)
			}
			if draft.form != nil {
				a.saveRunConfigForm(p, draft.form, func(id string, ok bool) {
					if !ok {
						failed()
						return
					}
					if d.generation == generation {
						d.rekey(draft, id)
					}
					done(true)
				})
				return
			}
			a.saveRunConfigEditor(p, draft.editor, func(ok bool) {
				if !ok {
					failed()
					return
				}
				done(true)
			})
		})
	}
	finish := func(ok bool) {
		if d.generation != generation {
			a.refreshRunConfigurations(p)
			return
		}
		d.saving = false
		if ok {
			s := &p.runConfigs
			if id := d.selected; id != "" && !strings.HasPrefix(id, runConfigNewKey) {
				s.reveal, s.currentFile = id, false
				if step == runConfigDialogRun {
					s.start = id
				}
			}
			if step != runConfigDialogApply {
				a.closeRunConfigDialog(p)
			}
		}
		a.refreshRunConfigurations(p)
	}
	var next func(index int)
	next = func(index int) {
		if d.generation != generation {
			finish(false)
			return
		}
		if index == len(tasks) {
			finish(true)
			return
		}
		tasks[index](func(ok bool) {
			if !ok {
				finish(false)
				return
			}
			next(index + 1)
		})
	}
	next(0)
}

// runConfigDialogSaveOrder is the drafts with something to save, as the tree shows them, so a
// failure stops at the first one the user sees.
func (p *project) runConfigDialogSaveOrder() []string {
	d := &p.runConfigs.dialog
	var keys []string
	seen := map[string]bool{}
	for _, group := range d.groups {
		for _, key := range group.keys {
			if draft := d.drafts[key]; draft != nil && !seen[key] && draft.dirty() {
				keys, seen[key] = append(keys, key), true
			}
		}
	}
	return keys
}

// rekey files a draft under the ID its save returned, when that differs from its key: a new
// configuration's first save, or a rename that gave it another ID. The old ID stays out of the
// tree until the list stops showing it.
func (d *runConfigDialog) rekey(draft *runConfigDraft, id string) {
	old := draft.key
	if id == "" || id == old {
		return
	}
	delete(d.drafts, old)
	draft.key, d.drafts[id] = id, draft
	if !strings.HasPrefix(old, runConfigNewKey) {
		d.hidden[old] = true
	}
	if index := slices.Index(d.added, old); index >= 0 {
		d.added[index] = id
	} else {
		d.added = append(d.added, id)
	}
	if d.selected == old {
		d.selected = id
	}
	if row, ok := d.ids["c\x00"+old]; ok {
		d.ids["c\x00"+id] = row
	}
}

// runConfigDialogRowID is the list key of a tree row, the same across paints: one per draft
// key and one per group key, numbered as they first show.
func (d *runConfigDialog) runConfigDialogRowID(row runConfigDialogRow) int {
	key := "c\x00" + row.key
	if row.key == "" {
		key = "g\x00" + d.groups[row.group].key
	}
	id, ok := d.ids[key]
	if !ok {
		id = len(d.ids)
		d.ids[key] = id
	}
	return id
}

// runConfigDialogRowIndex is the index of the selected row among the rows as they show, -1
// when nothing is selected or the selection is in a closed group.
func (d *runConfigDialog) runConfigDialogRowIndex() int {
	for index, row := range d.rows {
		if row.key == "" {
			if d.selected == "" && d.group != "" && d.groups[row.group].key == d.group {
				return index
			}
		} else if row.key == d.selected {
			return index
		}
	}
	return -1
}

// toggleRunConfigDialogGroup opens a closed group of the tree and closes an open one.
// Closing the group of the selected configuration leaves the selection on the group's row.
func (p *project) toggleRunConfigDialogGroup(key string) {
	d := &p.runConfigs.dialog
	if d.closed[key] {
		delete(d.closed, key)
		return
	}
	if d.closed == nil {
		d.closed = map[string]bool{}
	}
	d.closed[key] = true
	if d.selected != "" && p.runConfigDialogGroupKey(d.selected) == key {
		d.selected, d.group = "", key
	}
}

// runAvailabilityText words why this platform cannot run a configuration of provider, from
// the availability Core gave its kind or its editor.
func (a *App) runAvailabilityText(provider string, availability core.RunAvailability) string {
	language := a.language()
	if availability.Code == "unsupportedPlatform" {
		if provider == runProviderBatch {
			return i18n.Shared(language, "desktop.runConfig.unavailableBatchPlatform")
		}
		kind, ok := runConfigTypeLabel(language, provider)
		if !ok {
			kind = provider
		}
		return i18n.SharedFormat(language, "desktop.runConfig.unavailablePlatform", map[string]string{"type": kind})
	}
	return i18n.SharedFormat(language, "desktop.runConfig.unavailableOther", map[string]string{"reason": availability.Message})
}
