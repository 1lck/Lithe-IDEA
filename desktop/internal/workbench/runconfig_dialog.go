package workbench

import (
	"cmp"
	"context"
	"encoding/json"
	"maps"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds the Run/Debug Configurations dialog, after IDEA's: the configurations as a
// tree by kind on the left, under the buttons that add, remove and copy one, make a folder and
// sort the list by name; the editor of the selected one on the right; and Run, Cancel, Apply and
// OK under them. Every configuration the user selects gets its own draft, so edits to several
// configurations, the configurations added, copied and removed, and the folders and order the
// user gave the list all wait for Apply or OK, and Cancel drops them together. Drawing is in
// runconfig_dialog_view.go.
//
// A folder lives in the configurations it holds, as IDEA's folderName does: Core saves it with
// each one, so a folder with nothing in it is not saved. The manual order and the choice to sort
// by name are this machine's and Core keeps them in the local layer.

// runConfigNewKey starts the draft key of a configuration created in the dialog and not saved
// yet. No configuration ID starts with it, since Core's IDs start with their layer.
const runConfigNewKey = "new:"

// runConfigFolderBytes is the longest folder name Core takes, in bytes.
const runConfigFolderBytes = 256

// runConfigNewMenu is where the menu of kinds a new configuration can take shows.
type runConfigNewMenu uint8

const (
	runConfigNewMenuClosed runConfigNewMenu = iota
	// runConfigNewMenuToolbar is under the + button, and opens from the keyboard too.
	runConfigNewMenuToolbar
	// runConfigNewMenuTree is under the link of the empty tree.
	runConfigNewMenuTree
	// runConfigNewMenuPane is under the link the pane shows while no configuration is selected.
	runConfigNewMenuPane
)

// runConfigDialog is the state of the Run/Debug Configurations dialog. Only the window thread
// reads or writes it.
type runConfigDialog struct {
	open bool
	// generation rejects the answer of a save chain whose dialog was closed or reopened since.
	generation uint64
	// selected is the draft key of the selected configuration, and node the group or folder
	// row selected while one of those rather than a configuration is.
	selected string
	node     runConfigDialogNode
	// drafts are the editors of the configurations the user selected, by configuration ID, or
	// by a runConfigNewKey key until a new configuration's first save names it.
	drafts map[string]*runConfigDraft
	// added are the keys of the configurations created or copied in the dialog, in creation
	// order. A saved one stays until the list shows it, so it does not vanish while the list
	// refreshes.
	added []string
	// removed are the listed configurations to delete on Apply, and hidden the IDs a save
	// replaced, such as by renaming, or deleted, kept out of the tree until the list stops
	// showing them.
	removed, hidden map[string]bool
	// next numbers the next new configuration's key.
	next int
	// newMenu says where the menu of kinds is showing, if anywhere.
	newMenu runConfigNewMenu
	// saving says Apply, OK or Run is saving the drafts; failure is a step of the save that
	// failed outside every editor: a removal, a copy or the arrangement.
	saving  bool
	failure string
	// closed are the groups and folders the user closed. They stay closed across openings.
	closed map[runConfigDialogNode]bool
	// folders are the folders the user moved configurations to, by draft key, "" for none;
	// emptyFolders are the folders made in the dialog with nothing in them yet, by group key.
	folders      map[string]string
	emptyFolders map[string][]string
	// sort is the choice to sort by name the user made in the dialog, nil while the list's
	// stands; order is the manual order the user made, by draft key, nil while the list's
	// stands. rearranged says the folders, the order or the sort changed since Apply.
	sort       *bool
	order      []string
	rearranged bool
	// folderName is the text of the selected folder's name field, and folderError why it
	// cannot name the folder.
	folderName, folderError string
	// groups, rows and ids are the tree as it shows, collected on each paint; ids give every
	// row a key of its own for the tree's state, the same across paints. selectedRow is the
	// row of the selection in the last paint, -1 when none shows, and painted the number of
	// rows the tree last painted.
	groups               []runConfigDialogGroup
	rows                 []runConfigDialogRow
	ids                  map[string]int
	selectedRow, painted int
	// focus is the keyboard focus the tree last saw, so a row the arrow keys move to is
	// selected. reveal scrolls the selection into view on the next paint, and refocus also
	// gives it the keyboard, as after Delete took out the focused row.
	focus           gfx.ID
	reveal, refocus bool
	view            ui.TreeState
}

// runConfigDraft is the editor of one configuration in the dialog: the form of a built-in
// process run, the options editor of a build provider run, or the name of a copy Core makes on
// Apply. A provider run whose plugin cannot resolve has none of them, and the dialog says why it
// cannot be edited.
type runConfigDraft struct {
	key    string
	form   *runConfigForm
	editor *runConfigEditor
	// folder is the folder the configuration is saved in, for while the list does not show it
	// under this key: after a rename, or for a copy.
	folder string
	// copyOf is the configuration a copy not saved yet copies, and copyName the copy's name.
	// Core copies it on Apply, every saved choice and the folder included; copied then says it
	// did, and the draft gives way to the configuration's own editor once the list shows it.
	// A built-in run is copied from its form instead, with what the form shows.
	copyOf, copyName string
	copied           bool
	// group and icon are where and how a copy shows until the list shows it.
	group runConfigDialogGroup
	icon  gfx.Icon
}

// runConfigDialogNode names a group row of the tree by the group's key, or a folder row by its
// group's key and its name.
type runConfigDialogNode struct {
	group, folder string
}

// id is the node's key among the tree's row keys.
func (n runConfigDialogNode) id() string {
	if n.folder == "" {
		return "g\x00" + n.group
	}
	return "f\x00" + n.group + "\x00" + n.folder
}

// runConfigDialogGroup is one kind of configuration in the tree: a built-in kind, or the build
// system that provides runs.
type runConfigDialogGroup struct {
	key, title string
	icon       gfx.Icon
	// order places the built-in kinds first, in the order Core lists them.
	order int
	// folders are the group's folders by name, and keys the configurations outside them, each
	// in the order the list shows them.
	folders []runConfigDialogFolder
	keys    []string
}

// runConfigDialogFolder is one folder of a group and the configurations in it.
type runConfigDialogFolder struct {
	name string
	keys []string
}

// runConfigDialogRow is one row of the tree: a group's or a folder's, with an empty key, or a
// configuration's. node is the row's group or folder, or the one the configuration is in.
type runConfigDialogRow struct {
	group int
	node  runConfigDialogNode
	key   string
	depth int
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
		open: true, generation: d.generation + 1, closed: d.closed, selectedRow: -1, reveal: true,
		drafts: map[string]*runConfigDraft{}, removed: map[string]bool{}, hidden: map[string]bool{}, ids: map[string]int{},
	}
	a.title.runConfigOpen = false
	a.loadTitleRunConfigs(p)
	a.loadRunConfigTypes(p, true)
	if configuration := p.runConfigs.configuration(id); configuration != nil {
		a.selectRunConfigDraft(p, id)
		group := p.runConfigDialogGroupKey(id)
		delete(d.closed, runConfigDialogNode{group: group})
		delete(d.closed, runConfigDialogNode{group: group, folder: configuration.Folder})
	}
}

