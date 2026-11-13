package workbench

import (
	"cmp"
	"maps"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file holds the Build tool window's list of run configurations: the scope it shows (every
// configuration, the pinned ones, or those of one execution kind), the configurations of the
// scope under the build system that provides them, and what a row does. Drawing is in
// runconfig_view.go.

// runConfigPinsFile is the data-store file of the pinned run configurations: the sorted
// configuration ids of each project, keyed by its root. The pins are the client's own state
// and are never written into the project.
const runConfigPinsFile = "run-configuration-pins.json"

// runScopePinned is the scope of the pinned configurations. The empty scope is every
// configuration, and any other one the execution kind Core gives a configuration.
const runScopePinned = ":pinned"

// runExecutions are the execution kinds that have a scope of their own, in the order the
// scopes show. A configuration of a kind not listed shows under every configuration only.
var runExecutions = []string{"service", "application", "task", "group"}

// runExecutionTitle is the title of the scope of an execution kind, "" for a kind without one.
func runExecutionTitle(language i18n.Language, execution string) string {
	switch execution {
	case "service":
		return i18n.Shared(language, "native.services")
	case "application":
		return i18n.Shared(language, "native.applications")
	case "task":
		return i18n.Shared(language, "native.tasks")
	case "group":
		return i18n.Shared(language, "native.groups")
	}
	return ""
}

// Heights of the list in the Build window: as it first shows, and the least of it and of the
// build tree under it, its filter field and a few rows.
const (
	runConfigListHeight = 168
	runConfigListMin    = 72
	runConfigRestMin    = buildRowHeight + 96
)

// runConfigBrowser is the state of the list of run configurations. Only the window thread
// reads or writes it.
type runConfigBrowser struct {
	// scope is the scope the list shows; see runScopePinned.
	scope string
	// pins are the pinned configuration ids, read from the data store once the first
	// configurations resolve. An id stays pinned while its configuration is not listed, so a
	// configuration that comes back with its build model keeps its pin.
	pins       map[string]bool
	pinsLoaded bool
	// closed are the groups the user closed, by key, and group the key of the selected group
	// while a group's row rather than a configuration is selected.
	closed map[string]bool
	group  string
	// groups and rows are the list as it shows, collected on each paint.
	groups []runConfigGroup
	rows   []runConfigRow
	view   ui.ListState
	split  ui.SplitterState
}

// runConfigGroup is the configurations of one build system in the scope, as indexes into the
// resolved list, sorted by name.
type runConfigGroup struct {
	key, title     string
	configurations []int
}

// runConfigRow is one row of the list: a group's, with configuration -1, or a configuration
// under it, at its index in the resolved list.
type runConfigRow struct {
	group, configuration int
}

// runConfigGroupKey names the build system that provides a configuration: its plugin and
// build system, whatever root the system was detected at.
func runConfigGroupKey(configuration *core.RunConfiguration) string {
	reference, _ := configuration.BuildReference()
	return reference.PluginID + "\x00" + reference.BuildSystemID
}

// inScope reports whether configuration shows in scope.
func (b *runConfigBrowser) inScope(configuration *core.RunConfiguration, scope string) bool {
	switch scope {
	case "":
		return true
	case runScopePinned:
		return b.pins[configuration.ID]
	}
	return configuration.Execution == scope
}

// scopes are the scopes the picker offers: every configuration, the pinned ones, and each
// execution kind with a scope that some configuration has.
func (s *runConfigState) scopes() []string {
	scopes := []string{"", runScopePinned}
	for _, execution := range runExecutions {
		if slices.ContainsFunc(s.list, func(c core.RunConfiguration) bool { return c.Execution == execution }) {
			scopes = append(scopes, execution)
		}
	}
	return scopes
}

// scopeCount is how many configurations show in scope.
func (s *runConfigState) scopeCount(scope string) int {
	count := 0
	for index := range s.list {
		if s.browser.inScope(&s.list[index], scope) {
			count++
		}
	}
	return count
}

// runScopeLabel is the picker's text of a scope: its title and how many configurations it
// shows.
func (a *App) runScopeLabel(s *runConfigState, scope string) string {
	language := a.language()
	title := runExecutionTitle(language, scope)
	switch scope {
	case "":
		title = i18n.Shared(language, "native.allConfigurations")
	case runScopePinned:
		title = i18n.Shared(language, "native.pinned")
	}
	return i18n.SharedFormat(language, "native.lld.variant2", map[string]string{"arg1": title, "arg2": strconv.Itoa(s.scopeCount(scope))})
}

// collectRunConfigRows groups the configurations of the scope under their build systems, the
// groups by title and the configurations by name, and lists the rows as they show: each
// group, then its configurations unless the user closed it.
func (p *project) collectRunConfigRows() {
	s := &p.runConfigs
	b := &s.browser
	b.groups, b.rows = b.groups[:0], b.rows[:0]
	for index := range s.list {
		configuration := &s.list[index]
		if !b.inScope(configuration, b.scope) {
			continue
		}
		key := runConfigGroupKey(configuration)
		g := slices.IndexFunc(b.groups, func(group runConfigGroup) bool { return group.key == key })
		if g < 0 {
			g = len(b.groups)
			b.groups = append(b.groups, runConfigGroup{key: key, title: p.runConfigGroupTitle(configuration)})
		}
		b.groups[g].configurations = append(b.groups[g].configurations, index)
	}
	slices.SortStableFunc(b.groups, func(x, y runConfigGroup) int {
		return cmp.Or(strings.Compare(strings.ToLower(x.title), strings.ToLower(y.title)), strings.Compare(x.key, y.key))
	})
	for g := range b.groups {
		group := &b.groups[g]
		slices.SortStableFunc(group.configurations, func(x, y int) int {
			return cmp.Or(strings.Compare(strings.ToLower(s.list[x].Name), strings.ToLower(s.list[y].Name)), strings.Compare(s.list[x].ID, s.list[y].ID))
		})
		b.rows = append(b.rows, runConfigRow{group: g, configuration: -1})
		if b.closed[group.key] {
			continue
		}
		for _, index := range group.configurations {
			b.rows = append(b.rows, runConfigRow{group: g, configuration: index})
		}
	}
}

// runConfigGroupTitle is the title of the group of a configuration: the name its detected
// build system gives itself, else the build system's identity.
func (p *project) runConfigGroupTitle(configuration *core.RunConfiguration) string {
	reference, _ := configuration.BuildReference()
	if index := p.buildInstanceIndex(reference); index >= 0 && p.build.instances[index].System.DisplayName != "" {
		return p.build.instances[index].System.DisplayName
	}
	return reference.BuildSystemID
}

// selectedRunConfigRow is the index of the selected row among the rows as they show, -1 when
// the selection is hidden in a closed group or outside the scope.
func (p *project) selectedRunConfigRow() int {
	s := &p.runConfigs
	b := &s.browser
	for index, row := range b.rows {
		if row.configuration < 0 {
			if b.group != "" && b.groups[row.group].key == b.group {
				return index
			}
		} else if b.group == "" && s.list[row.configuration].ID == s.selected {
			return index
		}
	}
	return -1
}

// toggleRunConfigGroup closes the group key when it is open and opens it when it is closed.
// Closing the group of the selected configuration leaves the selection on the group's row.
func (s *runConfigState) toggleRunConfigGroup(key string) {
	b := &s.browser
	if b.closed[key] {
		delete(b.closed, key)
		return
	}
	if b.closed == nil {
		b.closed = map[string]bool{}
	}
	b.closed[key] = true
	if configuration := s.configuration(s.selected); b.group == "" && configuration != nil && runConfigGroupKey(configuration) == key {
		b.group = key
	}
}

// runningConfiguration is the run configuration the Build window's operation runs, "" when it
// runs none.
func (p *project) runningConfiguration() string {
	if p.build.operation == nil {
		return ""
	}
	return p.build.operation.configuration
}

// loadRunConfigPins reads the pinned configurations of the project the first time its
// configurations resolve. A store that cannot be read leaves nothing pinned and says why.
func (a *App) loadRunConfigPins(p *project) {
	b := &p.runConfigs.browser
	if b.pinsLoaded {
		return
	}
	b.pinsLoaded, b.pins = true, map[string]bool{}
	if a.store == nil {
		return
	}
	all := map[string][]string{}
	if _, err := a.store.Load(runConfigPinsFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("run_configuration_pins_load", documentLogError(err)))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.runConfig.loadFailed", map[string]string{"reason": err.Error()}))
		return
	}
	for _, id := range all[filepath.Clean(p.root)] {
		b.pins[id] = true
	}
}

