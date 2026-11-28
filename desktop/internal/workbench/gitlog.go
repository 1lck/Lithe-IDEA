package workbench

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// The log tab of the Git tool window asks the kernel for everything it shows: the
// references, the history in pages, the laid out graph, the changed files and the
// details of a commit. This file keeps what the kernel answered and decides when to ask
// again; gitlog_view.go declares the tab and gitgraph.go paints the graph.

const (
	// logPageSize is the number of commits the log loads at a time.
	logPageSize = 100
	// logWindowSize is the number of commits the graph keeps its lanes and colors stable
	// against: the kernel's limit for one history walk.
	logWindowSize = 5000
	// logDateChunk is the most commits the kernel's date query takes at once.
	logDateChunk = 4096
	// logLoadMoreMargin is how near the end of the list the next page is asked for.
	logLoadMoreMargin = 240
)

// logDelays are the pauses the log waits before it asks the kernel: the files of a
// selected commit wait until the selection rests, and a filter until the typing stops.
// Tests set them to zero.
type logDelays struct {
	files  time.Duration
	filter time.Duration
}

var defaultLogDelays = logDelays{files: 120 * time.Millisecond, filter: 180 * time.Millisecond}

// logDate is a date filter of the commit list.
type logDate int

const (
	logAnyTime logDate = iota
	logToday
	logYesterday
	logLast7Days
	logLast30Days
	logDateCount
)

// logFiles is the state of the changed files of the selected commit.
type logFiles int

const (
	logFilesIdle logFiles = iota
	logFilesLoading
	logFilesFailed
	logFilesReady
)

// logPopover is the popover of the log tab that is open.
type logPopover int

const (
	logPopoverNone logPopover = iota
	logPopoverMenu
	logPopoverBranch
	logPopoverUser
	logPopoverDate
	logPopoverPath
	// logPopoverBranchSettings is the menu of the reference pane's settings.
	logPopoverBranchSettings
	// logPopoverViewMore is the overflow menu of the filter bar: the view buttons it has no room
	// for.
	logPopoverViewMore
	// logPopoverRoots is the list of the repositories of the project folder under the name of the
	// one the log walks, after the filter chips.
	logPopoverRoots
)

// logSection is one section of the reference pane: the local branches, the remote ones
// or the tags, with the folder tree the kernel grouped their names into.
type logSection struct {
	kind  string
	refs  []core.GitReference
	nodes []core.ReferenceTreeNode
}

type logReveal uint8

const (
	logRevealNone logReveal = iota
	logRevealSelection
	logRevealWithFocus
)

// gitLogState is what the log tab of an open project knows. It belongs to the project,
// so a project opened later starts from nothing.
type gitLogState struct {
	// started is set once the log was asked for.
	started bool
	// gen counts the loads of the history; the answer of an older load is dropped.
	gen     int
	loading bool
	err     error

	refs core.GitReferences
	// current is the short name of the checked out branch, empty when HEAD is detached.
	current string
	// comparing says a comparison of the Log tab's compare buttons is being read.
	comparing bool
	sections  [3]logSection

	// reference is the full name of the reference the log walks, empty for all of them;
	// referenceLabel is its short name, for the tab.
	reference      string
	referenceLabel string

	commits []core.GitCommit
	// byHash finds a loaded commit by the key the graph knows it by: its hash, or the merged key
	// while the log walks several repositories.
	byHash      map[string]int
	cursor      string
	cursorRoot  string
	cursorOwner context.Context
	hasMore     bool
	// walks are the repositories the log walks while it walks several, origins where each of the
	// commits comes from and pending the walks whose next page the list waits on; all nil while
	// the log walks one repository (gitlog_multi.go).
	walks   []logWalk
	origins []logOrigin
	pending []int
	// A merged continuation can change row keys. Publish its identities only
	// when the corresponding graph is ready.
	stagedMerge *logMergedPage
	// loadingMore and moreFailed are the state of the next page.
	loadingMore bool
	moreFailed  bool
	readCancel  context.CancelFunc
	// limitReached says the log read as many commits as the Git Log settings let it while the
	// history goes on; the list ends there with a note offering the settings (gitlog_limits.go).
	limitReached bool
	// window is the wider history the graph's lanes and colors stay stable against.
	window       []core.GraphCommit
	windowCancel context.CancelFunc

	// graph is the kernel's layout of the commits the filters keep, and projGen counts
	// the layouts asked for, so the newest one wins.
	graph       core.Graph
	projGen     int
	projStop    chan struct{}
	projFailed  bool
	currentRows map[string]bool
	// projectedRows maps a loaded commit index to its one-based visible row when
	// filtering or the repository context changes the order. Nil uses the loaded index.
	projectedRows []int32

	// The filters as applied, and the files of the commits the path filter has seen.
	text, user, path string
	date             logDate
	pathFiles        map[string][]core.GitCommitFile

	// selected is the hash of the selected commit; files, filesState and detail are what
	// the kernel answered about it.
	selected   string
	files      []core.GitCommitFile
	filesState logFiles
	// folders are the folders of files, grouped once when they arrive, and closedFolders the
	// ones the user closed in this commit's files.
	folders       []logFolder
	closedFolders map[string]bool
	detail        *core.GitCommitDetail
	selGen        int
	selStop       chan struct{}

	showDetails    bool
	decorations    bool
	expanded       bool
	branchesHidden bool
	// collapsed holds the sections and folders of the reference pane the user closed.
	collapsed map[string]bool
	// refSelected is the full name of the reference selected in the pane.
	refSelected string
	popover     logPopover
	// reveal scrolls the selected commit into view and can give its row keyboard focus.
	reveal logReveal

	// users is the sorted list of authors of the loaded commits, for the user filter;
	// usersFor is the number of commits it was made from.
	users    []string
	usersFor int

	// sync is the fetch and update the menu runs, with the dialogs they open.
	sync syncState
}

