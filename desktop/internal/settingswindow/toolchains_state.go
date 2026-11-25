package settingswindow

import (
	"context"
	"errors"
	"hash/fnv"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// The two scopes the Toolchains page edits: the machine's defaults and the open project's pins.
const (
	scopeGlobal  = "global"
	scopeProject = "project"
)

// toolchainIssueLimit is how many problems the Build page lists before it links to the
// Toolchains list.
const toolchainIssueLimit = 5

// toolchainScope is one scope's half of the Toolchains page: the snapshot Core read for it and
// the user's choices that are not applied yet. Only the window thread touches it.
type toolchainScope struct {
	name       string
	loadEffect *ui.EffectState[toolchain.Snapshot, int]
	// loadKey names the read in flight or last made; zero means none was made.
	loadKey int
	loading bool
	loaded  bool
	failed  error
	// stale asks for a re-read the next time the scope shows, after a write elsewhere changed
	// what it inherits.
	stale    bool
	snapshot toolchain.Snapshot
	// draft maps a tool ID to the home the user chose; "" asks for the inherited or automatic
	// layers. A tool whose choice equals the saved pin has no entry.
	draft map[string]string
	// custom holds the directories the user checked, by tool, in the order they were checked.
	// They list as candidates until the scope's next write, which registers every one of them
	// in the machine catalog.
	custom map[string][]core.ToolchainPin
	// inputs are the add-directory fields' bound values, one per tool.
	inputs map[string]*string
	// revision changes with the snapshot and the draft, so the list's projection runs again.
	revision int
}

func newToolchainScope(name string) *toolchainScope {
	return &toolchainScope{name: name, draft: make(map[string]string), custom: make(map[string][]core.ToolchainPin), inputs: make(map[string]*string)}
}

// saved is the home the scope's document pins for the tool, empty when it pins none.
func (s *toolchainScope) saved(id string) string {
	if tool := s.tool(id); tool != nil && tool.Pin != nil {
		return tool.Pin.Home
	}
	return ""
}

// wanted is the tool's pin as it will be after the scope applies: the draft if there is one.
func (s *toolchainScope) wanted(id string) string {
	if home, ok := s.draft[id]; ok {
		return home
	}
	return s.saved(id)
}

func (s *toolchainScope) changed(id string) bool {
	_, ok := s.draft[id]
	return ok
}

func (s *toolchainScope) tool(id string) *toolchain.Tool {
	for index := range s.snapshot.Tools {
		if s.snapshot.Tools[index].ID == id {
			return &s.snapshot.Tools[index]
		}
	}
	return nil
}

// choose records the user's choice of a home; choosing the saved pin drops the draft.
func (s *toolchainScope) choose(id, home string) {
	tool := s.tool(id)
	if tool == nil || tool.ManagedOnly {
		return
	}
	if home == s.saved(id) {
		delete(s.draft, id)
	} else {
		s.draft[id] = home
	}
	s.revision++
}

func (s *toolchainScope) undo(id string) {
	if _, ok := s.draft[id]; ok {
		delete(s.draft, id)
		s.revision++
	}
}

func (s *toolchainScope) input(id string) *string {
	if s.inputs[id] == nil {
		s.inputs[id] = new(string)
	}
	return s.inputs[id]
}

// apply takes a snapshot Core read. A read keeps the user's drafts that still differ from the
// saved pins; a write clears them, because the snapshot now holds what they asked for.
func (s *toolchainScope) apply(snapshot toolchain.Snapshot, written bool) {
	s.snapshot, s.loaded, s.stale, s.failed = snapshot, true, false, nil
	s.revision++
	if written {
		s.draft = make(map[string]string)
		s.custom = make(map[string][]core.ToolchainPin)
		s.inputs = make(map[string]*string)
		return
	}
	for id, home := range s.draft {
		if s.tool(id) == nil || home == s.saved(id) {
			delete(s.draft, id)
		}
	}
}

// pinFor is the pin that selects home for the tool, from the candidates the scope knows. A
// candidate without a version cannot be pinned.
func (s *toolchainScope) pinFor(tool *toolchain.Tool, home string) (core.ToolchainPin, bool) {
	for _, pin := range s.custom[tool.ID] {
		if pin.Home == home {
			return pin, true
		}
	}
	if tool.Pin != nil && tool.Pin.Home == home && tool.Pin.Version != "" {
		return *tool.Pin, true
	}
	for _, installation := range tool.Installations {
		if installation.Home == home && installation.Version != "" {
			return core.ToolchainPin{Home: installation.Home, Version: installation.Version, Provider: installation.Provider}, true
		}
	}
	// A shell or project environment's home is a directory the user can name too; pinning it
	// records it as one they chose.
	for _, shell := range tool.Shell {
		if shell.Home == home && shell.Version != nil && shell.Reason == "" {
			return core.ToolchainPin{Home: home, Version: *shell.Version, Provider: "host:manual"}, true
		}
	}
	if s.name == scopeProject {
		for _, project := range tool.Project {
			if project.Home == home && project.Version != nil && project.Reason == "" {
				return core.ToolchainPin{Home: home, Version: *project.Version, Provider: "host:manual"}, true
			}
		}
	}
	if s.name == scopeGlobal && tool.Pin != nil && tool.Pin.Home == home {
		// The machine default records a home only.
		return *tool.Pin, true
	}
	return core.ToolchainPin{}, false
}

// edits builds one pin change per tool with a draft, in the snapshot's order.
func (s *toolchainScope) edits() []toolchain.Edit {
	var edits []toolchain.Edit
	for index := range s.snapshot.Tools {
		tool := &s.snapshot.Tools[index]
		wanted, ok := s.draft[tool.ID]
		if !ok {
			continue
		}
		if wanted == "" {
			edits = append(edits, toolchain.Edit{Tool: tool.ID})
			continue
		}
		if pin, ok := s.pinFor(tool, wanted); ok {
			edits = append(edits, toolchain.Edit{Tool: tool.ID, Pin: &pin})
		}
	}
	return edits
}

// saveSnapshot is the snapshot a write starts from. The machine catalog lists the homes
// discovery does not find, so the write registers every directory the user checked for an
// edited tool, the chosen one and the others, and a default on such a home in the same write.
func (s *toolchainScope) saveSnapshot(edits []toolchain.Edit) toolchain.Snapshot {
	snapshot := s.snapshot
	if s.name != scopeGlobal {
		return snapshot
	}
	snapshot.Tools = slices.Clone(snapshot.Tools)
	for _, edit := range edits {
		for index := range snapshot.Tools {
			tool := &snapshot.Tools[index]
			if tool.ID != edit.Tool {
				continue
			}
			var homes []string
			for _, pin := range s.custom[tool.ID] {
				homes = append(homes, pin.Home)
			}
			if edit.Pin != nil {
				homes = append(homes, edit.Pin.Home)
			}
			for _, home := range homes {
				known := slices.Contains(tool.CustomHomes, home)
				for _, installation := range tool.Installations {
					known = known || installation.Home == home
				}
				if !known {
					tool.CustomHomes = append(slices.Clone(tool.CustomHomes), home)
				}
			}
		}
	}
	return snapshot
}

// toolchainEntry is one line of the Toolchains list: a tool Core resolved, or a tool ID two
// plugins declare, which Core does not resolve.
type toolchainEntry struct {
	tool     toolchain.Tool
	conflict []string
}

// toolchainWant names one projection of the list. It is comparable, so a paint asks again only
// when something it depends on changed.
type toolchainWant struct {
	scope    string
	revision int
	text     string
	filter   string
	groupBy  string
	folds    string
	issues   int
}

type toolchainProjected struct {
	want    toolchainWant
	view    core.ToolchainSettingsView
	entries []toolchainEntry
}

type toolchainProjectionJob struct {
	want    toolchainWant
	request core.ToolchainSettingsViewRequest
	entries []toolchainEntry
}

// toolchainProjection asks Core to filter, group, fold and count the list off the window thread.
// The window writes the job under the lock before it changes the Effect's key; the run reads
// it under the same lock, so a request that replaced it never mixes with its inputs.
type toolchainProjection struct {
	effect    *ui.EffectState[toolchainProjected, toolchainWant]
	mu        sync.Mutex
	job       toolchainProjectionJob
	want      toolchainWant
	requested bool
	// ready is set once a projection arrived; view and entries are then the last one, which
	// stays shown while the next runs, and got names it.
	ready   bool
	got     toolchainWant
	view    core.ToolchainSettingsView
	entries []toolchainEntry
	failed  error
}

func newToolchainProjection(viewer ToolchainViewer) *toolchainProjection {
	p := &toolchainProjection{}
	if viewer == nil {
		return p
	}
	p.effect = ui.NewEffect[toolchainProjected, toolchainWant](func(ctx context.Context) (toolchainProjected, error) {
		p.mu.Lock()
		job := p.job
		p.mu.Unlock()
		view, err := viewer.SettingsView(ctx, job.request)
		return toolchainProjected{want: job.want, view: view, entries: job.entries}, err
	})
	return p
}

// request asks for the projection want names; entries and request are built only when it changed.
func (p *toolchainProjection) request(want toolchainWant, build func() (core.ToolchainSettingsViewRequest, []toolchainEntry)) {
	if p.requested && p.want == want {
		return
	}
	request, entries := build()
	p.want, p.requested = want, true
	if p.effect == nil {
		// Without Core's projection the list is every entry, unsorted and unclassified.
		rows := make([]core.ToolchainSettingsRow, len(entries))
		for index := range entries {
			rows[index] = core.ToolchainSettingsRow{Kind: "tool", Index: index}
		}
		p.view = core.ToolchainSettingsView{Rows: rows, Counts: core.ToolchainSettingsCounts{Total: len(entries), Matched: len(entries)}}
		p.entries, p.ready, p.got, p.failed = entries, true, want, nil
		return
	}
	p.mu.Lock()
	p.job = toolchainProjectionJob{want: want, request: request, entries: entries}
	p.mu.Unlock()
}

func (p *toolchainProjection) declare(c ui.C) {
	if p.effect != nil && p.requested {
		ui.Effect(c, p.effect, p.want)
	}
}

func (p *toolchainProjection) take() {
	if p.effect == nil {
		return
	}
	result, err, ok := p.effect.Take()
	if !ok || result.want != p.want {
		return
	}
	if err != nil {
		p.failed = err
		return
	}
	p.view, p.entries, p.ready, p.got, p.failed = result.view, result.entries, true, result.want, nil
}

// entry is the list entry a projected row names, or nil for a group or a row out of range.
func (p *toolchainProjection) entry(row core.ToolchainSettingsRow) *toolchainEntry {
	if row.Kind != "tool" || row.Index < 0 || row.Index >= len(p.entries) {
		return nil
	}
	return &p.entries[row.Index]
}

// toolchainState is the Toolchains page: both scopes, the write, check and trust requests, and
// the list's query. Only the window thread reads or writes the fields; each request is a page
// Effect whose key changes when it is made, and the window takes what finished at the start of
// a paint.
type toolchainState struct {
	loader ToolchainLoader
	scopes map[string]*toolchainScope
	// order lists the scopes the loader reads, global first.
	order []string
	scope string

	saveEffect   *ui.EffectState[toolchain.Snapshot, int]
	saveKey      int
	saveScope    string
	saveSnapshot toolchain.Snapshot
	saveEdits    []toolchain.Edit
	saving       bool

	inspectEffect            *ui.EffectState[core.ToolchainSelection, int]
	inspectKey               int
	inspectScope             string
	inspectSnapshot          toolchain.Snapshot
	inspectTool, inspectHome string
	inspecting               bool

	trustEffect   *ui.EffectState[toolchain.Snapshot, int]
	trustKey      int
	trustSnapshot toolchain.Snapshot
	trustWanted   bool
	trusting      bool

	runtimeEffect    *ui.EffectState[toolchain.Snapshot, int]
	runtimeKey       int
	runtimeScope     string
	runtimeSnapshot  toolchain.Snapshot
	runtimeTool      toolchain.Tool
	preparingRuntime bool
	runtimeProgress  atomic.Pointer[pluginruntime.Progress]
	invalidate       func()

	// failed is the last write, check or trust request's error; a read's error is its scope's.
	failed error

	// locations is the Trusted Locations page, which writes the same catalog file.
	locations *trustedLocationsState
	// remote is the Remote Workspaces card of the same page. Its document is a file of its own,
	// so busy() does not include its requests.
	remote *remoteTrustState
	// prefs is the Remote Workspace page; its document is a file of its own too.
	prefs *remotePreferencesState

	// The list's query and the page's selection.
	query    string
	filter   string
	groupBy  string
	folds    map[string]bool
	selected string
	adding   string
	whyOpen  bool
	list     ui.ListState

	view, search *toolchainProjection
}

func newToolchainState(loader ToolchainLoader) *toolchainState {
	t := &toolchainState{loader: loader, scopes: make(map[string]*toolchainScope), filter: "all", groupBy: "category", folds: make(map[string]bool)}
	viewer, _ := loader.(ToolchainViewer)
	t.view, t.search = newToolchainProjection(viewer), newToolchainProjection(viewer)
	t.locations = newTrustedLocationsState(t, loader)
	t.remote = newRemoteTrustState(loader)
	t.prefs = newRemotePreferencesState(loader)
	if loader == nil {
		return t
	}
	scoped, ok := loader.(ToolchainScopedLoader)
	if ok {
		t.order = []string{scopeGlobal, scopeProject}
	} else {
		t.order = []string{scopeProject}
	}
	t.scope = t.order[0]
	for _, name := range t.order {
		scope := newToolchainScope(name)
		scope.loadEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			if scoped != nil {
				return scoped.LoadScope(ctx, name)
			}
			return loader.Load(ctx)
		})
		t.scopes[name] = scope
	}
	t.saveEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
		return loader.Save(ctx, t.saveSnapshot, t.saveEdits)
	})
	if inspector, ok := loader.(ToolchainInspector); ok {
		t.inspectEffect = ui.NewEffect[core.ToolchainSelection, int](func(ctx context.Context) (core.ToolchainSelection, error) {
			ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			defer cancel()
			return inspector.Inspect(ctx, t.inspectSnapshot, t.inspectTool, t.inspectHome)
		})
	}
	if truster, ok := loader.(ToolchainTrustLoader); ok {
		t.trustEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			return truster.SetWorkspaceTrust(ctx, t.trustSnapshot, t.trustWanted)
		})
	}
	if preparer, ok := loader.(ToolchainRuntimePreparer); ok {
		t.runtimeEffect = ui.NewEffect[toolchain.Snapshot, int](func(ctx context.Context) (toolchain.Snapshot, error) {
			return preparer.PrepareRuntime(ctx, t.runtimeScope, t.runtimeSnapshot, t.runtimeTool, func(progress pluginruntime.Progress) {
				t.runtimeProgress.Store(&progress)
				if t.invalidate != nil {
					t.invalidate()
				}
			})
		})
	}
	return t
}

