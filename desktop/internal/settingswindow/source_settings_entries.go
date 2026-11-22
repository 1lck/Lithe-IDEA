package settingswindow

import (
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// maximumSourceEntries is the contract's bound on one entryList; the add menu
// stops offering entries past it rather than letting Save fail.
const maximumSourceEntries = 256

// sourceRowKind says what a row of a source form's list shows.
type sourceRowKind uint8

const (
	sourceRowGroup  sourceRowKind = iota // a group's heading (and a table's add control)
	sourceRowTable                       // one source of a table group
	sourceRowField                       // one field of a form or sidebar source
	sourceRowEntry                       // one entry of the entryList field above it
	sourceRowModule                      // the selected sidebar source's name and file
	sourceRowTabs                        // the selected sidebar source's sections
)

type sourceSettingsRow struct {
	kind   sourceRowKind
	group  int
	source int
	field  int
	entry  int
	// heading is the section a form field starts, shown above it.
	heading string
}

// sourceNavItem is a row of the module list beside a form with a sidebar group:
// a sidebar group's heading, one of its sources, or a whole other group.
type sourceNavItem struct {
	group   int
	source  int // -1 for a heading or a whole group
	depth   int
	heading bool
}

// sourceEntryChooser is the dialog that adds entries of a choice kind.
type sourceEntryChooser struct {
	path          string
	open          bool
	source, field string
	kind          int
	picked        []bool
	list          ui.ListState
}

func cloneSourceInput(input core.SourceSettingInput) core.SourceSettingInput {
	entries := make([]core.SourceEntry, len(input.Entries))
	for index, entry := range input.Entries {
		entries[index] = cloneSourceEntry(entry)
	}
	input.Entries = entries
	return input
}

func cloneSourceEntry(entry core.SourceEntry) core.SourceEntry {
	if entry.Attributes != nil {
		attributes := make(map[string]any, len(entry.Attributes))
		for id, value := range entry.Attributes {
			attributes[id] = value
		}
		entry.Attributes = attributes
	}
	return entry
}

// sameSourceInput compares drafts as Core does: entry display text never makes
// two drafts differ.
func sameSourceInput(a, b core.SourceSettingInput) bool {
	if a.Text != b.Text || a.Choice != b.Choice || a.On != b.On || a.Inherit != b.Inherit || len(a.Entries) != len(b.Entries) {
		return false
	}
	for index := range a.Entries {
		x, y := a.Entries[index], b.Entries[index]
		if x.Kind != y.Kind || x.Value != y.Value || len(x.Attributes) != len(y.Attributes) {
			return false
		}
		for id, value := range x.Attributes {
			if other, ok := y.Attributes[id]; !ok || other != value {
				return false
			}
		}
	}
	return true
}

func entryKindIndex(field core.SourceSettingField, kind string) int {
	for index, candidate := range field.EntryKinds {
		if candidate.ID == kind {
			return index
		}
	}
	return -1
}

// entryLabel is what an entry's row shows: the plugin's title, else the value.
func entryLabel(entry core.SourceEntry) string {
	if entry.Title != "" {
		return entry.Title
	}
	return entry.Value
}

// entryBool is a boolean attribute; absent, the plugin's default, shown as off.
// Core admits only booleans for a boolean attribute.
func entryBool(entry core.SourceEntry, id string) bool {
	on, _ := entry.Attributes[id].(bool)
	return on
}

// entryChoice is an enum attribute's value; absent, the plugin's default, which
// the host shows as the first option.
func entryChoice(entry core.SourceEntry, attribute core.SourceEntryAttribute) string {
	if value, ok := entry.Attributes[attribute.ID].(string); ok {
		return value
	}
	if len(attribute.Options) > 0 {
		return attribute.Options[0].Value
	}
	return ""
}

func setEntryAttribute(entry *core.SourceEntry, id string, value any) {
	if entry.Attributes == nil {
		entry.Attributes = make(map[string]any)
	}
	entry.Attributes[id] = value
}

func hasEntry(entries []core.SourceEntry, kind, value string) bool {
	for _, entry := range entries {
		if entry.Kind == kind && entry.Value == value {
			return true
		}
	}
	return false
}

// pathEntries turns the paths a native picker returned into entries of kind,
// skipping ones the list already holds and any past the contract's bound.
func pathEntries(existing []core.SourceEntry, kind string, paths []string) []core.SourceEntry {
	var added []core.SourceEntry
	for _, path := range paths {
		if path == "" || hasEntry(existing, kind, path) || hasEntry(added, kind, path) || len(existing)+len(added) >= maximumSourceEntries {
			continue
		}
		added = append(added, core.SourceEntry{Kind: kind, Value: path, Title: filepath.Base(path), Detail: filepath.Dir(path)})
	}
	return added
}

// choiceEntries is the choices of kind the list does not hold yet, by index.
func choiceEntries(field core.SourceSettingField, kind int, entries []core.SourceEntry) []int {
	var available []int
	for index, choice := range field.EntryKinds[kind].Choices {
		if !hasEntry(entries, field.EntryKinds[kind].ID, choice.Value) {
			available = append(available, index)
		}
	}
	return available
}

// editEntries applies one change to an entryList draft. A draft that holds a
// list is an explicit value, even an empty one.
func (p *sourceSettingsForm) editEntries(source string, field core.SourceSettingField, edit func(*sourceSettingControl)) {
	control := p.controls[source][field.ID]
	edit(control)
	control.input.Inherit = false
	if control.entry >= len(control.input.Entries) {
		control.entry = len(control.input.Entries) - 1
	}
	control.syncAttributes(field)
	p.changed(source, field.ID)
	p.layoutDirty = true
}

func (p *sourceSettingsForm) addEntries(source string, field core.SourceSettingField, entries []core.SourceEntry) {
	if len(entries) == 0 {
		return
	}
	p.editEntries(source, field, func(control *sourceSettingControl) {
		control.input.Entries = append(control.input.Entries, entries...)
		control.entry = len(control.input.Entries) - 1
	})
}

func (p *sourceSettingsForm) removeEntry(source string, field core.SourceSettingField) {
	p.editEntries(source, field, func(control *sourceSettingControl) {
		if index := control.entry; index >= 0 && index < len(control.input.Entries) {
			control.input.Entries = append(control.input.Entries[:index], control.input.Entries[index+1:]...)
		}
	})
}

func (p *sourceSettingsForm) moveEntry(source string, field core.SourceSettingField, by int) {
	p.editEntries(source, field, func(control *sourceSettingControl) {
		from, to := control.entry, control.entry+by
		if from < 0 || to < 0 || to >= len(control.input.Entries) {
			return
		}
		entries := control.input.Entries
		entries[from], entries[to] = entries[to], entries[from]
		control.entry = to
	})
}

// navigation lists the module list of a form that has a sidebar group, and keeps
// the selection on an item that still exists; a form without one has no list.
func (p *sourceSettingsForm) navigation() {
	snapshot := &p.editor.State.Snapshot
	p.nav = p.nav[:0]
	sidebar := false
	for _, section := range p.editor.State.Layout {
		sidebar = sidebar || snapshot.Groups[section.Group].Layout == "sidebar"
	}
	if !sidebar {
		return
	}
	depths := make(map[string]int)
	for _, section := range p.editor.State.Layout {
		if snapshot.Groups[section.Group].Layout != "sidebar" {
			p.nav = append(p.nav, sourceNavItem{group: section.Group, source: -1})
			continue
		}
		p.nav = append(p.nav, sourceNavItem{group: section.Group, source: -1, heading: true})
		for _, index := range section.Sources {
			source := snapshot.Sources[index]
			depth := 0
			if parent, ok := depths[source.Parent]; ok && source.Parent != "" {
				depth = parent + 1
			}
			depths[source.ID] = depth
			p.nav = append(p.nav, sourceNavItem{group: section.Group, source: index, depth: depth + 1})
		}
	}
	for _, item := range p.nav {
		if !item.heading && p.navSelected(item) {
			return
		}
	}
	for _, item := range p.nav {
		if !item.heading {
			p.selectNav(item)
			return
		}
	}
}

func (p *sourceSettingsForm) navSelected(item sourceNavItem) bool {
	snapshot := &p.editor.State.Snapshot
	if snapshot.Groups[item.group].ID != p.selectedGroup {
		return false
	}
	if item.source < 0 {
		return p.selectedSource == ""
	}
	return snapshot.Sources[item.source].ID == p.selectedSource
}

func (p *sourceSettingsForm) selectNav(item sourceNavItem) {
	snapshot := &p.editor.State.Snapshot
	p.selectedGroup, p.selectedSource = snapshot.Groups[item.group].ID, ""
	if item.source >= 0 {
		p.selectedSource = snapshot.Sources[item.source].ID
	}
	p.layoutDirty = true
}

// sections is the tabs of a sidebar source, in order of first appearance.
func sourceSections(source core.SettingsSource) []string {
	var sections []string
	seen := make(map[string]bool)
	for _, field := range source.Fields {
		if field.Section != "" && !seen[field.Section] {
			seen[field.Section] = true
			sections = append(sections, field.Section)
		}
	}
	return sections
}

// fieldRows appends a source's fields, each entryList followed by its entries.
// A field that starts a section of a form carries it as its heading.
func (p *sourceSettingsForm) fieldRows(group, sourceIndex int, include func(core.SourceSettingField) bool, headings bool) {
	source := p.editor.State.Snapshot.Sources[sourceIndex]
	previous := ""
	for fieldIndex, field := range source.Fields {
		if !include(field) {
			continue
		}
		row := sourceSettingsRow{kind: sourceRowField, group: group, source: sourceIndex, field: fieldIndex, entry: -1}
		if headings && field.Section != previous {
			row.heading = field.Section
		}
		previous = field.Section
		p.rows = append(p.rows, row)
		if field.Kind == "entryList" {
			for entry := range p.controls[source.ID][field.ID].input.Entries {
				p.rows = append(p.rows, sourceSettingsRow{kind: sourceRowEntry, group: group, source: sourceIndex, field: fieldIndex, entry: entry})
			}
		}
	}
}