func newGitLogState() gitLogState {
	return gitLogState{showDetails: true, decorations: true, collapsed: map[string]bool{}}
}

// commit returns the loaded commit with hash.
func (l *gitLogState) commit(hash string) (core.GitCommit, bool) {
	if i, ok := l.byHash[hash]; ok {
		return l.commits[i], true
	}
	return core.GitCommit{}, false
}

// filtered reports that a filter other than the reference narrows the list.
func (l *gitLogState) filtered() bool {
	return l.text != "" || l.user != "" || l.path != "" || l.date != logAnyTime
}

// currentReference is the checked out local branch, or HEAD when it is detached or the
// references are not loaded.
func (l *gitLogState) currentReference() core.GitReference {
	for _, r := range l.refs.References {
		if r.Kind == "local" && r.IsCurrent {
			return r
		}
	}
	return headReference
}

// reference returns the reference of the pane with full name, if there is one.
func (l *gitLogState) findReference(full string) (core.GitReference, bool) {
	for _, s := range l.sections {
		for _, r := range s.refs {
			if r.FullName == full {
				return r, true
			}
		}
	}
	return core.GitReference{}, false
}

// refreshLog retries discovery when an open log has yet to learn the replacement session's repositories.
func (a *App) refreshLog(p *project) {
	if p.logReads.retired {
		return
	}
	if p.awaitsRemoteLogRoots() {
		a.loadGit(p)
		return
	}
	a.loadLog(p)
}