func (t *toolchainState) available() bool {
	return t.loader != nil
}

// current is the scope the page shows.
func (t *toolchainState) current() *toolchainScope {
	return t.scopes[t.scope]
}

func (t *toolchainState) busy() bool {
	if t.saving || t.inspecting || t.trusting || t.preparingRuntime || t.locations.busy() {
		return true
	}
	for _, scope := range t.scopes {
		if scope.loading {
			return true
		}
	}
	return false
}

// ensureLoaded reads the shown scope when it has no snapshot, then the other one, so the scope
// switch and the footer know both. Reads wait for whatever request is out.
func (t *toolchainState) ensureLoaded() {
	if t.loader == nil || t.busy() {
		return
	}
	if scope := t.current(); (!scope.loaded || scope.stale) && scope.failed == nil {
		t.beginLoad(scope)
		return
	}
	for _, name := range t.order {
		if scope := t.scopes[name]; !scope.loaded && scope.failed == nil {
			t.beginLoad(scope)
			return
		}
	}
}

func (t *toolchainState) beginLoad(scope *toolchainScope) {
	if scope == nil || t.busy() {
		return
	}
	scope.loadKey++
	scope.loading, scope.failed = true, nil
}

// reload reads the shown scope again without writing anything.
func (t *toolchainState) reload() {
	t.failed = nil
	t.beginLoad(t.current())
}

