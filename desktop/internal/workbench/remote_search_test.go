package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// The host files the search tests search besides remoteTestReadme.
const (
	remoteTestNotes = remoteTestFolder + "/NOTES.md"
	remoteTestOther = remoteTestFolder + "/OTHER.md"
)

// remoteHostSearch stands in for Core's search index of the workspace's folder: the files it
// lists, by path relative to the folder, whose text a query reads from the host when it matches,
// as Core's matcher reads the current text. A file the index does not list is not found, so a
// file added on the host shows only once the index is updated or built again.
type remoteHostSearch struct {
	// indexed is nil until a query builds the index from the host's files; builds counts how
	// often one did.
	indexed map[string]bool
	builds  int
	// updates are the paths of each incremental update.
	updates [][]string
	// sessions are the sessions the search's requests carried, "" for a request that carried no
	// remote workspace.
	sessions []string
}

// searchSessionLocked records the session ctx's request carries. A request whose workspace has
// no session fails as Core does; one that carries no workspace is about the empty placeholder, so
// it answers with nothing (ok false). The lock is held.
func (k *remoteHostKernel) searchSessionLocked(ctx context.Context, command string) (bool, error) {
	binding := core.RemoteWorkspaceOf(ctx)
	if binding == nil {
		k.search.sessions = append(k.search.sessions, "")
		return false, nil
	}
	session := binding.SessionID()
	k.search.sessions = append(k.search.sessions, session)
	if session == "" {
		return false, &core.Error{Command: command, Code: core.CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	return true, nil
}

// indexLocked is the index's files in order, built from the host's files when there is none.
// The lock is held.
func (k *remoteHostKernel) indexLocked() []string {
	if k.search.indexed == nil {
		k.search.indexed = map[string]bool{}
		k.search.builds++
		for host := range k.files {
			if relative, ok := strings.CutPrefix(host, remoteTestFolder+"/"); ok {
				k.search.indexed[relative] = true
			}
		}
	}
	return slices.Sorted(maps.Keys(k.search.indexed))
}

// matchesLocked are the file names that contain query, when names, and the lines that do, when
// content, of the index's files. The lock is held.
func (k *remoteHostKernel) matchesLocked(query string, names, content bool) []core.WorkspaceSearchMatch {
	var matches []core.WorkspaceSearchMatch
	for _, relative := range k.indexLocked() {
		data, ok := k.files[remoteTestFolder+"/"+relative]
		if !ok {
			continue
		}
		if names && strings.Contains(strings.ToLower(path.Base(relative)), strings.ToLower(query)) {
			matches = append(matches, core.WorkspaceSearchMatch{Kind: "file", Path: relative, Preview: relative})
		}
		if !content {
			continue
		}
		for i, text := range strings.Split(string(data), "\n") {
			at := strings.Index(text, query)
			if at < 0 {
				continue
			}
			line, source := i+1, text
			ranges := []core.SearchNameRange{{Start: utf16Length(text[:at]), Length: utf16Length(query)}}
			matches = append(matches, core.WorkspaceSearchMatch{
				Kind: "content", Path: relative, Line: &line, Preview: text,
				SourceLine: &source, ContentMatchRanges: ranges, PreviewRanges: ranges,
			})
		}
	}
	return matches
}

func (k *remoteHostKernel) InvalidateWorkspaceSearch(ctx context.Context, _ string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	ok, err := k.searchSessionLocked(ctx, "workspace.searchIndex.invalidate")
	if ok {
		k.search.indexed = nil
	}
	return err
}

func (k *remoteHostKernel) UpdateWorkspaceSearch(ctx context.Context, _ string, paths []string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	ok, err := k.searchSessionLocked(ctx, "workspace.searchIndex.update")
	if !ok {
		return err
	}
	k.search.updates = append(k.search.updates, slices.Clone(paths))
	if k.search.indexed == nil {
		return nil
	}
	for _, relative := range paths {
		if _, exists := k.files[remoteTestFolder+"/"+relative]; exists {
			k.search.indexed[relative] = true
		} else {
			delete(k.search.indexed, relative)
		}
	}
	return nil
}

func (k *remoteHostKernel) SearchWorkspacePage(ctx context.Context, request core.WorkspaceSearchRequest) (core.WorkspaceSearchPage, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if ok, err := k.searchSessionLocked(ctx, "workspace.search"); !ok {
		return core.WorkspaceSearchPage{}, err
	}
	names := request.MaxFileResults == nil || *request.MaxFileResults > 0
	return core.WorkspaceSearchPage{Matches: k.matchesLocked(request.Query, names, true)}, nil
}

func (k *remoteHostKernel) CountWorkspaceSearch(ctx context.Context, request core.WorkspaceSearchRequest) (core.WorkspaceSearchCounts, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	counts := core.WorkspaceSearchCounts{FileOccurrences: map[string]int{}}
	if ok, err := k.searchSessionLocked(ctx, "workspace.search"); !ok {
		return counts, err
	}
	for _, match := range k.matchesLocked(request.Query, false, true) {
		occurrences := strings.Count(*match.SourceLine, request.Query)
		if counts.FileOccurrences[match.Path] == 0 {
			counts.Files++
		}
		counts.Lines++
		counts.Occurrences += occurrences
		counts.FileOccurrences[match.Path] += occurrences
	}
	return counts, nil
}

func (k *remoteHostKernel) SearchEverywherePage(ctx context.Context, request core.EverywhereSearchRequest) (core.EverywhereSearchPage, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if ok, err := k.searchSessionLocked(ctx, "workspace.searchEverywhere"); !ok {
		return core.EverywhereSearchPage{}, err
	}
	names, content := slices.Contains(request.ResultKinds, "file"), slices.Contains(request.ResultKinds, "content")
	return core.EverywhereSearchPage{Matches: k.matchesLocked(request.Query, names, content)}, nil
}

// PreviewWorkspaceReplace plans the replacement of query in the index's files, each with the
// identity of the bytes it read, as Core does.
func (k *remoteHostKernel) PreviewWorkspaceReplace(ctx context.Context, request core.WorkspaceReplaceRequest) ([]core.WorkspaceReplaceFile, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if ok, err := k.searchSessionLocked(ctx, "workspace.replacePreview"); !ok {
		return nil, err
	}
	var files []core.WorkspaceReplaceFile
	for _, relative := range k.indexLocked() {
		data, ok := k.files[remoteTestFolder+"/"+relative]
		if !ok || !strings.Contains(string(data), request.Query) {
			continue
		}
		file := core.WorkspaceReplaceFile{Path: relative, ReplacementText: strings.ReplaceAll(string(data), request.Query, request.Replacement)}
		for i, text := range strings.Split(string(data), "\n") {
			if n := strings.Count(text, request.Query); n > 0 {
				file.Matches = append(file.Matches, core.WorkspaceReplaceMatch{Line: i + 1, Before: text, After: strings.ReplaceAll(text, request.Query, request.Replacement), OccurrenceCount: n})
			}
		}
		identity := sha256.Sum256(data)
		file.SourceIdentity = hex.EncodeToString(identity[:])
		files = append(files, file)
	}
	return files, nil
}

// searched reads the host's search record.
func (k *remoteHostKernel) searched() remoteHostSearch {
	k.mu.Lock()
	defer k.mu.Unlock()
	s := k.search
	s.updates, s.sessions = slices.Clone(s.updates), slices.Clone(s.sessions)
	return s
}

// remove deletes the host file path as someone on the host does.
func (k *remoteHostKernel) remove(path string) {
	k.set(func(k *remoteHostKernel) { delete(k.files, path) })
}

// overSession reports that every request in sessions went over the workspace's first session.
func overSession(sessions []string) bool {
	return len(sessions) > 0 && !slices.ContainsFunc(sessions, func(s string) bool { return s != "session-1" })
}

// matchesIn are the paths and lines of matches, as path:line, a file name as path.
func matchesIn(matches []core.WorkspaceSearchMatch) []string {
	found := make([]string, 0, len(matches))
	for _, match := range matches {
		if match.Line == nil {
			found = append(found, match.Path)
		} else {
			found = append(found, match.Path+":"+strconv.Itoa(*match.Line))
		}
	}
	return found
}

// searchAndWait runs query in Find in Files and waits for its results and their counts.
func (h *harness) searchAndWait(p *project, query searchQuery) {
	h.t.Helper()
	h.app.updateProjectSearch(p, query)
	h.awaitSearch(p)
}

// awaitSearch waits for Find in Files to show the results and the counts of the current query.
func (h *harness) awaitSearch(p *project) {
	h.t.Helper()
	h.await("the search's results and counts", func() bool {
		s := &p.search
		return s.failed || (!s.loading && !s.running && s.counts != nil && s.countCancel == nil)
	})
	if p.search.failed {
		h.t.Fatal("the search failed")
	}
}

// Find in Files of a remote workspace searches the host's folder over the workspace's session,
// and a result opens the host's file at its match in the editor; the Find tool window works there.
// A file added on the host is found after the host watch reported it, which updates the index
// with its path instead of building it again. Neither the host nor its paths are logged.
func TestRemoteWorkspaceFindsInTheHostsFiles(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	h.app.searchView.delay = 0
	k.put(remoteTestReadme, "# Project\nfind the needle\n")
	p := h.openRemoteTestProject(t)
	h.awaitWatching(p)

	h.searchAndWait(p, searchQuery{text: "needle"})
	if got, want := matchesIn(p.search.matches), []string{"README.md:2"}; !slices.Equal(got, want) {
		t.Fatalf("found %q, want %q", got, want)
	}
	if c := p.search.counts; c.Files != 1 || c.Occurrences != 1 {
		t.Fatalf("counted %d files and %d occurrences, want 1 and 1", c.Files, c.Occurrences)
	}
	built := k.searched().builds

	k.put(remoteTestNotes, "a needle too\n")
	k.lastWatch(t).changed(t, "NOTES.md")
	h.await("the host's new file in the results", func() bool {
		return slices.Contains(matchesIn(p.search.matches), "NOTES.md:1") && !p.search.loading && !p.search.running
	})
	h.awaitSearch(p)
	s := k.searched()
	if s.builds != built || len(s.updates) != 1 || !slices.Equal(s.updates[0], []string{"NOTES.md"}) {
		t.Fatalf("the change built the index %d more times and updated it with %q, want one update with its path", s.builds-built, s.updates)
	}
	if !overSession(s.sessions) {
		t.Fatalf("the search went over sessions %q, want the workspace's", s.sessions)
	}

	match := p.search.matches[slices.Index(matchesIn(p.search.matches), "NOTES.md:1")]
	h.app.openSearchResult(p, match)
	notes := filepath.Join(p.root, "NOTES.md")
	awaitDocumentState(t, h, func() bool { _, opening := p.docs.opening[notes]; return p.docs.byPath(notes) != nil && !opening })
	d := p.docs.byPath(notes)
	if text, _ := d.view.Text(); string(text) != "a needle too\n" {
		t.Fatalf("opened %q, want the host's text", text)
	}
	if line, column := d.view.Caret(); line != 0 || column != 2 {
		t.Fatalf("opened at %d:%d, want at the match, 0:2", line, column)
	}
	if _, err := os.Lstat(notes); err == nil {
		t.Fatal("the result was read from the placeholder")
	}

	h.app.openToolWindow(itemFind)
	h.redraw()
	if h.showsWrapped(i18n.Shared(h.app.language(), "desktop.remote.workspace.localOnly")) {
		t.Fatal("the Find tool window says it does not work in a remote workspace")
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}

// A search that reads folders the host watch leaves out, one that includes generated files, builds
// the index from the host for every query. So does every search once the host ran out of watches,
// whose changes then no longer reach the index; the host watch alone tells the user so, once.
func TestRemoteSearchBuildsTheIndexAgainWhileTheHostWatchMisses(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	lang := h.app.language()
	h.app.searchView.delay = 0
	k.put(remoteTestReadme, "needle\n")
	p := h.openRemoteTestProject(t)
	h.awaitWatching(p)
	w := k.lastWatch(t)

	h.searchAndWait(p, searchQuery{text: "needle", includeGenerated: true})
	built := k.searched().builds
	k.put(remoteTestNotes, "needle\n")
	w.changed(t, "NOTES.md")
	h.await("the generated search again", func() bool { return k.searched().builds > built })
	h.awaitSearch(p)
	if s := k.searched(); s.builds != built+1 || len(s.updates) != 0 {
		t.Fatalf("the change built the index %d more times and updated it %d times, want it built again", s.builds-built, len(s.updates))
	}

	// Without generated files, the index the last query built is current.
	built = k.searched().builds
	h.searchAndWait(p, searchQuery{text: "needle"})
	if got := k.searched().builds; got != built {
		t.Fatalf("the search built the index %d more times, want none", got-built)
	}

	w.deliver(t, func(events core.RemoteWatchEvents) { events.LimitReached() })
	h.await("the host out of watches", func() bool { return p.remote.watch.partial })
	if p.search.watchAvailable || !p.search.fullResync {
		t.Fatal("Find in Files still trusts the host watch")
	}
	// Every change from then on builds the index again, not only the first one after the limit.
	for _, line := range []string{"OTHER.md:1", "OTHER.md:2"} {
		built = k.searched().builds
		other, _ := k.file(remoteTestOther)
		k.put(remoteTestOther, other+"needle\n")
		w.changed(t, "OTHER.md")
		h.await("the search after the host ran out of watches", func() bool {
			return slices.Contains(matchesIn(p.search.matches), line) && !p.search.loading && !p.search.running
		})
		h.awaitSearch(p)
		if s := k.searched(); s.builds != built+1 || len(s.updates) != 0 {
			t.Fatalf("the change built the index %d more times and updated it %d times, want it built again", s.builds-built, len(s.updates))
		}
	}
	if h.countNotified(i18n.Shared(lang, "desktop.search.watchUnavailable")) != 0 || h.countNotified(i18n.Shared(lang, "desktop.project.watchUnavailable")) != 1 {
		t.Fatal("the missing watches were not told once, by the host watch")
	}
}

// Search Everywhere of a remote workspace searches the host's file names and text over its
// session with every scope, not only actions, and asks no language server; a file added on the
// host shows in the open popup once the host watch reported it.
func TestRemoteSearchEverywhereSearchesTheHost(t *testing.T) {
	h, k, _, _ := remoteWorkspaceHarness(t)
	k.put(remoteTestReadme, "# Project\n")
	p := h.openRemoteTestProject(t)
	h.awaitWatching(p)

	h.app.openEverywhere(p)
	h.app.everywhereView.query.SetText("README")
	h.app.updateEverywhere(p, "README", 0)
	awaitEverywhere := func(what string, want string) {
		t.Helper()
		h.await(what, func() bool {
			s := &p.everywhere
			return s.failed || (!s.loading && !s.running && slices.Contains(matchesIn(s.matches), want))
		})
		if p.everywhere.failed {
			t.Fatal("Search Everywhere failed")
		}
	}
	awaitEverywhere("the host's file name", "README.md")
	if p.everywhere.scope != 0 || p.everywhereActionsOnly() {
		t.Fatal("Search Everywhere offers only actions in a remote workspace")
	}

	k.put(remoteTestNotes, "see README\n")
	k.lastWatch(t).changed(t, "NOTES.md")
	awaitEverywhere("the host's new file's text", "NOTES.md:1")
	if s := k.searched(); !overSession(s.sessions) {
		t.Fatalf("Search Everywhere went over sessions %q, want the workspace's", s.sessions)
	}
	if p.everywhereSymbols.discoveryStarted || len(p.everywhereSymbols.servers) != 0 {
		t.Fatal("Search Everywhere asked a language server about the remote workspace")
	}
	h.app.closeEverywhere(p)
}

// Replace All writes the host's closed files over the workspace's session, nothing below the
// placeholder, and only while each still holds the bytes the preview read: a file changed on the
// host since is a conflict and a file removed says so in the user's words. Neither the host nor
// its paths are logged.
func TestRemoteReplaceAllWritesTheHostsFiles(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.put(remoteTestReadme, "needle one\n")
	k.put(remoteTestNotes, "needle two\n")
	k.put(remoteTestOther, "needle three\n")
	p := h.openRemoteTestProject(t)
	h.awaitWatching(p)
	replaceAll := func(want int) {
		t.Helper()
		h.app.previewProjectReplace(p, searchQuery{text: "needle"}, "thread")
		h.await("the replacement's preview", func() bool { return !p.replace.loading })
		if p.replace.failure != "" || len(p.replace.files) != want {
			t.Fatalf("the preview listed %d files, want %d", len(p.replace.files), want)
		}
	}
	apply := func() {
		t.Helper()
		h.app.applyProjectReplace(p)
		h.await("the replacement", func() bool { return !p.replace.applying && !p.replace.open })
		h.settle()
	}

	replaceAll(3)
	k.remove(remoteTestNotes)
	apply()
	if got, _ := k.file(remoteTestReadme); got != "thread one\n" {
		t.Fatalf("README.md holds %q on the host, want the replacement", got)
	}
	if got, _ := k.file(remoteTestOther); got != "thread three\n" {
		t.Fatalf("OTHER.md holds %q on the host, want the replacement", got)
	}
	if !h.notified(h.app.text.Search.ReplacePartlyFailed("2", "1", i18n.Shared(lang, "desktop.remote.document.notFound"))) {
		t.Fatal("the removed file was not told in the user's words")
	}

	k.put(remoteTestReadme, "needle again\n")
	replaceAll(1)
	k.put(remoteTestReadme, "needle changed on the host\n")
	apply()
	if got, _ := k.file(remoteTestReadme); got != "needle changed on the host\n" {
		t.Fatalf("README.md holds %q on the host: the replacement overwrote a change made there", got)
	}
	if !h.notified(h.app.text.Search.ReplacePartlyFailed("0", "1", h.app.text.Search.ReplaceConflict)) {
		t.Fatal("the change made on the host was not told as a conflict")
	}

	for _, name := range []string{"README.md", "NOTES.md", "OTHER.md"} {
		if _, err := os.Lstat(filepath.Join(p.root, name)); err == nil {
			t.Fatalf("the replacement wrote %s below the placeholder", name)
		}
	}
	if sessions := k.searched().sessions; !overSession(sessions) || !overSession(k.fileSessions) {
		t.Fatalf("the replacement went over sessions %q and %q, want the workspace's", sessions, k.fileSessions)
	}
	if event := loggedAny(t, logger, remoteTestHost, remoteTestHome); event != "" {
		t.Fatalf("logged the host or its paths: %s", event)
	}
}