// loadLog loads the log of p from the start: the references, the first page of history
// and its graph, then the wider window the graph is kept stable against.
func (a *App) loadLog(p *project) {
	if p.logReads.retired {
		return
	}
	l := &p.log
	if !l.started {
		*l = newGitLogState()
		l.started = true
	}
	a.releaseLogCursor(p)
	l.gen++
	gen := l.gen
	// A projection still running for the old commits must not land on the new ones.
	l.projGen++
	if l.projStop != nil {
		close(l.projStop)
		l.projStop = nil
	}
	l.loading, l.err = true, nil
	l.commits, l.byHash, l.cursor, l.cursorRoot, l.hasMore = nil, nil, "", "", false
	l.walks, l.origins, l.pending = nil, nil, nil
	l.stagedMerge = nil
	l.loadingMore, l.moreFailed, l.limitReached, l.window = false, false, false, nil
	l.graph, l.currentRows, l.projectedRows = core.Graph{}, nil, nil
	l.projFailed = false
	l.pathFiles = nil
	// The upstreams the graph paints were read for the repository before this one.
	a.logView.upstream, a.logView.upstreamFor = nil, nil
	a.selectCommit(p, "")
	if !p.logHasRepository() {
		l.loading = false
		l.refs, l.sections, l.current = core.GitReferences{}, [3]logSection{}, ""
		return
	}
	// The nested repositories' groups in the reference pane are read with the log (nested_refs.go).
	a.loadNestedReferences(p)
	if p.walksSeveral() {
		a.loadLogRepos(p, gen)
		return
	}
	kernel, root, reference := a.kernel, p.logRoot(), l.reference
	expanded, limit := l.expanded, a.gitLogLimit()
	owner := p.ctx
	l.readCancel = a.backgroundLogRead(p, func(ctx context.Context) logReadResult {
		refs, sections, current, err := readReferences(ctx, kernel, root)
		if err == nil && reference != "" && reference != headReference.FullName && !hasReference(refs.References, reference) {
			reference = ""
		}
		var page core.GitHistoryPage
		var graph core.Graph
		if err == nil {
			page, err = kernel.GitHistoryPage(ctx, root, reference, "", min(logPageSize, limit), limit)
		}
		if err == nil {
			commits := graphCommits(page.Commits)
			graph, err = kernel.GitGraph(ctx, core.GraphRequest{
				Commits: commits, RemoteNames: remoteNames(sections), RepositoryCommits: commits,
				Expanded: expanded, CurrentBranch: current,
			})
		}
		return logReadResult{logPageCursor(root, page.NextCursor), func(a *App) bool {
			if a.project != p || l.gen != gen || owner.Err() != nil {
				return false
			}
			l.stopGitLogRead()
			l.loading = false
			if err != nil {
				// Once the walked repository cannot be read, the references shown before are not its own.
				l.err = err
				l.refs, l.sections, l.current = core.GitReferences{}, [3]logSection{}, ""
				return false
			}
			l.refs, l.sections, l.current = refs, sections, current
			if reference == "" && l.reference != "" {
				l.reference, l.referenceLabel = "", ""
			}
			if l.refSelected != "" && l.refSelected != headReference.FullName && !hasReference(refs.References, l.refSelected) {
				l.refSelected = ""
			}
			if s := a.logView.compareSource; s != nil && a.logView.compareRoot == p.logRepositoryRoot() && !hasReference(refs.References, s.FullName) {
				a.logView.compareSource = nil
			}
			l.commits = page.Commits
			l.byHash = indexCommits(page.Commits)
			l.cursor, l.hasMore, l.limitReached = page.NextCursor, page.HasMore, page.LimitReached
			l.cursorRoot = root
			l.setGraph(graph)
			if l.filtered() {
				a.reproject(p, 0)
			}
			if page.HasMore {
				a.loadLogWindow(p, gen)
			}
			return true
		}}
	})
}

// readReferences asks for the references of root and the folder trees of each section.
func readReferences(ctx context.Context, kernel Kernel, root string) (core.GitReferences, [3]logSection, string, error) {
	var sections [3]logSection
	refs, err := kernel.GitReferences(ctx, root)
	if err != nil {
		return refs, sections, "", err
	}
	current := ""
	prioritized := map[string]bool{}
	for _, r := range refs.RecentReferences {
		prioritized[r.ShortName] = true
	}
	for i, kind := range [3]string{"local", "remote", "tag"} {
		sections[i].kind = kind
		for _, r := range refs.References {
			if r.Kind != kind {
				continue
			}
			sections[i].refs = append(sections[i].refs, r)
			if r.IsCurrent && kind == "local" {
				current = r.ShortName
				prioritized[r.ShortName] = true
			}
		}
	}
	for i := range sections {
		names := make([]string, len(sections[i].refs))
		for j, r := range sections[i].refs {
			names[j] = r.ShortName
		}
		if len(names) == 0 {
			continue
		}
		nodes, err := kernel.GitReferenceTree(ctx, names, prioritized)
		if err != nil {
			return refs, sections, current, err
		}
		sections[i].nodes = nodes
	}
	return refs, sections, current, nil
}