// closeRunConfigDialog closes the dialog and drops every draft; answers still out are ignored.
func (a *App) closeRunConfigDialog(p *project) {
	d := &p.runConfigs.dialog
	d.dropDrafts()
	d.generation++
	d.open, d.saving, d.newMenu = false, false, runConfigNewMenuClosed
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

// pendingCopy says the draft is a copy Core has not made yet.
func (draft *runConfigDraft) pendingCopy() bool { return draft.copyOf != "" && !draft.copied }

// dirty says the draft holds something Apply would save: an edited configuration, or a new
// one or a copy not saved yet.
func (draft *runConfigDraft) dirty() bool {
	switch {
	case draft.form != nil:
		return draft.form.open && (draft.form.dirty || draft.form.id == "")
	case draft.editor != nil:
		return draft.editor.dirty()
	}
	return draft.pendingCopy()
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
	d.selected, d.node, d.newMenu, d.folderError = key, runConfigDialogNode{}, runConfigNewMenuClosed, ""
	if d.drafts[key] != nil {
		return
	}
	configuration := p.runConfigs.configuration(key)
	if configuration == nil {
		return
	}
	draft := &runConfigDraft{key: key, folder: configuration.Folder}
	kind, form := runConfigKindOf(*configuration)
	switch {
	case !runConfigEditable(*configuration):
	case form:
		draft.form = a.openRunConfigForm(p, kind, key, nil)
	default:
		draft.editor = a.openRunConfigEditor(p, key)
	}
	d.drafts[key] = draft
}

// selectRunConfigDialogNode selects a group or folder row; a folder's name field starts with
// its name.
func (d *runConfigDialog) selectRunConfigDialogNode(node runConfigDialogNode) {
	d.selected, d.node, d.newMenu = "", node, runConfigNewMenuClosed
	d.folderName, d.folderError = node.folder, ""
}

// selectRunConfigDialogRow selects the configuration, group or folder of a row of the tree.
func (a *App) selectRunConfigDialogRow(p *project, row runConfigDialogRow) {
	if row.key != "" {
		a.selectRunConfigDraft(p, row.key)
		return
	}
	d := &p.runConfigs.dialog
	if d.selected != "" || d.node != row.node {
		d.selectRunConfigDialogNode(row.node)
	}
}

// addRunConfigDraft creates a new configuration of kind, seeded with values when they are set,
// opens its group and selects it. With a folder of that kind selected, or a configuration in
// one, the new configuration goes in that folder, as in IDEA.
func (a *App) addRunConfigDraft(p *project, kind runConfigKind, values map[string]json.RawMessage) {
	d := &p.runConfigs.dialog
	group := kind.groupKey()
	folder := d.node.folder
	if d.selected != "" {
		folder = p.runConfigDialogFolder(d.selected)
		if p.runConfigDialogGroupKey(d.selected) != group {
			folder = ""
		}
	} else if d.node.group != group {
		folder = ""
	}
	d.next++
	key := runConfigNewKey + strconv.Itoa(d.next)
	draft := &runConfigDraft{key: key, form: a.openRunConfigForm(p, kind, "", values)}
	d.drafts[key] = draft
	d.added = append(d.added, key)
	if folder != "" {
		d.moveToFolder(key, folder)
	}
	delete(d.closed, runConfigDialogNode{group: group})
	delete(d.closed, runConfigDialogNode{group: group, folder: folder})
	d.selected, d.node, d.newMenu, d.failure, d.reveal = key, runConfigDialogNode{}, runConfigNewMenuClosed, "", true
}

// runConfigCopyable says copy can copy configuration key: the form of a built-in run once it
// is read, or any other listed configuration. A copy is not copied again before it is saved.
func (p *project) runConfigCopyable(key string) bool {
	d := &p.runConfigs.dialog
	draft := d.drafts[key]
	switch {
	case key == "" || d.saving || draft == nil:
		return false
	case draft.form != nil:
		return draft.form.ready()
	case draft.copyOf != "":
		return false
	}
	return p.runConfigs.configuration(key) != nil
}

// copyRunConfigDraft creates a copy of the selected configuration, named as a copy, in its
// folder. A built-in run is copied with the values its form shows; any other configuration,
// such as a build provider run, is copied by Core on Apply with every choice it saved.
func (a *App) copyRunConfigDraft(p *project) {
	d := &p.runConfigs.dialog
	key := d.selected
	if !p.runConfigCopyable(key) {
		return
	}
	draft := d.drafts[key]
	name := i18n.SharedFormat(a.language(), "desktop.runConfig.copyName", map[string]string{"name": a.runConfigDraftLabel(p, key)})
	folder := p.runConfigDialogFolder(key)
	if draft.form != nil {
		values := draft.form.collect()
		values["name"], _ = json.Marshal(name)
		a.addRunConfigDraft(p, draft.form.kind, values)
		d.moveToFolder(d.selected, folder)
		return
	}
	group := runConfigDialogGroup{key: p.runConfigDialogGroupKey(key)}
	if g := slices.IndexFunc(d.groups, func(existing runConfigDialogGroup) bool { return existing.key == group.key }); g >= 0 {
		group = runConfigDialogGroup{key: d.groups[g].key, title: d.groups[g].title, icon: d.groups[g].icon, order: d.groups[g].order}
	}
	d.next++
	copied := &runConfigDraft{
		key: runConfigNewKey + strconv.Itoa(d.next), folder: folder,
		copyOf: key, copyName: name, group: group, icon: a.runConfigDraftIcon(p, key),
	}
	d.drafts[copied.key] = copied
	d.added = append(d.added, copied.key)
	d.selected, d.node, d.newMenu, d.failure, d.reveal = copied.key, runConfigDialogNode{}, runConfigNewMenuClosed, "", true
}

// removeRunConfigSelection is − and Delete: the selected configuration leaves the tree, and a
// selected folder lets go of its configurations, which stay in its group.
func (a *App) removeRunConfigSelection(p *project) {
	d := &p.runConfigs.dialog
	switch {
	case d.saving:
	case d.selected != "":
		a.removeRunConfigDraft(p)
	case d.node.folder != "":
		p.ungroupRunConfigFolder()
	}
}

// runConfigDialogRemovable says − has something to take out: a configuration it can remove,
// or a folder.
func (p *project) runConfigDialogRemovable() bool {
	d := &p.runConfigs.dialog
	if d.selected == "" {
		return !d.saving && d.node.folder != ""
	}
	return p.runConfigRemovable(d.selected)
}

// removeRunConfigDraft takes the selected configuration out of the tree: a new one or a copy
// not saved yet is dropped, a saved one is deleted on Apply. The selection moves to the
// configuration that takes its place.
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
	if strings.HasPrefix(key, runConfigNewKey) {
		delete(d.folders, key)
	} else {
		d.removed[key] = true
	}
	d.selected, d.failure, d.reveal = "", "", true
	p.collectRunConfigDialogRows(a)
	for index := min(at, len(d.rows)-1); index >= 0; index-- {
		if d.rows[index].key != "" {
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

// runConfigRemovable says − can take configuration key out: a new one or a copy, or a saved
// user configuration that does not run. Generated configurations come back on the next
// detection, so they are never removed.
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
		if kind, ok := runConfigKindOf(*configuration); ok {
			return kind.groupKey()
		}
		return runConfigGroupKey(configuration)
	}
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil {
		if draft.form != nil {
			return draft.form.kind.groupKey()
		}
		return draft.group.key
	}
	return ""
}

// runConfigDialogFolder is the folder configuration or draft key shows in: the one the user
// moved it to in the dialog, else the one it is saved in, "" for none.
func (p *project) runConfigDialogFolder(key string) string {
	d := &p.runConfigs.dialog
	if folder, ok := d.folders[key]; ok {
		return folder
	}
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		return configuration.Folder
	}
	if draft := d.drafts[key]; draft != nil {
		return draft.folder
	}
	return ""
}