// toggleRunConfigPin pins configuration id when it is not pinned and unpins it when it is, and
// writes the project's pins into the data store. A failed write keeps the pins as they were.
func (a *App) toggleRunConfigPin(p *project, id string) {
	b := &p.runConfigs.browser
	pins := maps.Clone(b.pins)
	if pins == nil {
		pins = map[string]bool{}
	}
	if pins[id] {
		delete(pins, id)
	} else {
		pins[id] = true
	}
	if err := a.storeRunConfigPins(p.root, pins); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("run_configuration_pins_save", documentLogError(err)))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()}))
		return
	}
	b.pins = pins
}

// storeRunConfigPins writes the pins of the project at root, dropping the project from the
// file when none is pinned.
func (a *App) storeRunConfigPins(root string, pins map[string]bool) error {
	if a.store == nil {
		return nil
	}
	all := map[string][]string{}
	if _, err := a.store.Load(runConfigPinsFile, &all); err != nil {
		return err
	}
	key := filepath.Clean(root)
	if len(pins) == 0 {
		delete(all, key)
	} else {
		all[key] = slices.Sorted(maps.Keys(pins))
	}
	return a.store.Save(runConfigPinsFile, all)
}

// runExecutionIcon is the icon of a configuration's execution kind.
func runExecutionIcon(execution string) gfx.Icon {
	switch execution {
	case "service":
		return icons.Server
	case "application":
		return icons.SquareTerminal
	case "task":
		return icons.Wrench
	case "group":
		return icons.LayoutGrid
	}
	return icons.Play
}