// loadLogWindow reads the wider history window, no wider than the log reads, and lays the
// graph out again against it.
func (a *App) loadLogWindow(p *project, gen int) {
	kernel, root, reference := a.kernel, p.logRoot(), p.log.reference
	size := min(logWindowSize, a.gitLogLimit())
	p.log.windowCancel = a.backgroundLogRead(p, func(ctx context.Context) logReadResult {
		page, err := kernel.GitHistoryPage(ctx, root, reference, "", size, size)
		if page.NextCursor != "" {
			closeCursor := a.logCursorCloser(ctx, kernel)
			closeCursor(root, page.NextCursor)
		}
		window := graphCommits(page.Commits)
		return logReadResult{publish: func(a *App) bool {
			if a.project != p || p.log.gen != gen {
				return false
			}
			p.log.windowCancel = nil
			if err != nil {
				return false
			}
			p.log.window = window
			a.reproject(p, 0)
			return true
		}}
	})
}

// loadMoreLog reads the next page once the current projection has been published.
func (a *App) loadMoreLog(p *project) {
	if p.logReads.retired {
		return
	}
	l := &p.log
	if l.projStop != nil || l.projFailed {
		// Until the new rows land, the viewport still sees the old end of
		// the list. Another page here would cancel and redo that projection.
		return
	}
	if l.walks != nil {
		a.loadMoreLogRepos(p)
		return
	}
	if l.loading || !l.hasMore || l.loadingMore || l.moreFailed || l.cursor == "" {
		return
	}
	l.loadingMore = true
	gen := l.gen
	kernel, root, reference, cursor := a.kernel, p.logRoot(), l.reference, l.cursor
	loaded := l.commits
	limit, owner := a.gitLogLimit(), p.ctx
	l.readCancel = a.backgroundLogRead(p, func(ctx context.Context) logReadResult {
		closeCursor := a.logCursorCloser(ctx, kernel)
		page, err := readGitLogPage(ctx, kernel, root, reference, cursor, logPageSize, limit, loaded, closeCursor)
		var byHash map[string]int
		if err == nil {
			// Readers of the old snapshot use only its immutable prefix.
			loaded = append(loaded, page.Commits...)
			byHash = indexCommits(loaded)
		}
		return logReadResult{logPageCursor(root, page.NextCursor), func(a *App) bool {
			if a.project != p || l.gen != gen || owner.Err() != nil {
				return false
			}
			l.stopGitLogRead()
			l.loadingMore = false
			if errors.Is(err, errLogHistoryChanged) {
				a.loadLog(p)
				return false
			}
			if err != nil {
				l.moreFailed = true
				return false
			}
			l.commits, l.byHash = loaded, byHash
			l.cursor, l.hasMore, l.limitReached = page.NextCursor, page.HasMore, page.LimitReached
			a.reproject(p, 0)
			return true
		}}
	})
}

func (l *gitLogState) stopGitLogRead() {
	if l.readCancel != nil {
		l.readCancel()
		l.readCancel = nil
	}
}

var errLogHistoryChanged = errors.New("Git history changed while its cursor was idle")

// readGitLogPage resumes a rejected cursor only after a fresh walk reproduces the
// loaded prefix. The caller reloads the log when refs changed during the pause.
func readGitLogPage(ctx context.Context, pager historyPager, root, reference, cursor string, pageSize, limit int, loaded []core.GitCommit, closeCursor func(root, cursor string)) (core.GitHistoryPage, error) {
	page, err := pager.GitHistoryPage(ctx, root, reference, cursor, pageSize, 0)
	var failure *core.Error
	if cursor == "" || !errors.As(err, &failure) || failure.Code != core.CodeInvalidRequest || failure.Details != cursor {
		return page, err
	}

	reopened := ""
	defer func() {
		if reopened != "" {
			closeCursor(root, reopened)
		}
	}()
	for checked := 0; checked < len(loaded); {
		maxCommits := 0
		if reopened == "" {
			maxCommits = limit
		}
		want := min(logWindowSize, len(loaded)-checked)
		page, err = pager.GitHistoryPage(ctx, root, reference, reopened, want, maxCommits)
		if err != nil {
			return core.GitHistoryPage{}, err
		}
		reopened = page.NextCursor
		if len(page.Commits) != want || !slices.EqualFunc(loaded[checked:checked+want], page.Commits, func(a, b core.GitCommit) bool {
			// Commit data is immutable, but decorations can move as refs change.
			return a.Hash == b.Hash && a.Decorations == b.Decorations
		}) {
			return core.GitHistoryPage{}, errLogHistoryChanged
		}
		checked += want
		if !page.HasMore || reopened == "" {
			if checked < len(loaded) {
				return core.GitHistoryPage{}, errLogHistoryChanged
			}
			return core.GitHistoryPage{LimitReached: page.LimitReached}, nil
		}
	}
	maxCommits := 0
	if reopened == "" {
		maxCommits = limit
	}
	page, err = pager.GitHistoryPage(ctx, root, reference, reopened, pageSize, maxCommits)
	if err != nil {
		return core.GitHistoryPage{}, err
	}
	reopened = ""
	return page, nil
}