// moveToFolder moves configuration key to folder, or out of every folder for "", on Apply.
func (d *runConfigDialog) moveToFolder(key, folder string) {
	if d.folders == nil {
		d.folders = map[string]string{}
	}
	d.folders[key] = folder
	d.rearranged = true
}

// runConfigDialogSorted says the tree lists configurations by name rather than in the order
// the user gave them: the choice made in the dialog, else the saved one.
func (p *project) runConfigDialogSorted() bool {
	if sort := p.runConfigs.dialog.sort; sort != nil {
		return *sort
	}
	return !p.runConfigs.manualOrder
}

// collectRunConfigDialogRows lists the tree as it shows: the listed configurations the user did
// not remove and the ones created or copied in the dialog, each under its kind, the built-in
// kinds first in Core's order and the build systems by title. In a kind, its folders come first
// by name, then the configurations outside them; configurations are listed by name, or in the
// order the user gave them. A closed group or folder shows its row only.
func (p *project) collectRunConfigDialogRows(a *App) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	d.groups, d.rows = d.groups[:0], d.rows[:0]
	members := map[string][]string{}
	place := func(key string, group runConfigDialogGroup) {
		if !slices.ContainsFunc(d.groups, func(existing runConfigDialogGroup) bool { return existing.key == group.key }) {
			d.groups = append(d.groups, group)
		}
		members[group.key] = append(members[group.key], key)
	}
	kindGroup := func(kind runConfigKind) runConfigDialogGroup {
		return runConfigDialogGroup{key: kind.groupKey(), title: s.kindTitle(language, kind), icon: s.kindIcon(kind, a.colors.Dark), order: s.kindOrder(kind)}
	}
	listed := map[string]bool{}
	for index := range s.list {
		configuration := &s.list[index]
		listed[configuration.ID] = true
		if d.removed[configuration.ID] || d.hidden[configuration.ID] {
			continue
		}
		if kind, ok := runConfigKindOf(*configuration); ok {
			place(configuration.ID, kindGroup(kind))
			continue
		}
		place(configuration.ID, runConfigDialogGroup{
			key: runConfigGroupKey(configuration), title: p.runConfigGroupTitle(language, configuration), icon: icons.Wrench, order: len(s.types) + 1,
		})
	}
	for _, key := range d.added {
		draft := d.drafts[key]
		switch {
		case listed[key] || draft == nil:
		case draft.form != nil:
			place(key, kindGroup(draft.form.kind))
		case draft.copyOf != "":
			place(key, draft.group)
		}
	}
	slices.SortStableFunc(d.groups, func(x, y runConfigDialogGroup) int {
		return cmp.Or(cmp.Compare(x.order, y.order), strings.Compare(strings.ToLower(x.title), strings.ToLower(y.title)), strings.Compare(x.key, y.key))
	})
	// The manual order ranks configurations: the dialog's, else the list's, which Core keeps in
	// the saved order; configurations it does not place come after it.
	rank := map[string]int{}
	for index, key := range d.order {
		rank[key] = index
	}
	for index := range s.list {
		if _, ok := rank[s.list[index].ID]; !ok {
			rank[s.list[index].ID] = len(d.order) + index
		}
	}
	for index, key := range d.added {
		if _, ok := rank[key]; !ok {
			rank[key] = len(d.order) + len(s.list) + index
		}
	}
	sorted := p.runConfigDialogSorted()
	for g := range d.groups {
		group := &d.groups[g]
		keys := members[group.key]
		labels := make(map[string]string, len(keys))
		for _, key := range keys {
			labels[key] = strings.ToLower(a.runConfigDraftLabel(p, key))
		}
		slices.SortStableFunc(keys, func(x, y string) int {
			if sorted {
				return cmp.Or(strings.Compare(labels[x], labels[y]), strings.Compare(x, y))
			}
			return cmp.Or(cmp.Compare(rank[x], rank[y]), strings.Compare(x, y))
		})
		folders := map[string][]string{}
		for _, name := range d.emptyFolders[group.key] {
			folders[name] = nil
		}
		for _, key := range keys {
			if folder := p.runConfigDialogFolder(key); folder != "" {
				folders[folder] = append(folders[folder], key)
			} else {
				group.keys = append(group.keys, key)
			}
		}
		for _, name := range slices.SortedFunc(maps.Keys(folders), func(x, y string) int {
			return cmp.Or(strings.Compare(strings.ToLower(x), strings.ToLower(y)), strings.Compare(x, y))
		}) {
			group.folders = append(group.folders, runConfigDialogFolder{name: name, keys: folders[name]})
		}
		node := runConfigDialogNode{group: group.key}
		d.rows = append(d.rows, runConfigDialogRow{group: g, node: node})
		if d.closed[node] {
			continue
		}
		for _, folder := range group.folders {
			inside := runConfigDialogNode{group: group.key, folder: folder.name}
			d.rows = append(d.rows, runConfigDialogRow{group: g, node: inside, depth: 1})
			if d.closed[inside] {
				continue
			}
			for _, key := range folder.keys {
				d.rows = append(d.rows, runConfigDialogRow{group: g, node: inside, key: key, depth: 2})
			}
		}
		for _, key := range group.keys {
			d.rows = append(d.rows, runConfigDialogRow{group: g, node: node, key: key, depth: 1})
		}
	}
}

