package workbench

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// This file runs the tool windows of the plugin version control providers
// (rust/contracts/vcs-provider-v1.md). Each provider an enabled plugin declares has a window.
// Core finds the project's working copies from the providers' static markers, without starting
// any process; a window starts its provider's session the first time it runs an operation, and
// Core checks every operation before the provider sees it and every reply before the window
// shows it. Drawing is in vcs_view.go.
//
// Each provider session is a process of its plugin. Its state, log and temporary directories
// are under the plugin root's .state/<plugin>/<version>/vcs/<workspace digest>, the same
// writable tree build providers use; nothing is written into the installed package or the
// application bundle. The sessions belong to the project and stop with it, or when the
// version control plugins change.

// vcsItemPrefix starts the chrome identifier of a provider's window. The window is a plugin item,
// so the layout keeps its place while its plugin is away; a tool window ID never holds a colon,
// so it never meets a declared window.
const vcsItemPrefix = pluginItemPrefix + "vcs:"

const (
	// vcsReadTimeout bounds an operation that only reads the working copy, the start of the
	// provider's session included, and vcsWriteTimeout one that changes it or the repository,
	// which may wait on the network.
	vcsReadTimeout  = 2 * time.Minute
	vcsWriteTimeout = 30 * time.Minute
	// vcsStopTimeout bounds how long closing the sessions waits for them.
	vcsStopTimeout = 15 * time.Second
	// vcsHistoryLimit is how many revisions one page of the History tab asks for.
	vcsHistoryLimit = 100
	// vcsRootMappingsFile is the data-store file of the VCS the user chose for each directory
	// holding the metadata of several, by project root. It is the client's own state, never
	// written into the project.
	vcsRootMappingsFile = "vcs-root-mappings.json"
)

// vcsWindow is one plugin VCS provider as its window knows it.
type vcsWindow struct {
	PluginID, Version, Directory string
	Manifest                     json.RawMessage
	// Vcs is the provider's ID, the VCS it serves, and DisplayName the window's title.
	Vcs, DisplayName string
}

// vcsWindows is a window for each provider the plugins declare, in their order.
func vcsWindows(plugins []pluginservice.VcsPlugin) []vcsWindow {
	var windows []vcsWindow
	for _, plugin := range plugins {
		for _, provider := range plugin.Providers {
			title := provider.DisplayName
			if title == "" {
				title = provider.ID
			}
			windows = append(windows, vcsWindow{
				PluginID: plugin.PluginID, Version: plugin.Version, Directory: plugin.Directory, Manifest: plugin.Manifest,
				Vcs: provider.ID, DisplayName: title,
			})
		}
	}
	return windows
}

// vcsItemID is the chrome identifier of a provider's window.
func vcsItemID(window *vcsWindow) string { return vcsItemPrefix + window.PluginID + "/" + window.Vcs }

// sameVcsWindow reports whether two windows show the same provider of the same package.
func sameVcsWindow(a, b *vcsWindow) bool {
	return a.PluginID == b.PluginID && a.Version == b.Version && a.Directory == b.Directory &&
		a.Vcs == b.Vcs && a.DisplayName == b.DisplayName && bytes.Equal(a.Manifest, b.Manifest)
}

// vcsKernel is the part of Core the version control windows use.
type vcsKernel interface {
	VcsDetectRoots(ctx context.Context, workspaceRoot string, manifests []json.RawMessage, mappings []core.VcsMapping) (core.VcsDetection, error)
	VcsDecodeReply(ctx context.Context, operation string, capabilities map[string]int, request, reply json.RawMessage) (json.RawMessage, error)
	CompareTexts(ctx context.Context, oldText, newText string) (core.GitDiffFile, error)
}

// vcsKernel is the window's kernel when it has the version control commands.
func (a *App) vcsKernel() (vcsKernel, bool) {
	k, ok := a.kernel.(vcsKernel)
	return k, ok
}

// vcsState is what the version control windows know of a project. Only the window thread
// reads or writes it; the sessions synchronize themselves.
type vcsState struct {
	// generation rejects a detection a newer one replaced.
	generation uint64
	detecting  bool
	detected   bool
	detection  core.VcsDetection
	// manifests are the plugins whose manifests the detection was asked about, in its order,
	// so a rejected index names its plugin.
	manifests []string
	failure   string
	// sessions are the provider sessions the project started, nil until the first starts.
	sessions *vcsRuntime
	// views are the view of each window, by its chrome identifier.
	views map[string]*vcsView
}