// setLogReference makes the log walk one reference, or every reference when full is
// empty, and loads it again.
func (a *App) setLogReference(p *project, full, short string) {
	l := &p.log
	if p.logReads.retired || l.reference == full {
		return
	}
	if p.walksSeveral() {
		// A reference names a commit of one repository, so the log walks that reference in the
		// repository whose references it lists rather than every repository together.
		a.setLogRepo(p, p.logRepoID(), full, short)
		return
	}
	l.reference, l.referenceLabel = full, short
	a.loadLog(p)
}

// hasReference reports that refs lists a reference with full name.
func hasReference(refs []core.GitReference, full string) bool {
	return slices.ContainsFunc(refs, func(r core.GitReference) bool {
		return r.FullName == full
	})
}

// dropLogReference clears the log's walked, selected, or compared reference when it was deleted in root.
func (a *App) dropLogReference(p *project, root, full string) {
	if full == "" || root != p.logRepositoryRoot() {
		return
	}
	l := &p.log
	if l.reference == full {
		l.reference, l.referenceLabel = "", ""
	}
	if l.refSelected == full {
		l.refSelected = ""
	}
	if s := a.logView.compareSource; s != nil && a.logView.compareRoot == root && s.FullName == full {
		a.logView.compareSource = nil
	}
}

// renameLogReference moves the log's walked, selected, or compared reference to its new name in root.
func (a *App) renameLogReference(p *project, root, oldFull, newFull, newShort string) {
	if oldFull == "" || root != p.logRepositoryRoot() {
		return
	}
	l := &p.log
	if l.reference == oldFull {
		l.reference, l.referenceLabel = newFull, newShort
	}
	if l.refSelected == oldFull {
		l.refSelected = newFull
	}
	if s := a.logView.compareSource; s != nil && a.logView.compareRoot == root && s.FullName == oldFull {
		s.FullName, s.ShortName = newFull, newShort
	}
}

// logProjection is what one graph layout is made from, copied so the background work
// reads nothing the window thread changes.
type logProjection struct {
	commits []core.GitCommit
	// keys and roots are the merged keys and the repository roots of the commits while the log
	// walks several repositories, nil while it walks one.
	keys, roots      []string
	origins          []logOrigin
	window           []core.GraphCommit
	remotes          []string
	current          string
	expanded         bool
	text, user, path string
	after, before    *int64
	pathFiles        map[string][]core.GitCommitFile
}