// noProject reports that the project scope read no project, so it has nothing to edit.
func (t *toolchainState) noProject() bool {
	scope := t.scopes[scopeProject]
	return scope != nil && scope.loaded && scope.snapshot.Root == ""
}

// projectName is the open project's folder name, empty until the project scope read one.
func (t *toolchainState) projectName() string {
	if scope := t.scopes[scopeProject]; scope != nil && scope.snapshot.Root != "" {
		return filepath.Base(scope.snapshot.Root)
	}
	return ""
}

// setScope shows another scope; the drafts of both stay.
func (t *toolchainState) setScope(name string) {
	if t.scopes[name] == nil || name == t.scope {
		return
	}
	t.scope, t.adding = name, ""
}

// drafts counts the tools with an unapplied choice in the scope.
func (t *toolchainState) drafts(name string) int {
	if scope := t.scopes[name]; scope != nil {
		return len(scope.draft)
	}
	return 0
}

// beginSave writes the scope's drafts. Every edit goes through the same Core-validated document
// merge; a conflict keeps the drafts.
func (t *toolchainState) beginSave(name string) bool {
	scope := t.scopes[name]
	if scope == nil || !scope.loaded || t.busy() {
		return false
	}
	edits := scope.edits()
	if len(edits) == 0 {
		return false
	}
	t.saveScope, t.saveSnapshot, t.saveEdits = name, scope.saveSnapshot(edits), edits
	t.saveKey++
	t.saving, t.failed = true, nil
	return true
}