// vcsView is the state of one provider's window.
type vcsView struct {
	// root is the ID of the working copy the window shows.
	root string
	// history says the window shows the History tab rather than the changes.
	history bool
	roots   map[string]*vcsRootView
	message ui.Field
	// revisions is the list of the History tab, and split the line under the changes or the
	// revisions.
	revisions ui.ListState
	split     ui.SplitterState
	// commit is the splitter between the changes and the commit area, which keeps the height
	// the user gave it.
	commit commitView
	// capabilities are what the provider negotiated, known once its session started.
	capabilities map[string]int
	// busy is the operation that changes the working copy or the repository, "" when none runs.
	busy string
	// notice is the result of the last such operation, and failure why it failed.
	notice, failure string
	// rollback are the paths the rollback dialog asks about, nil while it is closed.
	rollback []string
}

// can reports whether the provider negotiated capability.
func (v *vcsView) can(capability string) bool {
	_, ok := v.capabilities[capability]
	return ok
}

// vcsRootView is what a window knows of one working copy.
type vcsRootView struct {
	status  *core.VcsStatusReply
	loading bool
	failure string
	// include are the changes the user put in or left out of the commit, by path, over the
	// default of each change.
	include map[string]bool
	// selected is the path of the selected change.
	selected string
	// rows are the list of changes as it shows, collected when the status arrives.
	rows []vcsRow
	// history is the loaded revisions, newest first, and cursor the next page's, nil at the end.
	history        []core.VcsHistoryEntry
	cursor         *string
	historyLoaded  bool
	historyLoading bool
	historyFailure string
	// revision is the index of the selected revision, -1 for none.
	revision int
}

// vcsRow is one row of the list of changes: a section's title, with change -1, or a change of
// the status at its index.
type vcsRow struct {
	section, change int
}

// Sections of the list of changes, in their order.
const (
	vcsSectionConflicts = iota
	vcsSectionChanges
	vcsSectionUnversioned
)

// vcsSection is the section a change shows in.
func vcsSection(change *core.VcsChange) int {
	switch {
	case change.Status == "conflicted" || change.HasFlag("treeConflict"):
		return vcsSectionConflicts
	case change.Status == "unversioned" || change.Status == "ignored":
		return vcsSectionUnversioned
	}
	return vcsSectionChanges
}

// vcsVersioned reports whether the VCS tracks the change, so it can be rolled back.
func vcsVersioned(change *core.VcsChange) bool {
	return change.Status != "unversioned" && change.Status != "ignored"
}

// vcsIncludedByDefault reports whether a change is in the commit until the user says otherwise:
// a versioned change that is not in conflict.
func vcsIncludedByDefault(change *core.VcsChange) bool {
	return vcsSection(change) == vcsSectionChanges
}

// included reports whether change is in the commit.
func (r *vcsRootView) included(change *core.VcsChange) bool {
	if include, ok := r.include[change.Path]; ok {
		return include
	}
	return vcsIncludedByDefault(change)
}

// collectRows lists the changes under their sections, each section that has any.
func (r *vcsRootView) collectRows() {
	r.rows = r.rows[:0]
	if r.status == nil {
		return
	}
	for _, section := range []int{vcsSectionConflicts, vcsSectionChanges, vcsSectionUnversioned} {
		header := false
		for index := range r.status.Changes {
			if vcsSection(&r.status.Changes[index]) != section {
				continue
			}
			if !header {
				r.rows = append(r.rows, vcsRow{section: section, change: -1})
				header = true
			}
			r.rows = append(r.rows, vcsRow{section: section, change: index})
		}
	}
}

// sectionCount is how many changes show in section.
func (r *vcsRootView) sectionCount(section int) int {
	count := 0
	for _, row := range r.rows {
		if row.section == section && row.change >= 0 {
			count++
		}
	}
	return count
}

// change is the change at path, nil when the status has none.
func (r *vcsRootView) change(path string) *core.VcsChange {
	if r.status == nil || path == "" {
		return nil
	}
	for index := range r.status.Changes {
		if r.status.Changes[index].Path == path {
			return &r.status.Changes[index]
		}
	}
	return nil
}

// commitPaths are the paths a commit of the included changes names: each change's path, and the
// old path of a move, which the commit also records.
func (r *vcsRootView) commitPaths() []string {
	var paths []string
	if r.status == nil {
		return nil
	}
	for index := range r.status.Changes {
		change := &r.status.Changes[index]
		if !r.included(change) {
			continue
		}
		paths = append(paths, change.Path)
		if change.OldPath != nil && *change.OldPath != change.Path {
			paths = append(paths, *change.OldPath)
		}
	}
	slices.Sort(paths)
	return slices.Compact(paths)
}

// view is the state of the window id, made on first use.
func (s *vcsState) view(id string) *vcsView {
	if s.views == nil {
		s.views = map[string]*vcsView{}
	}
	view := s.views[id]
	if view == nil {
		view = &vcsView{roots: map[string]*vcsRootView{}, commit: newCommitView()}
		s.views[id] = view
	}
	return view
}