// displayOrder is every configuration of the tree in the order it lists them, the ones in
// closed groups and folders too, as of the last paint.
func (d *runConfigDialog) displayOrder() []string {
	var keys []string
	for _, group := range d.groups {
		for _, folder := range group.folders {
			keys = append(keys, folder.keys...)
		}
		keys = append(keys, group.keys...)
	}
	return keys
}

// runConfigDialogFolderKeys are the configurations in folder node as of the last paint.
func (d *runConfigDialog) runConfigDialogFolderKeys(node runConfigDialogNode) []string {
	for _, group := range d.groups {
		if group.key != node.group {
			continue
		}
		for _, folder := range group.folders {
			if folder.name == node.folder {
				return slices.Clone(folder.keys)
			}
		}
	}
	return nil
}

// runConfigDialogFolderTaken says group has a folder called name as of the last paint.
func (d *runConfigDialog) runConfigDialogFolderTaken(group, name string) bool {
	for _, existing := range d.groups {
		if existing.key == group {
			return slices.ContainsFunc(existing.folders, func(folder runConfigDialogFolder) bool { return folder.name == name })
		}
	}
	return false
}

// addRunConfigFolder makes a folder in the group of the selection, named New Folder or the
// first New Folder N its group does not have: with a configuration selected the folder takes it
// in, else it is empty until a configuration moves in. The folder is selected so it can be
// renamed.
func (a *App) addRunConfigFolder(p *project) {
	d := &p.runConfigs.dialog
	group := d.node.group
	if d.selected != "" {
		group = p.runConfigDialogGroupKey(d.selected)
	}
	if group == "" || d.saving {
		return
	}
	base := i18n.Shared(a.language(), "desktop.runConfig.newFolderName")
	name := base
	for number := 2; d.runConfigDialogFolderTaken(group, name); number++ {
		name = base + " " + strconv.Itoa(number)
	}
	if d.selected != "" {
		d.moveToFolder(d.selected, name)
	} else {
		if d.emptyFolders == nil {
			d.emptyFolders = map[string][]string{}
		}
		d.emptyFolders[group] = append(d.emptyFolders[group], name)
	}
	delete(d.closed, runConfigDialogNode{group: group})
	d.selectRunConfigDialogNode(runConfigDialogNode{group: group, folder: name})
	d.reveal = true
}