func (t *toolchainState) beginInspect(tool, home string) {
	scope := t.current()
	if t.inspectEffect == nil || t.busy() || scope == nil || !scope.loaded || home == "" {
		return
	}
	t.inspectScope, t.inspectSnapshot, t.inspectTool, t.inspectHome = scope.name, scope.snapshot, tool, home
	t.inspectKey++
	t.inspecting, t.failed = true, nil
}

func (t *toolchainState) beginTrust(trusted bool) {
	scope := t.scopes[scopeProject]
	if t.trustEffect == nil || t.busy() || scope == nil || !scope.loaded || scope.snapshot.Global || scope.snapshot.Root == "" {
		return
	}
	t.trustSnapshot, t.trustWanted = scope.snapshot, trusted
	t.trustKey++
	t.trusting, t.failed = true, nil
}

func (t *toolchainState) beginPrepareRuntime(tool toolchain.Tool) {
	scope := t.current()
	if t.runtimeEffect == nil || t.busy() || scope == nil || !scope.loaded || !tool.ManagedRuntime {
		return
	}
	t.runtimeScope, t.runtimeSnapshot, t.runtimeTool = scope.name, scope.snapshot, tool
	t.runtimeProgress.Store(nil)
	t.runtimeKey++
	t.preparingRuntime, t.failed = true, nil
}