// rootView is the state of the window's working copy id, made on first use.
func (v *vcsView) rootView(id string) *vcsRootView {
	root := v.roots[id]
	if root == nil {
		root = &vcsRootView{revision: -1}
		v.roots[id] = root
	}
	return root
}

// roots are the working copies the detection found for vcs, in Core's order.
func (s *vcsState) roots(vcs string) []core.VcsRoot {
	var roots []core.VcsRoot
	for _, root := range s.detection.Roots {
		if root.Vcs == vcs {
			roots = append(roots, root)
		}
	}
	return roots
}

// ambiguous are the directories holding the metadata of vcs among other VCSs, none of which
// was chosen yet.
func (s *vcsState) ambiguous(vcs string) []core.VcsAmbiguous {
	var directories []core.VcsAmbiguous
	for _, directory := range s.detection.Ambiguous {
		if slices.Contains(directory.Vcs, vcs) {
			directories = append(directories, directory)
		}
	}
	return directories
}

// rejection is Core's reason for refusing the manifest of plugin, "" when it accepted it.
func (s *vcsState) rejection(plugin string) string {
	for _, rejected := range s.detection.Rejected {
		if rejected.Index >= 0 && rejected.Index < len(s.manifests) && s.manifests[rejected.Index] == plugin && rejected.Error != nil {
			return rejected.Error.Message
		}
	}
	return ""
}

// vcsRuntime holds the provider sessions of one project, one per provider.
type vcsRuntime struct {
	mu      sync.Mutex
	clients map[string]*buildprovider.Client
	closed  bool
}

// errVcsNotNegotiated is a session that started without negotiating the provider it was started
// for; it is stopped and never asked anything.
var errVcsNotNegotiated = errors.New("the provider session did not negotiate its version control provider")

// errVcsToolMissing is a provider whose client none of its commands finds.
var errVcsToolMissing = errors.New("the version control client of the provider was not found")

// live is the running session of key, nil when there is none.
func (r *vcsRuntime) live(key string) *buildprovider.Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	if client := r.clients[key]; client != nil && !client.Closed() {
		return client
	}
	return nil
}

// session is the running session of window, started when there is none. A session that did not
// negotiate the window's provider is stopped and refused, as the contract asks. The process starts
// outside the lock, so detaching on the window thread never waits for a start; a start that lost
// to another one or to detaching is stopped again.
func (r *vcsRuntime) session(ctx context.Context, runner *pluginbackend.Runner, pluginRoot, root, rootURI string, window vcsWindow, settings core.PluginSettingsState) (*buildprovider.Client, error) {
	key := window.PluginID + "\x00" + window.Vcs
	r.mu.Lock()
	closed, client := r.closed, r.clients[key]
	r.mu.Unlock()
	if closed {
		return nil, buildprovider.ErrClosed
	}
	if client != nil && !client.Closed() {
		return client, nil
	}
	state := filepath.Join(pluginRoot, ".state", window.PluginID, window.Version, "vcs", workspaceDigest(root))
	workspaceState := filepath.Join(state, "workspace")
	logDirectory := filepath.Join(state, "log")
	temporaryDirectory := filepath.Join(state, "tmp")
	for _, directory := range []string{state, workspaceState, logDirectory, temporaryDirectory} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, err
		}
	}
	started, err := buildprovider.Start(ctx, runner, pluginbackend.StartRequest{
		Manifest:                window.Manifest,
		PackageDirectory:        window.Directory,
		PluginID:                window.PluginID,
		ProviderID:              window.PluginID + "/" + window.Vcs,
		VcsProviderID:           window.Vcs,
		Role:                    "vcs",
		StateDirectory:          state,
		WorkspaceStateDirectory: workspaceState,
		LogDirectory:            logDirectory,
		TemporaryDirectory:      temporaryDirectory,
		Architecture:            core.PluginArchitecture(),
		Settings:                settings.Settings,
		ProjectSettings:         settings.ProjectSettings,
		RootURI:                 rootURI,
		WorkingDirectory:        root,
	})
	if err != nil {
		return nil, err
	}
	if vcs, _, ok := started.VcsProvider(); !ok || vcs != window.Vcs {
		_ = started.Close(ctx)
		return nil, errVcsNotNegotiated
	}
	r.mu.Lock()
	closed, client = r.closed, r.clients[key]
	if !closed && (client == nil || client.Closed()) {
		if r.clients == nil {
			r.clients = map[string]*buildprovider.Client{}
		}
		r.clients[key] = started
		r.mu.Unlock()
		return started, nil
	}
	r.mu.Unlock()
	_ = started.Close(ctx)
	if closed {
		return nil, buildprovider.ErrClosed
	}
	return client, nil
}