// renameRunConfigFolder names the selected folder after its name field, without the spaces
// around it, moving every configuration in it. A name Core cannot save, or that another folder
// of the group has, is not taken and the field says why.
func (a *App) renameRunConfigFolder(p *project) {
	d := &p.runConfigs.dialog
	node := d.node
	if node.folder == "" || d.selected != "" || d.saving {
		return
	}
	language := a.language()
	name := strings.TrimSpace(d.folderName)
	switch {
	case name == "":
		d.folderError = i18n.Shared(language, "desktop.runConfig.folderNameEmpty")
		return
	case len(name) > runConfigFolderBytes || strings.ContainsFunc(name, unicode.IsControl):
		d.folderError = i18n.Shared(language, "desktop.runConfig.folderNameInvalid")
		return
	case name == node.folder:
		d.folderError = ""
		return
	case d.runConfigDialogFolderTaken(node.group, name):
		d.folderError = i18n.Shared(language, "desktop.runConfig.folderNameTaken")
		return
	}
	d.folderError = ""
	for _, key := range d.runConfigDialogFolderKeys(node) {
		d.moveToFolder(key, name)
	}
	if empty := d.emptyFolders[node.group]; slices.Contains(empty, node.folder) {
		d.emptyFolders[node.group] = append(slices.DeleteFunc(empty, func(folder string) bool { return folder == node.folder }), name)
	}
	renamed := runConfigDialogNode{group: node.group, folder: name}
	if d.closed[node] {
		delete(d.closed, node)
		d.closed[renamed] = true
	}
	// The row keeps its key, so it keeps the keyboard while it is renamed.
	if id, ok := d.ids[node.id()]; ok {
		d.ids[renamed.id()] = id
	}
	d.node = renamed
}

// ungroupRunConfigFolder takes the configurations out of the selected folder, which then no
// longer shows, and selects its group.
func (p *project) ungroupRunConfigFolder() {
	d := &p.runConfigs.dialog
	node := d.node
	if node.folder == "" {
		return
	}
	for _, key := range d.runConfigDialogFolderKeys(node) {
		d.moveToFolder(key, "")
	}
	if empty := d.emptyFolders[node.group]; empty != nil {
		d.emptyFolders[node.group] = slices.DeleteFunc(empty, func(folder string) bool { return folder == node.folder })
	}
	d.selectRunConfigDialogNode(runConfigDialogNode{group: node.group})
	d.reveal = true
}