// take applies finished work on the window thread at the start of a paint. It reports a
// write that failed, so the footer's apply stops.
func (t *toolchainState) take() (saveFailed error) {
	if t.loader == nil {
		return nil
	}
	for _, scope := range t.scopes {
		if snapshot, err, ok := scope.loadEffect.Take(); ok {
			scope.loading = false
			if err != nil {
				scope.failed = err
			} else {
				scope.apply(snapshot, false)
			}
		}
	}
	if snapshot, err, ok := t.saveEffect.Take(); ok {
		t.saving = false
		scope := t.scopes[t.saveScope]
		switch {
		case err != nil && errors.Is(err, toolchain.ErrPinCommitted):
			// The pins were written but the re-read failed: the drafts are on disk, and the
			// page reads them back before it shows the scope again.
			t.failed, scope.loaded, scope.stale = err, false, true
			scope.draft = make(map[string]string)
			scope.revision++
			saveFailed = err
			if t.saveScope == scopeGlobal {
				t.locations.markStale()
			}
		case err != nil:
			t.failed, saveFailed = err, err
		default:
			scope.apply(snapshot, true)
			// A machine default is what the project scope inherits, and the machine catalog
			// also holds the trusted locations.
			if t.saveScope == scopeGlobal {
				if project := t.scopes[scopeProject]; project != nil && project.loaded {
					project.stale = true
				}
				t.locations.markStale()
			}
		}
	}
	if t.inspectEffect != nil {
		if selection, err, ok := t.inspectEffect.Take(); ok {
			t.inspecting, t.failed = false, err
			if err == nil && selection.Home != nil {
				t.acceptInspection(t.inspectScope, t.inspectTool, selection)
			}
		}
	}
	if t.trustEffect != nil {
		if snapshot, err, ok := t.trustEffect.Take(); ok {
			t.trusting = false
			scope := t.scopes[scopeProject]
			if err != nil {
				t.failed = err
				if errors.Is(err, toolchain.ErrPinCommitted) {
					scope.loaded, scope.stale = false, true
					t.trustWritten()
				}
			} else {
				// The grant changes what the project probes; the user's choices stay.
				scope.apply(snapshot, false)
				t.trustWritten()
			}
		}
	}
	if t.runtimeEffect != nil {
		if snapshot, err, ok := t.runtimeEffect.Take(); ok {
			t.preparingRuntime = false
			t.runtimeProgress.Store(nil)
			if err != nil {
				t.failed = err
			} else {
				if scope := t.scopes[t.runtimeScope]; scope != nil {
					scope.apply(snapshot, false)
				}
				other := scopeProject
				if t.runtimeScope == scopeProject {
					other = scopeGlobal
				}
				if sibling := t.scopes[other]; sibling != nil && sibling.loaded {
					sibling.stale = true
				}
			}
		}
	}
	if err := t.locations.take(); err != nil && saveFailed == nil {
		saveFailed = err
	}
	if err := t.remote.take(); err != nil && saveFailed == nil {
		saveFailed = err
	}
	if err := t.prefs.take(); err != nil && saveFailed == nil {
		saveFailed = err
	}
	t.view.take()
	t.search.take()
	return saveFailed
}

// trustWritten marks what was read from the machine catalog before a trust decision wrote it.
func (t *toolchainState) trustWritten() {
	if global := t.scopes[scopeGlobal]; global != nil && global.loaded {
		global.stale = true
	}
	t.locations.markStale()
}

// catalogWritten marks both scopes stale after the Trusted Locations page wrote the machine
// catalog: it changes which projects are trusted and the bytes the machine defaults are
// written against.
func (t *toolchainState) catalogWritten() {
	for _, scope := range t.scopes {
		if scope.loaded {
			scope.stale = true
		}
	}
}

// acceptInspection lists a checked directory as the tool's candidate and chooses it.
func (t *toolchainState) acceptInspection(name, id string, selection core.ToolchainSelection) {
	scope := t.scopes[name]
	if scope == nil || selection.Home == nil {
		return
	}
	pin := core.ToolchainPin{Home: *selection.Home, Version: selection.Version, Provider: "host:manual"}
	scope.custom[id] = append(slices.DeleteFunc(scope.custom[id], func(known core.ToolchainPin) bool { return known.Home == pin.Home }), pin)
	if t.adding == id {
		t.adding = ""
	}
	delete(scope.inputs, id)
	scope.choose(id, pin.Home)
}

// declare keeps the requests that are out alive. The window declares it in every paint, so
// leaving the page does not cancel a write.
func (t *toolchainState) declare(c ui.C) {
	if t.loader == nil {
		return
	}
	for _, name := range t.order {
		if scope := t.scopes[name]; scope.loadKey != 0 {
			ui.Effect(c, scope.loadEffect, scope.loadKey)
		}
	}
	if t.saveKey != 0 {
		ui.Effect(c, t.saveEffect, t.saveKey)
	}
	if t.inspectKey != 0 && t.inspectEffect != nil {
		ui.Effect(c, t.inspectEffect, t.inspectKey)
	}
	if t.trustKey != 0 && t.trustEffect != nil {
		ui.Effect(c, t.trustEffect, t.trustKey)
	}
	if t.runtimeKey != 0 && t.runtimeEffect != nil {
		ui.Effect(c, t.runtimeEffect, t.runtimeKey)
	}
	t.locations.declare(c)
	t.remote.declare(c)
	t.prefs.declare(c)
	t.view.declare(c)
	t.search.declare(c)
}

// foldKey is the comparable form of the user's folds.
func (t *toolchainState) foldKey() string {
	keys := make([]string, 0, len(t.folds))
	for key, collapsed := range t.folds {
		if collapsed {
			keys = append(keys, "-"+key)
		} else {
			keys = append(keys, "+"+key)
		}
	}
	slices.Sort(keys)
	return strings.Join(keys, "\x00")
}

// toggleGroup folds or opens a group against what the list shows now.
func (t *toolchainState) toggleGroup(row core.ToolchainSettingsRow) {
	t.folds[row.Key] = !row.Collapsed
}

// requestView asks for the list's projection under the page's query.
func (t *toolchainState) requestView() {
	scope := t.current()
	if scope == nil || !scope.loaded {
		return
	}
	want := toolchainWant{scope: scope.name, revision: scope.revision, text: strings.TrimSpace(t.query), filter: t.filter, groupBy: t.groupBy, folds: t.foldKey(), issues: toolchainIssueLimit}
	t.view.request(want, func() (core.ToolchainSettingsViewRequest, []toolchainEntry) {
		request, entries := t.projectionRequest(scope)
		request.Query = core.ToolchainSettingsQuery{Text: want.text, Filter: want.filter, GroupBy: want.groupBy}
		for key, collapsed := range t.folds {
			if collapsed {
				request.Query.Collapsed = append(request.Query.Collapsed, key)
			} else {
				request.Query.Expanded = append(request.Query.Expanded, key)
			}
		}
		slices.Sort(request.Query.Collapsed)
		slices.Sort(request.Query.Expanded)
		request.IssueLimit = toolchainIssueLimit
		return request, entries
	})
}