// detach takes every session and, with closing set, refuses new ones.
func (r *vcsRuntime) detach(closing bool) []*buildprovider.Client {
	r.mu.Lock()
	defer r.mu.Unlock()
	clients := make([]*buildprovider.Client, 0, len(r.clients))
	for _, client := range r.clients {
		clients = append(clients, client)
	}
	r.clients = nil
	if closing {
		r.closed = true
	}
	return clients
}

// runtime is the project's sessions, made on first use.
func (s *vcsState) runtime() *vcsRuntime {
	if s.sessions == nil {
		s.sessions = &vcsRuntime{}
	}
	return s.sessions
}

// stopVcs stops every provider session of a project that closes, on a background task with a
// bounded wait.
func (a *App) stopVcs(p *project) {
	if p == nil || p.vcs.sessions == nil {
		return
	}
	a.closeVcsSessions(p.vcs.sessions.detach(true))
}

// invalidateVcs forgets what the version control windows of the project found and stops their
// sessions, after the version control plugins changed: the next window to show detects again.
func (a *App) invalidateVcs(p *project) {
	if p == nil {
		return
	}
	if p.vcs.sessions != nil {
		a.closeVcsSessions(p.vcs.sessions.detach(true))
	}
	p.vcs = vcsState{generation: p.vcs.generation + 1}
}

// closeVcsSessions closes clients on a background task with a bounded wait.
func (a *App) closeVcsSessions(clients []*buildprovider.Client) {
	if len(clients) == 0 {
		return
	}
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		ctx, cancel := context.WithTimeout(context.Background(), vcsStopTimeout)
		defer cancel()
		for _, client := range clients {
			_ = client.Close(ctx)
		}
	}()
}

// vcsWindowsShown are the windows of the catalog, in its order.
func (a *App) vcsWindowsShown() []*vcsWindow { return vcsItems(a.chrome.catalog) }

// detectVcsRoots has Core find the project's working copies for every provider of the catalog,
// with the VCS the user chose for each ambiguous directory.
func (a *App) detectVcsRoots(p *project) {
	kernel, ok := a.vcsKernel()
	if !ok || p == nil {
		return
	}
	s := &p.vcs
	var manifests []json.RawMessage
	var plugins []string
	for _, window := range a.vcsWindowsShown() {
		if !slices.Contains(plugins, window.PluginID) {
			plugins = append(plugins, window.PluginID)
			manifests = append(manifests, window.Manifest)
		}
	}
	mappings, err := a.loadVcsMappings(p.root)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_root_mappings_load", documentLogError(err)))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.project.readFailed", map[string]string{"reason": err.Error()}))
	}
	s.generation++
	generation, root := s.generation, p.root
	s.detecting, s.failure = true, ""
	a.background(p, vcsReadTimeout, func(ctx context.Context) func(*App) {
		detection, err := kernel.VcsDetectRoots(ctx, root, manifests, mappings)
		return func(a *App) {
			if s.generation != generation {
				return
			}
			s.detecting, s.detected = false, true
			if err != nil {
				s.failure = a.vcsFailureText(err)
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_detect_roots", documentLogError(err)))
				return
			}
			s.detection, s.manifests = detection, plugins
			for _, conflict := range detection.Conflicts {
				a.emit(core.LevelWarn, "app.vcs.provider_conflict", map[string]any{"plugin": conflict.PluginID, "vcs": conflict.Vcs, "by": conflict.By})
			}
			if len(detection.UnusedMappings) > 0 {
				a.dropVcsMappings(root, detection.UnusedMappings)
			}
		}
	})
}

// loadVcsMappings reads the VCS the user chose for each ambiguous directory of the project.
func (a *App) loadVcsMappings(root string) ([]core.VcsMapping, error) {
	if a.store == nil {
		return nil, nil
	}
	all := map[string][]core.VcsMapping{}
	if _, err := a.store.Load(vcsRootMappingsFile, &all); err != nil {
		return nil, err
	}
	return all[filepath.Clean(root)], nil
}

// storeVcsMappings writes the mappings of the project at root, dropping the project from the
// file when it has none.
func (a *App) storeVcsMappings(root string, mappings []core.VcsMapping) error {
	if a.store == nil {
		return nil
	}
	all := map[string][]core.VcsMapping{}
	if _, err := a.store.Load(vcsRootMappingsFile, &all); err != nil {
		return err
	}
	key := filepath.Clean(root)
	if len(mappings) == 0 {
		delete(all, key)
	} else {
		slices.SortFunc(mappings, func(x, y core.VcsMapping) int { return strings.Compare(x.ID, y.ID) })
		all[key] = mappings
	}
	return a.store.Save(vcsRootMappingsFile, all)
}