// reproject lays the graph out again for the loaded commits and the filters, after
// delay. A newer call replaces one that has not answered yet.
func (a *App) reproject(p *project, delay time.Duration) {
	if p.logReads.retired {
		return
	}
	l := &p.log
	l.projGen++
	gen := l.projGen
	if l.projStop != nil {
		close(l.projStop)
	}
	stop := make(chan struct{})
	l.projStop = stop
	commits, origins, byHash := l.commits, l.origins, l.byHash
	staged := l.stagedMerge
	if staged != nil {
		commits, origins, byHash = staged.commits, staged.origins, staged.byHash
	}
	in := logProjection{
		commits:  commits,
		keys:     logKeys(origins),
		roots:    logRoots(l.walks, origins),
		origins:  origins,
		window:   l.window,
		remotes:  l.logRemoteNames(),
		current:  l.current,
		expanded: l.expanded,
		text:     strings.ToLower(l.text),
		user:     l.user,
		path:     strings.ToLower(l.path),
	}
	if len(in.window) < len(in.commits) || in.origins != nil {
		in.window = nil
	}
	if in.origins != nil {
		// A branch name may be checked out in each of the repositories, so none is the current one.
		in.current = ""
	}
	if l.date != logAnyTime {
		in.after, in.before = logDateBounds(l.date, a.now())
	}
	if in.path != "" {
		in.pathFiles = make(map[string][]core.GitCommitFile, len(l.pathFiles))
		for k, v := range l.pathFiles {
			in.pathFiles[k] = v
		}
	}
	dated := l.date != logAnyTime
	kernel, root := a.kernel, p.logRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-stop:
				return nil
			case <-ctx.Done():
				return func(*App) {
					if l.projGen == gen {
						l.projStop = nil
					}
				}
			}
		}
		ctx, cancel := untilStopped(ctx, stop)
		defer cancel()
		graph, files, err := in.run(ctx, kernel, root, dated)
		var projectedRows []int32
		if err == nil {
			projectedRows = in.indexProjectedRows(graph.Rows, byHash)
		}
		return func(a *App) {
			if l.projGen != gen {
				return
			}
			l.projStop = nil
			if files != nil {
				l.pathFiles = files
			}
			if err != nil {
				l.projFailed = true
				a.operationFailed("git_log_project", err)
				a.notifyError(a.text.Git.Failed(err.Error()))
				return
			}
			if staged != nil {
				if selected := l.selectedMergedKey(staged); selected != l.selected {
					if selected == "" {
						a.selectCommit(p, "")
					} else {
						l.selected = selected
					}
				}
				l.publishMerged(staged)
			}
			l.setGraph(graph)
			l.projectedRows = projectedRows
			l.projFailed = false
		}
	})
}

// run filters the commits and asks the kernel for the layout of what is left. It
// returns the files the path filter read, so the next run does not read them again.
func (in logProjection) run(ctx context.Context, kernel Kernel, root string, dated bool) (core.Graph, map[string][]core.GitCommitFile, error) {
	rootAt := func(i int) string {
		if in.roots != nil {
			return in.roots[i]
		}
		return root
	}
	var visible []string
	if in.text != "" || in.user != "" || in.path != "" || dated {
		keep := make([]bool, len(in.commits))
		for i, c := range in.commits {
			keep[i] = (in.text == "" || strings.Contains(strings.ToLower(c.Subject), in.text) || strings.HasPrefix(c.Hash, in.text)) &&
				(in.user == "" || c.AuthorName == in.user)
		}
		if dated {
			if err := in.keepDates(ctx, kernel, keep); err != nil {
				return core.Graph{}, nil, err
			}
		}
		if in.path != "" {
			// The path filter reads the files of commit after commit, which the console
			// records only when it records these reads.
			filtering := core.WithQueryCategory(ctx, core.GitQueryLogPathFilter)
			for i, c := range in.commits {
				if !keep[i] {
					continue
				}
				key := in.keyAt(i)
				files, ok := in.pathFiles[key]
				if !ok {
					var err error
					if files, err = kernel.GitCommitFiles(filtering, rootAt(i), c.Hash); err != nil {
						return core.Graph{}, in.pathFiles, err
					}
					in.pathFiles[key] = files
				}
				keep[i] = slices.ContainsFunc(files, func(f core.GitCommitFile) bool {
					return strings.Contains(strings.ToLower(f.Path), in.path)
				})
			}
		}
		visible = make([]string, 0, len(in.commits))
		for i := range in.commits {
			if keep[i] {
				visible = append(visible, in.keyAt(i))
			}
		}
	}
	commits := graphInput(in.commits, in.origins)
	window := in.window
	if window == nil {
		window = commits
	}
	request := core.GraphRequest{
		Commits: commits, RemoteNames: in.remotes, RepositoryCommits: window,
		VisibleHashes: visible, Expanded: in.expanded,
	}
	if in.origins != nil {
		// A merged list marks each repository's own current branch, as loadLogRepos does.
		request.CheckedOutHeads = true
	} else {
		request.CurrentBranch = in.current
	}
	graph, err := kernel.GitGraph(ctx, request)
	return graph, in.pathFiles, err
}