// requestSearch asks which tools match the sidebar's search, grouped as the page groups them,
// so a match the user chooses can open its group. A search folds no group.
func (t *toolchainState) requestSearch(text string) {
	scope := t.current()
	if scope == nil || !scope.loaded || text == "" {
		return
	}
	want := toolchainWant{scope: scope.name, revision: scope.revision, text: text, filter: "all", groupBy: t.groupBy, issues: 1}
	t.search.request(want, func() (core.ToolchainSettingsViewRequest, []toolchainEntry) {
		request, entries := t.projectionRequest(scope)
		request.Query = core.ToolchainSettingsQuery{Text: text, Filter: "all", GroupBy: want.groupBy}
		request.IssueLimit = 1
		return request, entries
	})
}

// searchReady reports that the sidebar's tool matches it holds are for text.
func (t *toolchainState) searchReady(text string) bool {
	return t.search.ready && t.search.got.text == text && t.search.failed == nil
}

// searchGroup is the key of the group the sidebar's search lists the tool under, empty when
// the page does not group.
func (t *toolchainState) searchGroup(id string) string {
	return t.search.group(id)
}

// group is the key of the group the projection lists the tool under, empty when it does not
// group or does not list the tool.
func (p *toolchainProjection) group(id string) string {
	group := ""
	for _, row := range p.view.Rows {
		if row.Kind != "tool" {
			group = row.Key
			continue
		}
		if entry := p.entry(row); entry != nil && entry.tool.ID == id {
			return group
		}
	}
	return ""
}

// reveal shows the tool on the page: its group opened, no query or filter that hides it, and
// the tool chosen.
func (t *toolchainState) reveal(id, group string) {
	t.query, t.filter, t.selected, t.adding, t.whyOpen = "", "all", id, "", false
	if group != "" {
		t.folds[group] = false
	}
}

// showMatches opens the page on every tool the sidebar's search matched.
func (t *toolchainState) showMatches(text string) {
	t.query, t.filter = text, "all"
}

// projectionRequest lists the scope's tools as Core's projection takes them: identity, the
// resolver's reason, whether the scope pins or the draft changes it, and the versions and
// paths a search can find.
func (t *toolchainState) projectionRequest(scope *toolchainScope) (core.ToolchainSettingsViewRequest, []toolchainEntry) {
	entries := make([]toolchainEntry, 0, len(scope.snapshot.Tools)+len(scope.snapshot.Conflicts))
	ids := make(map[string]bool, len(scope.snapshot.Tools))
	for _, tool := range scope.snapshot.Tools {
		if tool.ID == "" || tool.PluginID == "" || ids[tool.ID] {
			continue
		}
		ids[tool.ID] = true
		entries = append(entries, toolchainEntry{tool: tool})
	}
	for _, conflict := range scope.snapshot.Conflicts {
		if conflict.Tool == "" || len(conflict.PluginIDs) == 0 || ids[conflict.Tool] {
			continue
		}
		ids[conflict.Tool] = true
		entries = append(entries, toolchainEntry{
			tool:     toolchain.Tool{ID: conflict.Tool, DisplayName: conflict.Tool, PluginID: conflict.PluginIDs[0], Reason: "conflict"},
			conflict: conflict.PluginIDs,
		})
	}
	request := core.ToolchainSettingsViewRequest{Tools: make([]core.ToolchainSettingsTool, len(entries))}
	for index, entry := range entries {
		tool := entry.tool
		name := tool.DisplayName
		if name == "" {
			name = tool.ID
		}
		request.Tools[index] = core.ToolchainSettingsTool{
			ID: tool.ID, DisplayName: name, PluginID: tool.PluginID, PluginName: tool.PluginName,
			Category: tool.Category, Audience: tool.Audience, Reason: tool.Reason,
			Pinned: tool.Pin != nil, Changed: scope.changed(tool.ID), Terms: toolchainTerms(scope, tool),
		}
	}
	return request, entries
}

// toolchainMaxTerms is Core's limit on a tool's search terms.
const toolchainMaxTerms = 16

// toolchainTerms are a tool's versions and paths, the text a search finds it by besides its
// names.
func toolchainTerms(scope *toolchainScope, tool toolchain.Tool) []string {
	var terms []string
	add := func(text string) {
		if text == "" || len(terms) >= toolchainMaxTerms || len(text) > 1024 || strings.ContainsFunc(text, isControl) || slices.Contains(terms, text) {
			return
		}
		terms = append(terms, text)
	}
	if tool.Effective != nil {
		add(tool.Effective.Version)
		if tool.Effective.Home != nil {
			add(*tool.Effective.Home)
		}
		add(tool.Effective.Executable)
	}
	for _, pin := range scope.custom[tool.ID] {
		add(pin.Version)
		add(pin.Home)
	}
	for _, installation := range tool.Installations {
		add(installation.Version)
		add(installation.Home)
	}
	for _, shell := range tool.Shell {
		if shell.Version != nil {
			add(*shell.Version)
		}
		add(shell.Home)
	}
	for _, project := range tool.Project {
		if project.Version != nil {
			add(*project.Version)
		}
		add(project.Home)
	}
	return terms
}