// mapVcsRoot records that vcs manages the ambiguous directory id and detects again.
func (a *App) mapVcsRoot(p *project, id, vcs string) {
	mappings, err := a.loadVcsMappings(p.root)
	if err == nil {
		mappings = slices.DeleteFunc(mappings, func(m core.VcsMapping) bool { return m.ID == id })
		err = a.storeVcsMappings(p.root, append(mappings, core.VcsMapping{ID: id, Vcs: vcs}))
	}
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_root_mappings_save", documentLogError(err)))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.runConfig.saveFailed", map[string]string{"reason": err.Error()}))
		return
	}
	a.detectVcsRoots(p)
}

// dropVcsMappings forgets mappings whose directory is no longer ambiguous.
func (a *App) dropVcsMappings(root string, unused []core.VcsMapping) {
	mappings, err := a.loadVcsMappings(root)
	if err == nil {
		mappings = slices.DeleteFunc(mappings, func(m core.VcsMapping) bool { return slices.Contains(unused, m) })
		err = a.storeVcsMappings(root, mappings)
	}
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_root_mappings_save", documentLogError(err)))
	}
}

// vcsCall is one operation a window asks its provider for.
type vcsCall struct {
	window    vcsWindow
	operation string
	// root is the native path of the working copy, and tool the commands of the provider's
	// client, nil when it declares none.
	root      string
	tool      []string
	arguments any
	timeout   time.Duration
}

// call is an operation of window on the working copy root of the detection.
func (s *vcsState) call(window *vcsWindow, root core.VcsRoot, operation string, arguments any, timeout time.Duration) vcsCall {
	call := vcsCall{window: *window, operation: operation, root: root.Path, arguments: arguments, timeout: timeout}
	if descriptor := s.detection.Provider(window.Vcs); descriptor != nil && descriptor.Tool != nil {
		call.tool = slices.Clone(descriptor.Tool.Commands)
	}
	return call
}

// runVcs runs call away from the window thread: it starts the provider's session when none
// runs, resolves the provider's client, has Core send the operation, waits for its reply and has
// Core check it. It returns the checked reply and what the provider negotiated.
func (a *App) runVcs(ctx context.Context, p *project, sessions *vcsRuntime, call vcsCall) (json.RawMessage, map[string]int, error) {
	kernel, ok := a.vcsKernel()
	if !ok || a.plugins == nil || a.plugins.Backend == nil {
		return nil, nil, errVcsNotNegotiated
	}
	client := sessions.live(call.window.PluginID + "\x00" + call.window.Vcs)
	if client == nil {
		settings, err := a.loadPluginPreferenceSources(ctx, call.window.Manifest, p.root)
		if err != nil {
			return nil, nil, err
		}
		rootURI, err := a.kernel.PluginDocumentURI(ctx, p.root, "auto")
		if err != nil {
			return nil, nil, err
		}
		if client, err = sessions.session(ctx, a.plugins.Backend, a.plugins.Root, p.root, rootURI, call.window, settings.State); err != nil {
			return nil, nil, err
		}
	}
	_, capabilities, _ := client.VcsProvider()
	var tool *string
	if len(call.tool) > 0 {
		executable, err := a.plugins.Backend.ResolveCommand(call.tool)
		if err != nil {
			return nil, capabilities, errors.Join(errVcsToolMissing, err)
		}
		tool = &executable
	}
	arguments, err := json.Marshal(call.arguments)
	if err != nil {
		return nil, capabilities, err
	}
	operation, err := client.ExecuteVcs(ctx, core.PluginVcsRequest{
		Vcs: call.window.Vcs, Operation: call.operation, Root: call.root, Tool: tool, Arguments: arguments,
		TimeoutMilliseconds: int(call.timeout / time.Millisecond),
	})
	if err != nil {
		return nil, capabilities, err
	}
	value, err := operation.Wait(ctx)
	if err != nil {
		if ctx.Err() != nil {
			cancelCtx, cancel := context.WithTimeout(context.Background(), vcsStopTimeout)
			_ = client.Cancel(cancelCtx, operation)
			cancel()
		}
		return nil, capabilities, err
	}
	decoded, err := kernel.VcsDecodeReply(ctx, call.operation, capabilities, arguments, value)
	return decoded, capabilities, err
}