// keepDates clears keep for the commits the kernel finds outside the date bounds.
func (in logProjection) keepDates(ctx context.Context, kernel Kernel, keep []bool) error {
	for start := 0; start < len(in.commits); start += logDateChunk {
		end := min(start+logDateChunk, len(in.commits))
		entries := make([]core.HistoryDateEntry, 0, end-start)
		for i := start; i < end; i++ {
			c := in.commits[i]
			id := c.Hash
			if in.keys != nil {
				id = in.keys[i]
			}
			entries = append(entries, core.HistoryDateEntry{
				ID: id, Date: c.Date, UTCOffsetMinutes: c.DateUTCOffsetMinutes, FallbackUnixSeconds: c.DateUnixSeconds,
			})
		}
		ids, err := kernel.GitHistoryDates(ctx, entries, in.after, in.before)
		if err != nil {
			return err
		}
		match := make(map[string]bool, len(ids))
		for _, id := range ids {
			match[id] = true
		}
		for i := start; i < end; i++ {
			id := in.commits[i].Hash
			if in.keys != nil {
				id = in.keys[i]
			}
			keep[i] = keep[i] && match[id]
		}
	}
	return nil
}

// logDateBounds is the span of a date preset in the local time of now, in Unix seconds:
// from the start of its first day to the start of the day after its last.
func logDateBounds(date logDate, now time.Time) (after, before *int64) {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	tomorrow := today.AddDate(0, 0, 1)
	var from, to time.Time
	switch date {
	case logToday:
		from, to = today, tomorrow
	case logYesterday:
		from, to = today.AddDate(0, 0, -1), today
	case logLast7Days:
		from, to = today.AddDate(0, 0, -6), tomorrow
	case logLast30Days:
		from, to = today.AddDate(0, 0, -29), tomorrow
	default:
		return nil, nil
	}
	f, t := from.Unix(), to.Unix()
	return &f, &t
}

// setGraph keeps a layout and drops a selection the filters no longer show.
func (l *gitLogState) setGraph(graph core.Graph) {
	l.graph = graph
	l.projectedRows = nil
	l.currentRows = make(map[string]bool, len(graph.CurrentBranchHashes))
	for _, h := range graph.CurrentBranchHashes {
		l.currentRows[h] = true
	}
}

func (in *logProjection) keyAt(i int) string {
	if in.keys != nil {
		return in.keys[i]
	}
	return in.commits[i].Hash
}

func (in *logProjection) indexProjectedRows(rows []core.GraphRow, byHash map[string]int) []int32 {
	loaded := len(in.commits)
	for row, entry := range rows {
		if row >= loaded || entry.CommitHash != in.keyAt(row) {
			indices := make([]int32, loaded)
			for i, entry := range rows {
				if index, ok := byHash[entry.CommitHash]; ok && index >= 0 && index < loaded {
					indices[index] = int32(i + 1)
				}
			}
			return indices
		}
	}
	return nil
}

// visibleRow resolves a commit against the published graph. The hash check also
// protects a lookup made while a new history page is being projected.
func (l *gitLogState) visibleRow(hash string) int {
	row, ok := l.byHash[hash]
	if !ok || row < 0 {
		return -1
	}
	if l.projectedRows != nil {
		if row >= len(l.projectedRows) {
			return -1
		}
		row = int(l.projectedRows[row]) - 1
	}
	if row < 0 || row >= len(l.graph.Rows) || l.graph.Rows[row].CommitHash != hash {
		return -1
	}
	return row
}

// selectCommit selects the commit with hash, empty for none, and loads its files and
// details once the selection has rested.
func (a *App) selectCommit(p *project, hash string) {
	l := &p.log
	if p.logReads.retired || hash != "" && l.selected == hash && l.filesState != logFilesFailed {
		return
	}
	l.selected = hash
	l.stopLogSelection()
	gen := l.selGen
	l.files, l.folders, l.detail = nil, nil, nil
	clear(l.closedFolders)
	if hash == "" {
		l.filesState = logFilesIdle
		return
	}
	l.filesState = logFilesLoading
	stop := make(chan struct{})
	l.selStop = stop
	delay := a.delays.files
	kernel, root, key := a.kernel, p.logRoot(), hash
	if l.origins != nil {
		// The commit is read in its own repository, under its hash.
		root, hash = p.logCommitAt(key)
	}
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-stop:
				return nil
			case <-ctx.Done():
				return nil
			}
		}
		ctx, cancel := untilStopped(ctx, stop)
		defer cancel()
		files, err := kernel.GitCommitFiles(ctx, root, hash)
		var folders []logFolder
		if err == nil {
			folders, err = groupLogFiles(ctx, kernel, commitFilePaths(files))
		}
		if ctx.Err() != nil {
			return nil
		}
		detail, detailErr := kernel.GitCommit(ctx, root, hash)
		return func(a *App) {
			if l.selGen != gen {
				return
			}
			if err != nil {
				l.filesState = logFilesFailed
			} else {
				l.files, l.folders, l.filesState = files, folders, logFilesReady
			}
			if detailErr == nil {
				l.detail = &detail
			}
		}
	})
}