// toggleRunConfigDialogSort switches between listing by name and the order the user gives the
// list. The first manual order is the one the tree shows, so turning sorting off moves nothing.
func (p *project) toggleRunConfigDialogSort() {
	d := &p.runConfigs.dialog
	sorted := !p.runConfigDialogSorted()
	if !sorted && d.order == nil {
		d.order = d.displayOrder()
	}
	d.sort, d.rearranged, d.reveal = &sorted, true, true
}

// runConfigDialogCanDrop says a dragged row can be let go where it is: only a configuration, in
// its own group. Into the group's row takes it out of its folder and into a folder's row puts it
// there; before or after another configuration places it in that one's folder and, when the list
// is not sorted by name, at that place.
func (p *project) runConfigDialogCanDrop(from, to int, where ui.TreeDrop) bool {
	d := &p.runConfigs.dialog
	if d.saving || from == to || from < 0 || to < 0 || from >= len(d.rows) || to >= len(d.rows) {
		return false
	}
	source, target := d.rows[from], d.rows[to]
	if source.key == "" || source.group != target.group {
		return false
	}
	if target.key == "" {
		return where == ui.TreeDropInside && target.node.folder != source.node.folder
	}
	if where == ui.TreeDropInside {
		return false
	}
	return !p.runConfigDialogSorted() || target.node.folder != source.node.folder
}

// dropRunConfigDialogRow moves a configuration where it was dropped and selects it.
func (a *App) dropRunConfigDialogRow(p *project, move ui.TreeMove) {
	d := &p.runConfigs.dialog
	if !p.runConfigDialogCanDrop(move.From, move.To, move.Where) {
		return
	}
	source, target := d.rows[move.From], d.rows[move.To]
	key := source.key
	d.moveToFolder(key, target.node.folder)
	if !p.runConfigDialogSorted() {
		order := d.displayOrder()
		at := slices.Index(order, key)
		order = slices.Delete(order, at, at+1)
		if target.key != "" {
			at = slices.Index(order, target.key)
			if move.Where == ui.TreeDropAfter {
				at++
			}
		} else {
			// Into a group or folder goes after the configurations already there.
			var section []string
			if target.node.folder != "" {
				section = d.runConfigDialogFolderKeys(target.node)
			} else {
				section = d.groups[target.group].keys
			}
			for index, existing := range order {
				if existing != key && slices.Contains(section, existing) {
					at = index + 1
				}
			}
		}
		d.order = slices.Insert(order, max(0, min(at, len(order))), key)
	}
	a.selectRunConfigDraft(p, key)
	d.reveal = true
}