// vcsFailureText is what the window says of a failed operation: the meaning of each stable code
// the contract defines, else the provider's or Core's own message, which is a diagnostic.
func (a *App) vcsFailureText(err error) string {
	language := a.language()
	var provider *buildprovider.ProviderError
	if errors.As(err, &provider) {
		switch provider.Code {
		case "vcs.tool.unavailable":
			return i18n.Shared(language, "native.theVersionControlClientCouldNotBeRunCheckThatItIsInstalled")
		case "vcs.workingCopy.locked":
			return i18n.Shared(language, "native.theWorkingCopyIsLockedByAnInterruptedActionRunCleanupThenTryAgain")
		case "vcs.outOfDate":
			return i18n.Shared(language, "native.theWorkingCopyIsOutOfDateUpdateItThenCommitAgain")
		case "vcs.workingCopy.unsupported":
			return i18n.Shared(language, "native.thisWorkingCopyFormatIsNotSupportedUpgradeItWithTheCommandLineClient")
		case "vcs.conflict":
			return i18n.Shared(language, "native.theActionStoppedOnConflictedFilesResolveThemThenTryAgain")
		case "vcs.authentication.failed":
			return i18n.Shared(language, "native.authenticationFailedLitheCannotAskForCredentialsYetSignInOnceWithTheCommandLineClientSoItStoresThemThenTryAgain")
		}
		return provider.Message
	}
	var refused *core.Error
	if errors.As(err, &refused) && (strings.Contains(refused.Details, "vcs.capability.unsupported") || strings.Contains(refused.Details, "vcs.provider.unavailable")) {
		return i18n.Shared(language, "native.thisVersionControlProviderDoesNotSupportThisAction")
	}
	var rejection *core.MarketplaceRejection
	if errors.As(err, &rejection) && rejection.Code == "plugin.vcs.invalidOutput" {
		return i18n.SharedFormat(language, "native.litheCouldNotEvaluateTheVersionControlDataArg1", map[string]string{"arg1": rejection.Message})
	}
	switch {
	case errors.Is(err, errVcsToolMissing):
		return i18n.Shared(language, "native.theVersionControlClientCouldNotBeRunCheckThatItIsInstalled")
	case errors.Is(err, errVcsNotNegotiated):
		return i18n.Shared(language, "native.theVersionControlProviderFailedToStart")
	case errors.Is(err, buildprovider.ErrClosed):
		return i18n.Shared(language, "native.theVersionControlProviderStoppedBeforeItWasReady")
	}
	return err.Error()
}

// vcsTarget is the window, its view and the working copy it shows, the root's view included.
type vcsTarget struct {
	id     string
	window *vcsWindow
	view   *vcsView
	root   core.VcsRoot
	state  *vcsRootView
}

// vcsTarget is the target of the window id in project p, false while it shows no working copy.
func (p *project) vcsTarget(id string, window *vcsWindow) (vcsTarget, bool) {
	view := p.vcs.view(id)
	roots := p.vcs.roots(window.Vcs)
	index := slices.IndexFunc(roots, func(root core.VcsRoot) bool { return root.ID == view.root })
	if index < 0 {
		if len(roots) == 0 {
			return vcsTarget{}, false
		}
		index, view.root = 0, roots[0].ID
	}
	return vcsTarget{id: id, window: window, view: view, root: roots[index], state: view.rootView(roots[index].ID)}, true
}

// stillShows reports whether the target is still what the window shows, so a result of an
// operation that started before the project changed its working copies is dropped.
func (p *project) stillShows(t vcsTarget) bool {
	view := p.vcs.views[t.id]
	return view == t.view && view.roots[t.root.ID] == t.state
}

// refreshVcsStatus reads the status of the target's working copy again.
func (a *App) refreshVcsStatus(p *project, t vcsTarget) {
	if t.state.loading {
		return
	}
	t.state.loading, t.state.failure = true, ""
	call := p.vcs.call(t.window, t.root, core.VcsStatus, struct{}{}, vcsReadTimeout)
	sessions := p.vcs.runtime()
	a.background(p, vcsReadTimeout, func(ctx context.Context) func(*App) {
		decoded, capabilities, err := a.runVcs(ctx, p, sessions, call)
		var status core.VcsStatusReply
		if err == nil {
			err = json.Unmarshal(decoded, &status)
		}
		return func(a *App) {
			if !p.stillShows(t) {
				return
			}
			t.state.loading = false
			if capabilities != nil {
				t.view.capabilities = capabilities
			}
			if err != nil {
				t.state.failure = a.vcsFailureText(err)
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_status", documentLogError(err)))
				return
			}
			t.state.status = &status
			if t.state.change(t.state.selected) == nil {
				t.state.selected = ""
			}
			for path := range t.state.include {
				if t.state.change(path) == nil {
					delete(t.state.include, path)
				}
			}
			t.state.collectRows()
		}
	})
}