func (l *gitLogState) stopLogSelection() {
	l.selGen++
	if l.selStop != nil {
		close(l.selStop)
		l.selStop = nil
	}
}

// untilStopped is ctx, cancelled as well once stop is closed. A newer selection or filter
// closes the stop of the one it replaces, and the Git reads that one started stop with it
// instead of running on, and showing as running in the Git console, for an answer no one
// reads.
func untilStopped(ctx context.Context, stop <-chan struct{}) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-stop:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, cancel
}

// logFolder is one folder of a list of changed files as Core grouped it
// (git.changedFileGroups): its path from the top of the repository, "" for the top itself, and
// the indices into the files of the ones directly in it, in name order.
type logFolder struct {
	dir   string
	files []int
}

// changedFileGrouper is the kernel as the lists of changed files group their files.
type changedFileGrouper interface {
	GitChangedFileGroups(ctx context.Context, paths []string) ([]core.GitChangedFolder, error)
}

// groupLogFiles has Core group the files at paths by folder, folders and files in the project
// tree's natural order. A list is grouped once, when it loads.
func groupLogFiles(ctx context.Context, kernel changedFileGrouper, paths []string) ([]logFolder, error) {
	groups, err := kernel.GitChangedFileGroups(ctx, paths)
	if err != nil {
		return nil, err
	}
	folders := make([]logFolder, len(groups))
	for i, group := range groups {
		folders[i] = logFolder{dir: group.Path, files: group.Files}
	}
	return folders, nil
}

// holds says the folder lists the file at file, pathOf naming the file at an index.
func (f logFolder) holds(file string, pathOf func(int) string) bool {
	return slices.ContainsFunc(f.files, func(i int) bool { return pathOf(i) == file })
}

// commitFilePaths are the paths of a commit's changed files.
func commitFilePaths(files []core.GitCommitFile) []string {
	paths := make([]string, len(files))
	for i, file := range files {
		paths[i] = file.Path
	}
	return paths
}

// locateReference selects the newest loaded commit that the reference with short name
// points at.
func (a *App) locateReference(p *project, short string) {
	if p.logReads.retired {
		return
	}
	for _, row := range p.log.graph.Rows {
		for _, label := range row.Labels {
			if label.Title == short {
				a.selectCommit(p, row.CommitHash)
				p.log.reveal = logRevealSelection
				return
			}
		}
	}
}

// logUsers returns the authors of the loaded commits, sorted.
func (l *gitLogState) logUsers() []string {
	if l.usersFor == len(l.commits) && l.users != nil {
		return l.users
	}
	seen := map[string]bool{}
	l.users = l.users[:0]
	for _, c := range l.commits {
		if c.AuthorName != "" && !seen[c.AuthorName] {
			seen[c.AuthorName] = true
			l.users = append(l.users, c.AuthorName)
		}
	}
	slices.SortFunc(l.users, func(x, y string) int { return strings.Compare(strings.ToLower(x), strings.ToLower(y)) })
	l.usersFor = len(l.commits)
	return l.users
}

func graphCommits(commits []core.GitCommit) []core.GraphCommit {
	out := make([]core.GraphCommit, len(commits))
	for i, c := range commits {
		out[i] = core.GraphCommit{Hash: c.Hash, ParentHashes: c.ParentHashes, Decorations: c.Decorations}
	}
	return out
}

func indexCommits(commits []core.GitCommit) map[string]int {
	index := make(map[string]int, len(commits))
	for i, c := range commits {
		index[c.Hash] = i
	}
	return index
}

func remoteNames(sections [3]logSection) []string {
	names := make([]string, 0, len(sections[1].refs))
	for _, r := range sections[1].refs {
		names = append(names, r.ShortName)
	}
	return names
}