func isControl(r rune) bool {
	return r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0)
}

// rowKey is a list row's stable identity across projections: a tool's by its index in the
// entries, a group's by its key. Both fit the list's non-negative 31-bit keys.
func toolchainRowKey(row core.ToolchainSettingsRow) int {
	if row.Kind != "group" {
		return (row.Index & 0x3fffffff) * 2
	}
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(row.Key))
	return int(hash.Sum32()&0x3fffffff)*2 + 1
}

// toolchainOption is one choice of a tool's home in the detail pane.
type toolchainOption struct {
	home    string
	version string
	sources []string
	// why is what keeps the option from being chosen; empty when it can be.
	why  string
	auto bool
}

// options are a tool's choices in the scope: the inherited or automatic layers, then each home
// the scope knows once, with the sources that found it.
func (t *toolchainState) options(language i18n.Language, scope *toolchainScope, tool *toolchain.Tool) []toolchainOption {
	options := []toolchainOption{{auto: true}}
	index := make(map[string]int)
	add := func(home, version, source, why string) {
		if home == "" {
			return
		}
		if at, ok := index[home]; ok {
			option := &options[at]
			if source != "" && !slices.Contains(option.sources, source) {
				option.sources = append(option.sources, source)
			}
			if option.version == "" {
				option.version = version
			}
			if why == "" && option.why != "" {
				option.why = ""
			}
			return
		}
		option := toolchainOption{home: home, version: version, why: why}
		if source != "" {
			option.sources = []string{source}
		}
		index[home] = len(options)
		options = append(options, option)
	}
	for _, installation := range tool.Installations {
		why := ""
		if installation.Version == "" {
			why = i18n.Shared(language, "desktop.toolchains.reasonProbeFailed")
		}
		add(installation.Home, installation.Version, toolchainInstallationSource(language, tool, installation.Home, installation.Provider), why)
	}
	for _, shell := range tool.Shell {
		version, why := "", ""
		if shell.Version != nil {
			version = *shell.Version
		}
		if shell.Reason != "" {
			why = toolchainReasonLabel(language, shell.Reason)
		} else if version == "" {
			why = i18n.Shared(language, "desktop.toolchains.reasonProbeFailed")
		}
		source := shell.Variable
		if source == "" {
			// A command found on the search path; PATH is the variable's own name.
			source = "PATH"
		}
		add(shell.Home, version, source, why)
	}
	if scope.name == scopeProject {
		for _, project := range tool.Project {
			version, why := "", ""
			if project.Version != nil {
				version = *project.Version
			}
			switch {
			case project.Reason == "projectCodeRequiresAction":
				why = i18n.Shared(language, "desktop.toolchains.reasonProjectTrustRequired")
			case project.Reason != "":
				why = toolchainReasonLabel(language, project.Reason)
			case version == "":
				why = i18n.Shared(language, "desktop.toolchains.reasonProbeFailed")
			}
			home := project.Home
			if home == "" {
				home = project.Path
			}
			add(home, version, project.Path, why)
		}
	}
	for _, skipped := range tool.Skipped {
		add(skipped.Home, "", toolchainSourceLabel(language, skipped.Provider), toolchainReasonLabel(language, skipped.Reason))
	}
	for _, pin := range scope.custom[tool.ID] {
		add(pin.Home, pin.Version, toolchainSourceLabel(language, "host:manual"), "")
	}
	if pin := tool.Pin; pin != nil {
		// The pin is the checked choice, not a source, as in the prototype's srcTags: it names
		// who found its home only when nothing above did.
		source := ""
		if _, known := index[pin.Home]; !known {
			source = toolchainSourceLabel(language, pin.Provider)
		}
		add(pin.Home, pin.Version, source, "")
	}
	// An option that cannot be pinned is not a choice whatever found it.
	for at := range options {
		option := &options[at]
		if option.auto || option.why != "" {
			continue
		}
		if _, ok := scope.pinFor(tool, option.home); !ok {
			option.why = i18n.Shared(language, "desktop.toolchains.reasonProbeFailed")
		}
	}
	return options
}

func toolchainInstallationSource(language i18n.Language, tool *toolchain.Tool, home, provider string) string {
	if provider == "host:managed" || slices.Contains(tool.ManagedRuntimeHomes, home) {
		return toolchainSourceLabel(language, "host:managed")
	}
	return toolchainSourceLabel(language, provider)
}

// toolchainSourceLabel names who found a home: the host's own sources in the user's language,
// a plugin's provider by its ID.
func toolchainSourceLabel(language i18n.Language, provider string) string {
	switch provider {
	case "host:managed":
		return i18n.Shared(language, "desktop.buildSettings.sourceManaged")
	case "host:manual":
		return i18n.Shared(language, "desktop.buildSettings.sourceManual")
	case "host:system":
		return i18n.Shared(language, "desktop.buildSettings.sourceSystem")
	case "host:project":
		return i18n.Shared(language, "desktop.toolchains.layerProject")
	case "host:default":
		return i18n.Shared(language, "desktop.toolchains.layerGlobal")
	case "host:shell":
		return "PATH"
	default:
		return provider
	}
}