// loadVcsHistory reads the next page of the working copy's revisions, the first when none is
// loaded.
func (a *App) loadVcsHistory(p *project, t vcsTarget, more bool) {
	if t.state.historyLoading {
		return
	}
	arguments := map[string]any{"limit": vcsHistoryLimit}
	if more && t.state.cursor != nil {
		arguments["cursor"] = *t.state.cursor
	} else {
		more = false
	}
	t.state.historyLoading, t.state.historyFailure = true, ""
	call := p.vcs.call(t.window, t.root, core.VcsHistory, arguments, vcsReadTimeout)
	sessions := p.vcs.runtime()
	a.background(p, vcsReadTimeout, func(ctx context.Context) func(*App) {
		decoded, capabilities, err := a.runVcs(ctx, p, sessions, call)
		var page core.VcsHistoryReply
		if err == nil {
			err = json.Unmarshal(decoded, &page)
		}
		return func(a *App) {
			if !p.stillShows(t) {
				return
			}
			t.state.historyLoading = false
			if capabilities != nil {
				t.view.capabilities = capabilities
			}
			if err != nil {
				t.state.historyFailure = a.vcsFailureText(err)
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_history", documentLogError(err)))
				return
			}
			if !more {
				t.state.history, t.state.revision = nil, -1
			}
			t.state.history = append(t.state.history, page.Entries...)
			t.state.cursor, t.state.historyLoaded = page.NextCursor, true
		}
	})
}

// runVcsChange runs an operation that changes the working copy or the repository, one at a time
// per window; done says what it did once it succeeded. The status is read again either way, as
// a failed operation may have done part of its work.
func (a *App) runVcsChange(p *project, t vcsTarget, action, operation string, arguments any, done func(a *App, decoded json.RawMessage) string) {
	if t.view.busy != "" {
		a.notify(i18n.Shared(a.language(), "native.waitForTheRunningVersionControlActionToFinish"))
		return
	}
	a.performed(action, surfaceButton)
	t.view.busy, t.view.notice, t.view.failure = operation, "", ""
	call := p.vcs.call(t.window, t.root, operation, arguments, vcsWriteTimeout)
	sessions := p.vcs.runtime()
	a.background(p, vcsWriteTimeout, func(ctx context.Context) func(*App) {
		decoded, capabilities, err := a.runVcs(ctx, p, sessions, call)
		return func(a *App) {
			if p.vcs.views[t.id] != t.view {
				return
			}
			t.view.busy = ""
			if capabilities != nil {
				t.view.capabilities = capabilities
			}
			if err != nil {
				t.view.failure = a.vcsFailureText(err)
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_"+operation, documentLogError(err)))
			} else {
				t.view.notice = done(a, decoded)
			}
			if p.stillShows(t) {
				a.refreshVcsStatus(p, t)
				if t.state.historyLoaded {
					a.loadVcsHistory(p, t, false)
				}
			}
		}
	})
}

// commitVcs commits the included changes with the message in the window.
func (a *App) commitVcs(p *project, t vcsTarget) {
	message := strings.TrimSpace(t.view.message.Text())
	paths := t.state.commitPaths()
	if message == "" || len(paths) == 0 {
		return
	}
	a.runVcsChange(p, t, "vcs.commit", core.VcsCheckin, map[string]any{"paths": paths, "message": message}, func(a *App, decoded json.RawMessage) string {
		var reply core.VcsCheckinReply
		_ = json.Unmarshal(decoded, &reply)
		t.view.message.SetText("")
		t.state.include = nil
		if reply.Revision != nil {
			return i18n.SharedFormat(a.language(), "native.committedRevisionArg1", map[string]string{"arg1": reply.Revision.Label()})
		}
		return i18n.Shared(a.language(), "native.committed2")
	})
}

// rollbackVcs discards the local edits of paths, which the user confirmed.
func (a *App) rollbackVcs(p *project, t vcsTarget, paths []string) {
	a.runVcsChange(p, t, "vcs.rollback", core.VcsRollback, map[string]any{"paths": paths}, func(*App, json.RawMessage) string { return "" })
}

// updateVcs brings the working copy to the repository's latest revision.
func (a *App) updateVcs(p *project, t vcsTarget) {
	a.runVcsChange(p, t, "vcs.update", core.VcsUpdate, struct{}{}, func(a *App, decoded json.RawMessage) string {
		var reply core.VcsUpdateReply
		_ = json.Unmarshal(decoded, &reply)
		if reply.Revision != nil {
			return i18n.SharedFormat(a.language(), "native.updatedToRevisionArg1", map[string]string{"arg1": reply.Revision.Label()})
		}
		return i18n.Shared(a.language(), "native.updated2")
	})
}

// resolveVcs marks the conflicts of paths resolved.
func (a *App) resolveVcs(p *project, t vcsTarget, paths []string) {
	a.runVcsChange(p, t, "vcs.resolve", core.VcsResolve, map[string]any{"paths": paths}, func(*App, json.RawMessage) string { return "" })
}