// runConfigDraftLabel is the name a configuration shows in the tree: the name its form or copy
// holds, else the name it gets while the field is empty, else its saved name.
func (a *App) runConfigDraftLabel(p *project, key string) string {
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil {
		if f := draft.form; f != nil {
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
		if name := strings.TrimSpace(draft.copyName); draft.copyOf != "" && name != "" {
			return name
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
			return a.runAvailabilityText(draft.form.kind, *availability)
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

// runConfigDialogRunnable says Run can run the selected configuration once it is saved. A copy
// runs once the list shows it.
func (a *App) runConfigDialogRunnable(p *project) bool {
	d := &p.runConfigs.dialog
	draft := d.drafts[d.selected]
	if draft == nil || draft.copyOf != "" || a.runConfigDraftUnavailable(p, d.selected) != "" {
		return false
	}
	if draft.form != nil {
		return true
	}
	configuration := p.runConfigs.configuration(d.selected)
	return configuration != nil && p.runConfigurationReady(*configuration)
}

// dirty says Apply has something to save.
func (d *runConfigDialog) dirty() bool {
	if len(d.removed) > 0 || d.rearranged {
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

// applyRunConfigDialog saves what the dialog holds, one file change after another: every draft
// with something to save, the copies, the removals, then the folders, order and sort. The
// first failure stops the chain and selects the configuration it belongs to, whose editor or
// the pane shows the reason. When every step succeeded, the selected configuration becomes the
// one the title bar runs; OK then closes the dialog, and Run closes it and runs the
// configuration once the list shows what was saved. The configurations are resolved again
// either way, so what was saved before a failure shows.
func (a *App) applyRunConfigDialog(p *project, step runConfigDialogStep) {
	d := &p.runConfigs.dialog
	if !d.open || d.busy() {
		return
	}
	// The save order follows the tree, so a configuration added since the last paint saves too.
	p.collectRunConfigDialogRows(a)
	d.saving, d.failure = true, ""
	generation := d.generation
	current := func() bool { return d.generation == generation }
	failedAt := func(key, failure string) {
		if !current() {
			return
		}
		if failure != "" {
			d.failure = failure
		}
		d.selected, d.node, d.reveal = key, runConfigDialogNode{}, true
		group := p.runConfigDialogGroupKey(key)
		delete(d.closed, runConfigDialogNode{group: group})
		delete(d.closed, runConfigDialogNode{group: group, folder: p.runConfigDialogFolder(key)})
	}
	saves, copies := p.runConfigDialogSaveOrder()
	// A renamed or new configuration gets an ID the saved order does not have yet, so in a
	// list the user orders, the order the tree shows is saved with it and nothing moves.
	if !p.runConfigDialogSorted() && len(saves)+len(copies) > 0 {
		d.order, d.rearranged = d.displayOrder(), true
	}
	var tasks []runConfigDialogTask
	for _, key := range saves {
		draft := d.drafts[key]
		tasks = append(tasks, func(done func(bool)) {
			if draft.form != nil {
				a.saveRunConfigForm(p, draft.form, func(id string, ok bool) {
					if !ok {
						failedAt(draft.key, "")
						done(false)
						return
					}
					if current() {
						d.rekey(draft, id)
					}
					done(true)
				})
				return
			}
			a.saveRunConfigEditor(p, draft.editor, func(ok bool) {
				if !ok {
					failedAt(draft.key, "")
				}
				done(ok)
			})
		})
	}
	for _, key := range copies {
		draft := d.drafts[key]
		tasks = append(tasks, func(done func(bool)) {
			a.copyRunConfiguration(p, draft.copyOf, strings.TrimSpace(draft.copyName), func(id string, err error) {
				if err != nil {
					failedAt(draft.key, i18n.SharedFormat(a.language(), "desktop.runConfig.copyFailed", map[string]string{"reason": err.Error()}))
					done(false)
					return
				}
				if current() {
					d.rekey(draft, id)
					draft.copied = true
				}
				done(true)
			})
		})
	}
	for _, id := range slices.Sorted(maps.Keys(d.removed)) {
		tasks = append(tasks, func(done func(bool)) {
			a.removeRunConfiguration(p, id, func(err error) {
				if err != nil {
					if current() {
						d.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.deleteFailed", map[string]string{"reason": err.Error()})
					}
					done(false)
					return
				}
				delete(d.removed, id)
				// It stays out of the tree until the list stops showing it.
				d.hidden[id] = true
				done(true)
			})
		})
	}
	tasks = append(tasks, func(done func(bool)) {
		request, ok := p.runConfigDialogArrangement()
		if !current() || !ok {
			d.rearranged = d.rearranged && current() && ok
			done(true)
			return
		}
		a.arrangeRunConfigurations(p, request, func(err error) {
			if err != nil {
				if current() {
					d.failure = i18n.SharedFormat(a.language(), "desktop.runConfig.arrangeFailed", map[string]string{"reason": err.Error()})
				}
				done(false)
				return
			}
			if current() {
				d.rearranged = false
			}
			done(true)
		})
	})
	finish := func(ok bool) {
		if !current() {
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
		if !current() {
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

// runConfigDialogSaveOrder is the drafts with something to save and the copies to make, as
// the tree shows them, so a failure stops at the first one the user sees.
func (p *project) runConfigDialogSaveOrder() (saves, copies []string) {
	d := &p.runConfigs.dialog
	for _, key := range d.displayOrder() {
		draft := d.drafts[key]
		switch {
		case draft == nil || !draft.dirty() || slices.Contains(saves, key) || slices.Contains(copies, key):
		case draft.pendingCopy():
			copies = append(copies, key)
		default:
			saves = append(saves, key)
		}
	}
	return saves, copies
}

// runConfigDialogArrangement is the arrange request that saves the folders, the manual order
// and the sort choice the user made, for saved configurations only; false when it holds
// nothing to save.
func (p *project) runConfigDialogArrangement() (core.RunConfigArrangement, bool) {
	d := &p.runConfigs.dialog
	request := core.RunConfigArrangement{Root: p.root}
	if !d.rearranged {
		return request, false
	}
	saved := func(key string) bool {
		return !strings.HasPrefix(key, runConfigNewKey) && !d.removed[key] && !d.hidden[key]
	}
	for _, key := range slices.Sorted(maps.Keys(d.folders)) {
		if !saved(key) {
			continue
		}
		if request.Folders == nil {
			request.Folders = map[string]*string{}
		}
		var folder *string
		if name := d.folders[key]; name != "" {
			folder = &name
		}
		request.Folders[key] = folder
	}
	if !p.runConfigDialogSorted() {
		for _, key := range d.order {
			if saved(key) && !slices.Contains(request.Order, key) {
				request.Order = append(request.Order, key)
			}
		}
	}
	if d.sort != nil {
		sorted := *d.sort
		request.SortAlphabetically = &sorted
	}
	return request, request.Folders != nil || request.Order != nil || request.SortAlphabetically != nil
}

// copyRunConfiguration has Core copy configuration id under name and writes the copy; done gets
// the copy's ID.
func (a *App) copyRunConfiguration(p *project, id, name string, done func(string, error)) {
	root, kernel := p.root, a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		copied, changes, err := kernel.CopyRunConfiguration(ctx, root, id, name, a.runConfigPlugins(ctx))
		if err == nil {
			err = applyRunConfigChanges(ctx, root, changes)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("run_config_copy", err)
			}
			done(copied, err)
		}
	})
}

// arrangeRunConfigurations writes the folders, order and sort choice of request.
func (a *App) arrangeRunConfigurations(p *project, request core.RunConfigArrangement, done func(error)) {
	kernel := a.kernel
	a.background(p, buildRequestTimeout, func(ctx context.Context) func(*App) {
		request.Plugins = a.runConfigPlugins(ctx)
		changes, err := kernel.ArrangeRunConfigurations(ctx, request)
		if err == nil {
			err = applyRunConfigChanges(ctx, request.Root, changes)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("run_config_arrange", err)
			}
			done(err)
		}
	})
}

// settleRunConfigDialog brings the open dialog up to date with a new list: a copy Apply saved
// gives way to the configuration's own editor once the list shows it, and an ID the list no
// longer shows stops being hidden, so a later configuration that takes it shows.
func (a *App) settleRunConfigDialog(p *project) {
	s := &p.runConfigs
	d := &s.dialog
	if !d.open {
		return
	}
	for id := range d.hidden {
		if s.configuration(id) == nil {
			delete(d.hidden, id)
		}
	}
	for _, key := range slices.Sorted(maps.Keys(d.drafts)) {
		draft := d.drafts[key]
		if !draft.copied || s.configuration(key) == nil {
			continue
		}
		draft.close()
		delete(d.drafts, key)
		if d.selected == key {
			a.selectRunConfigDraft(p, key)
		}
	}
}

// rekey files a draft under the ID its save returned, when that differs from its key: a new
// configuration's or a copy's first save, or a rename that gave it another ID. The old ID stays
// out of the tree until the list stops showing it; its folder, place in the order and the copies
// of it move to the new ID.
func (d *runConfigDialog) rekey(draft *runConfigDraft, id string) {
	old := draft.key
	if id == "" || id == old {
		return
	}
	delete(d.drafts, old)
	draft.key, d.drafts[id] = id, draft
	delete(d.hidden, id)
	if !strings.HasPrefix(old, runConfigNewKey) {
		d.hidden[old] = true
	}
	if index := slices.Index(d.added, old); index >= 0 {
		d.added[index] = id
	} else {
		d.added = append(d.added, id)
	}
	if folder, ok := d.folders[old]; ok {
		delete(d.folders, old)
		d.folders[id] = folder
	}
	if index := slices.Index(d.order, old); index >= 0 {
		d.order[index] = id
	}
	for _, other := range d.drafts {
		if other.copyOf == old {
			other.copyOf = id
		}
	}
	if d.selected == old {
		d.selected = id
	}
	if row, ok := d.ids["c\x00"+old]; ok {
		d.ids["c\x00"+id] = row
	}
}

// runConfigDialogRowID is the tree key of a row, the same across paints: one per draft key and
// one per group and folder, numbered as they first show.
func (d *runConfigDialog) runConfigDialogRowID(row runConfigDialogRow) int {
	key := "c\x00" + row.key
	if row.key == "" {
		key = row.node.id()
	}
	id, ok := d.ids[key]
	if !ok {
		id = len(d.ids)
		d.ids[key] = id
	}
	return id
}

// runConfigDialogRowIndex is the index of the selected row among the rows as they show, -1
// when nothing is selected or the selection is in a closed group or folder.
func (d *runConfigDialog) runConfigDialogRowIndex() int {
	for index, row := range d.rows {
		if d.selected != "" {
			if row.key == d.selected {
				return index
			}
		} else if row.key == "" && d.node.group != "" && row.node == d.node {
			return index
		}
	}
	return -1
}

// toggleRunConfigDialogNode opens a closed group or folder of the tree and closes an open one.
// Closing the one that holds the selection leaves the selection on its row.
func (p *project) toggleRunConfigDialogNode(node runConfigDialogNode) {
	d := &p.runConfigs.dialog
	if d.closed[node] {
		delete(d.closed, node)
		return
	}
	if d.closed == nil {
		d.closed = map[runConfigDialogNode]bool{}
	}
	d.closed[node] = true
	switch {
	case d.selected != "":
		if p.runConfigDialogGroupKey(d.selected) == node.group && (node.folder == "" || p.runConfigDialogFolder(d.selected) == node.folder) {
			d.selectRunConfigDialogNode(node)
		}
	case node.folder == "" && d.node.group == node.group && d.node.folder != "":
		d.selectRunConfigDialogNode(node)
	}
}

// runAvailabilityText words why this platform cannot run a configuration of kind, from the
// availability Core gave its kind or its editor. Only a built-in kind is bound to a platform;
// any other reason shows Core's message.
func (a *App) runAvailabilityText(kind runConfigKind, availability core.RunAvailability) string {
	language := a.language()
	if availability.Code == "unsupportedPlatform" && !kind.declared() {
		if kind.provider == runProviderBatch {
			return i18n.Shared(language, "desktop.runConfig.unavailableBatchPlatform")
		}
		title, ok := runConfigTypeLabel(language, kind.provider)
		if !ok {
			title = kind.provider
		}
		return i18n.SharedFormat(language, "desktop.runConfig.unavailablePlatform", map[string]string{"type": title})
	}
	return i18n.SharedFormat(language, "desktop.runConfig.unavailableOther", map[string]string{"reason": availability.Message})
}