func toolchainFailureMessage(language i18n.Language, err error) string {
	var unavailable *toolchain.UnavailableError
	if errors.As(err, &unavailable) {
		return i18n.Shared(language, "desktop.toolchains.invalidDirectory")
	}
	if errors.Is(err, toolchain.ErrPinCommitted) {
		return i18n.Shared(language, "desktop.toolchains.reloadAfterSave")
	}
	if errors.Is(err, toolchain.ErrPinConflict) {
		return i18n.Shared(language, "desktop.toolchains.sourceChanged")
	}
	var rejection *core.MarketplaceRejection
	if errors.As(err, &rejection) && rejection.Code == "plugin.toolchain.rootLocation" {
		return i18n.Shared(language, "desktop.trustedLocations.rootLocation")
	}
	if errors.As(err, &rejection) && rejection.Code == "plugin.toolchain.trustListFull" {
		return i18n.Shared(language, "desktop.trustedLocations.listFull")
	}
	if errors.Is(err, configfile.ErrTarget) || errors.Is(err, configfile.ErrEncoding) || errors.Is(err, configfile.ErrTooLarge) ||
		(errors.As(err, &rejection) && (rejection.Code == "plugin.toolchain.invalidDocument" || rejection.Code == "plugin.toolchain.invalidIgnore")) {
		return i18n.Shared(language, "desktop.toolchains.sourceInvalid")
	}
	return i18n.SharedFormat(language, "desktop.toolchains.loadFailed", map[string]string{"reason": err.Error()})
}

func (w *window) pickToolchainDirectory(tool string, input *string, title string) {
	defer w.inv.Invalidate()
	path, err := app.OpenDirectory(app.OpenDirectoryOptions{Title: title})
	// log-exempt: 用户取消：关闭目录选择器不修改工具链草稿。
	if errors.Is(err, app.ErrCanceled) {
		return
	}
	if err != nil {
		w.toolchains.failed = err
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	if scope := w.toolchains.current(); path != "" && scope != nil && scope.inputs[tool] == input {
		*input = path
		w.toolchains.beginInspect(tool, path)
	}
}

func toolchainReason(tool toolchain.Tool) string {
	if tool.Reason != "" {
		return tool.Reason
	}
	for _, trace := range tool.Trace {
		if trace.Reason != nil && trace.Reason.Code != "" {
			return trace.Reason.Code
		}
	}
	for _, project := range tool.Project {
		if project.Reason != "" {
			return project.Reason
		}
	}
	return "notFound"
}

func toolRequiresProjectTrust(tool toolchain.Tool) bool {
	for _, project := range tool.Project {
		if project.Reason == "projectCodeRequiresAction" {
			return true
		}
	}
	for _, trace := range tool.Trace {
		if trace.Reason != nil && trace.Reason.Code == "projectCodeRequiresAction" {
			return true
		}
	}
	return false
}

// projectSources are the project files the tools that wait for trust come from.
func projectSources(snapshot toolchain.Snapshot) (tools int, sources []string) {
	for _, tool := range snapshot.Tools {
		if !toolRequiresProjectTrust(tool) {
			continue
		}
		tools++
		for _, project := range tool.Project {
			if project.Reason == "projectCodeRequiresAction" && project.Path != "" && !slices.Contains(sources, project.Path) {
				sources = append(sources, project.Path)
			}
		}
	}
	return tools, sources
}

func toolchainReasonLabel(language i18n.Language, code string) string {
	switch code {
	case "projectCodeRequiresAction":
		return i18n.Shared(language, "desktop.toolchains.reasonProjectTrustRequired")
	case "notFound":
		return i18n.Shared(language, "desktop.buildSettings.reasonNotFound")
	case "probeFailed":
		return i18n.Shared(language, "desktop.toolchains.reasonProbeFailed")
	case "versionUnsatisfied":
		return i18n.Shared(language, "desktop.toolchains.reasonVersionUnsatisfied")
	case "notExecutable":
		return i18n.Shared(language, "desktop.toolchains.reasonNotExecutable")
	case "unsafePath":
		return i18n.Shared(language, "desktop.toolchains.reasonUnsafePath")
	case "conflict":
		return i18n.Shared(language, "desktop.buildSettings.reasonConflict")
	default:
		return code
	}
}

// ToolchainLayerLabel names the layer the shared resolver selected an installation from: pinned,
// project, global or automatic. The workbench shows it beside a build's runtime as well.
func ToolchainLayerLabel(language i18n.Language, layer string) string {
	switch layer {
	case "pinned":
		return i18n.Shared(language, "desktop.toolchains.layerPinned")
	case "project":
		return i18n.Shared(language, "desktop.toolchains.layerProject")
	case "global":
		return i18n.Shared(language, "desktop.toolchains.layerGlobal")
	case "automatic":
		return i18n.Shared(language, "desktop.toolchains.layerAutomatic")
	default:
		return layer
	}
}