// cleanupVcs finishes or undoes the interrupted actions that left the working copy locked.
func (a *App) cleanupVcs(p *project, t vcsTarget) {
	a.runVcsChange(p, t, "vcs.cleanup", core.VcsCleanup, struct{}{}, func(a *App, _ json.RawMessage) string {
		return i18n.Shared(a.language(), "native.theWorkingCopyWasCleanedUp")
	})
}

// vcsPaths are the paths an operation on change names: its path, and the old path of a move.
func vcsPaths(change *core.VcsChange) []string {
	paths := []string{change.Path}
	if change.OldPath != nil && *change.OldPath != change.Path {
		paths = append(paths, *change.OldPath)
	}
	return paths
}

// vcsStatusLetter is the letter that stands for a status in the list and in a Diff tab.
func vcsStatusLetter(status string) string {
	switch status {
	case "modified":
		return "M"
	case "added", "copied":
		return "A"
	case "deleted":
		return "D"
	case "missing":
		return "!"
	case "renamed", "replaced":
		return "R"
	case "typeChanged":
		return "T"
	case "unversioned":
		return "?"
	case "ignored":
		return "I"
	case "conflicted":
		return "C"
	case "switched":
		return "S"
	}
	return "M"
}

// showVcsDiff opens a Diff tab of change: its base revision, which the provider reads, against
// the file in the working copy. Core compares the two; the tab is read-only.
func (a *App) showVcsDiff(p *project, t vcsTarget, change core.VcsChange) {
	kernel, ok := a.vcsKernel()
	if !ok {
		return
	}
	a.performed("vcs.showDiff", surfaceButton)
	call := p.vcs.call(t.window, t.root, core.VcsBaseContent, map[string]any{"path": change.Path}, vcsReadTimeout)
	sessions := p.vcs.runtime()
	a.background(p, vcsReadTimeout, func(ctx context.Context) func(*App) {
		file, capabilities, err := a.readVcsDiff(ctx, p, sessions, kernel, call, change)
		return func(a *App) {
			if capabilities != nil && p.vcs.views[t.id] == t.view {
				t.view.capabilities = capabilities
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("vcs_diff", documentLogError(err)))
				a.notifyError(a.vcsFailureText(err))
				return
			}
			language := a.language()
			diff := core.GitChange{Path: change.Path, Status: file.Status, Worktree: true}
			if change.OldPath != nil {
				diff.OriginalPath = *change.OldPath
			}
			saved := &savedSource{
				before: i18n.Shared(language, "native.baseRevision"),
				after:  i18n.Shared(language, "native.workingCopy"),
				files:  []core.GitDiffFile{file},
			}
			a.showDiff(p, t.root.Path, "vcs:"+t.window.Vcs, diff, []core.GitChange{diff}, diffOrigin{saved: saved})
		}
	})
}

// readVcsDiff reads the base of change and its file in the working copy and has Core compare
// them. A file that is binary on either side is a binary diff without lines.
func (a *App) readVcsDiff(ctx context.Context, p *project, sessions *vcsRuntime, kernel vcsKernel, call vcsCall, change core.VcsChange) (core.GitDiffFile, map[string]int, error) {
	decoded, capabilities, err := a.runVcs(ctx, p, sessions, call)
	if err != nil {
		return core.GitDiffFile{}, capabilities, err
	}
	var base core.VcsBaseContentReply
	if err := json.Unmarshal(decoded, &base); err != nil {
		return core.GitDiffFile{}, capabilities, err
	}
	var current []byte
	if change.Status != "deleted" && change.Status != "missing" {
		current, err = os.ReadFile(filepath.Join(call.root, filepath.FromSlash(change.Path)))
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return core.GitDiffFile{}, capabilities, err
		}
	}
	file := core.GitDiffFile{Path: change.Path, Status: vcsStatusLetter(change.Status), Lines: []core.GitDiffLine{}, Rows: []core.GitDiffRow{}}
	if change.OldPath != nil {
		file.OriginalPath = *change.OldPath
	}
	if base.Binary || !utf8.Valid(current) || bytes.IndexByte(current, 0) >= 0 {
		file.IsBinary = true
		return file, capabilities, nil
	}
	before := ""
	if base.Content != nil {
		before = *base.Content
	}
	compared, err := kernel.CompareTexts(ctx, before, string(current))
	if err != nil {
		return core.GitDiffFile{}, capabilities, err
	}
	file.Lines, file.Rows, file.Additions, file.Deletions = compared.Lines, compared.Rows, compared.Additions, compared.Deletions
	return file, capabilities, nil
}
