package workbench

import (
	"context"
	"path"
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
)

// logSection is one section of the reference pane: the local branches, the remote ones
// or the tags, with the folder tree the kernel grouped their names into.
type logSection struct {
	kind  string
	refs  []core.GitReference
	nodes []core.ReferenceTreeNode
}

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
	byHash  map[string]int
	cursor  string
	hasMore bool
	// loadingMore and moreFailed are the state of the next page.
	loadingMore bool
	moreFailed  bool
	// window is the wider history the graph's lanes and colors stay stable against.
	window []core.GraphCommit

	// graph is the kernel's layout of the commits the filters keep, and projGen counts
	// the layouts asked for, so the newest one wins.
	graph       core.Graph
	projGen     int
	projStop    chan struct{}
	currentRows map[string]bool

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
	// reveal asks the next frame to scroll the selected commit into view.
	reveal bool

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

// loadLog loads the log of p from the start: the references, the first page of history
// and its graph, then the wider window the graph is kept stable against.
func (a *App) loadLog(p *project) {
	l := &p.log
	if !l.started {
		*l = newGitLogState()
		l.started = true
	}
	if l.cursor != "" {
		a.closeLogCursor(p, l.cursor)
	}
	l.gen++
	gen := l.gen
	// A projection still running for the old commits must not land on the new ones.
	l.projGen++
	if l.projStop != nil {
		close(l.projStop)
		l.projStop = nil
	}
	l.loading, l.err = true, nil
	l.commits, l.byHash, l.cursor, l.hasMore = nil, nil, "", false
	l.loadingMore, l.moreFailed, l.window = false, false, nil
	l.graph, l.currentRows = core.Graph{}, nil
	l.pathFiles = nil
	// The upstreams the graph paints were read for the repository before this one.
	a.logView.upstream, a.logView.upstreamFor = nil, nil
	a.selectCommit(p, "")
	// The nested repositories' groups in the reference pane are read with the log (nested_refs.go).
	a.loadNestedReferences(p)
	kernel, root, reference := a.kernel, p.logRoot(), l.reference
	expanded := l.expanded
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		refs, sections, current, err := readReferences(ctx, kernel, root)
		var page core.GitHistoryPage
		var graph core.Graph
		if err == nil {
			page, err = kernel.GitHistoryPage(ctx, root, reference, "", logPageSize)
		}
		if err == nil {
			commits := graphCommits(page.Commits)
			graph, err = kernel.GitGraph(ctx, core.GraphRequest{
				Commits: commits, RemoteNames: remoteNames(sections), RepositoryCommits: commits,
				Expanded: expanded, CurrentBranch: current,
			})
		}
		return func(a *App) {
			if l.gen != gen {
				if page.NextCursor != "" {
					a.closeLogCursor(p, page.NextCursor)
				}
				return
			}
			l.loading = false
			if err != nil {
				// Once the walked repository cannot be read, the references shown before are not its own.
				l.err = err
				l.refs, l.sections, l.current = core.GitReferences{}, [3]logSection{}, ""
				return
			}
			l.refs, l.sections, l.current = refs, sections, current
			l.commits = page.Commits
			l.byHash = indexCommits(page.Commits)
			l.cursor, l.hasMore = page.NextCursor, page.HasMore
			l.setGraph(graph)
			if l.filtered() {
				a.reproject(p, 0)
			}
			if page.HasMore {
				a.loadLogWindow(p, gen)
			}
		}
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

// loadLogWindow reads the wider history window and lays the graph out again against it.
func (a *App) loadLogWindow(p *project, gen int) {
	kernel, root, reference := a.kernel, p.logRoot(), p.log.reference
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		page, err := kernel.GitHistoryPage(ctx, root, reference, "", logWindowSize)
		if err == nil && page.NextCursor != "" {
			_, _ = kernel.CloseGitHistoryCursor(ctx, root, page.NextCursor)
		}
		if err != nil {
			return nil
		}
		window := graphCommits(page.Commits)
		return func(a *App) {
			if p.log.gen != gen {
				return
			}
			p.log.window = window
			a.reproject(p, 0)
		}
	})
}

// loadMoreLog reads the next page of history when there is one and none is on its way.
func (a *App) loadMoreLog(p *project) {
	l := &p.log
	if l.loading || !l.hasMore || l.loadingMore || l.moreFailed || l.cursor == "" {
		return
	}
	l.loadingMore = true
	gen := l.gen
	kernel, root, reference, cursor := a.kernel, p.logRoot(), l.reference, l.cursor
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		page, err := kernel.GitHistoryPage(ctx, root, reference, cursor, logPageSize)
		return func(a *App) {
			if l.gen != gen {
				return
			}
			l.loadingMore = false
			if err != nil {
				l.moreFailed = true
				return
			}
			l.commits = slices.Concat(l.commits, page.Commits)
			l.byHash = indexCommits(l.commits)
			l.cursor, l.hasMore = page.NextCursor, page.HasMore
			a.reproject(p, 0)
		}
	})
}

// closeLogCursor releases a history walk the log no longer continues.
func (a *App) closeLogCursor(p *project, cursor string) {
	kernel, root := a.kernel, p.logRoot()
	a.background(p, gitTimeout, func(ctx context.Context) func(*App) {
		_, _ = kernel.CloseGitHistoryCursor(ctx, root, cursor)
		return nil
	})
}

// setLogReference makes the log walk one reference, or every reference when full is
// empty, and loads it again.
func (a *App) setLogReference(p *project, full, short string) {
	l := &p.log
	if l.reference == full {
		return
	}
	l.reference, l.referenceLabel = full, short
	a.loadLog(p)
}

// logProjection is what one graph layout is made from, copied so the background work
// reads nothing the window thread changes.
type logProjection struct {
	commits          []core.GitCommit
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
	l := &p.log
	l.projGen++
	gen := l.projGen
	if l.projStop != nil {
		close(l.projStop)
	}
	stop := make(chan struct{})
	l.projStop = stop
	in := logProjection{
		commits:  l.commits,
		window:   l.window,
		remotes:  remoteNames(l.sections),
		current:  l.current,
		expanded: l.expanded,
		text:     strings.ToLower(l.text),
		user:     l.user,
		path:     strings.ToLower(l.path),
	}
	if len(in.window) < len(in.commits) {
		in.window = nil
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
				return nil
			}
		}
		ctx, cancel := untilStopped(ctx, stop)
		defer cancel()
		graph, files, err := in.run(ctx, kernel, root, dated)
		return func(a *App) {
			if l.projGen != gen {
				return
			}
			if files != nil {
				l.pathFiles = files
			}
			if err != nil {
				a.notifyError(a.text.Git.Failed(err.Error()))
				return
			}
			l.setGraph(graph)
		}
	})
}

// run filters the commits and asks the kernel for the layout of what is left. It
// returns the files the path filter read, so the next run does not read them again.
func (in logProjection) run(ctx context.Context, kernel Kernel, root string, dated bool) (core.Graph, map[string][]core.GitCommitFile, error) {
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
			for i, c := range in.commits {
				if !keep[i] {
					continue
				}
				files, ok := in.pathFiles[c.Hash]
				if !ok {
					var err error
					if files, err = kernel.GitCommitFiles(ctx, root, c.Hash); err != nil {
						return core.Graph{}, in.pathFiles, err
					}
					in.pathFiles[c.Hash] = files
				}
				keep[i] = slices.ContainsFunc(files, func(f core.GitCommitFile) bool {
					return strings.Contains(strings.ToLower(f.Path), in.path)
				})
			}
		}
		visible = make([]string, 0, len(in.commits))
		for i, c := range in.commits {
			if keep[i] {
				visible = append(visible, c.Hash)
			}
		}
	}
	commits := graphCommits(in.commits)
	window := in.window
	if window == nil {
		window = commits
	}
	graph, err := kernel.GitGraph(ctx, core.GraphRequest{
		Commits: commits, RemoteNames: in.remotes, RepositoryCommits: window,
		VisibleHashes: visible, Expanded: in.expanded, CurrentBranch: in.current,
	})
	return graph, in.pathFiles, err
}

// keepDates clears keep for the commits the kernel finds outside the date bounds.
func (in logProjection) keepDates(ctx context.Context, kernel Kernel, keep []bool) error {
	for start := 0; start < len(in.commits); start += logDateChunk {
		end := min(start+logDateChunk, len(in.commits))
		entries := make([]core.HistoryDateEntry, 0, end-start)
		for _, c := range in.commits[start:end] {
			entries = append(entries, core.HistoryDateEntry{
				ID: c.Hash, Date: c.Date, UTCOffsetMinutes: c.DateUTCOffsetMinutes, FallbackUnixSeconds: c.DateUnixSeconds,
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
			keep[i] = keep[i] && match[in.commits[i].Hash]
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
	l.currentRows = make(map[string]bool, len(graph.CurrentBranchHashes))
	for _, h := range graph.CurrentBranchHashes {
		l.currentRows[h] = true
	}
}

// selectCommit selects the commit with hash, empty for none, and loads its files and
// details once the selection has rested.
func (a *App) selectCommit(p *project, hash string) {
	l := &p.log
	if hash != "" && l.selected == hash && l.filesState != logFilesFailed {
		return
	}
	l.selected = hash
	l.selGen++
	gen := l.selGen
	if l.selStop != nil {
		close(l.selStop)
		l.selStop = nil
	}
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
	kernel, root := a.kernel, p.logRoot()
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
				l.files, l.folders, l.filesState = files, groupLogFiles(files), logFilesReady
			}
			if detailErr == nil {
				l.detail = &detail
			}
		}
	})
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

// logFolder is one folder of the selected commit's changed files: its path from the top of
// the repository, "." for the top itself, and the indices into the files of the ones in it, in
// the order Git listed them.
type logFolder struct {
	dir   string
	files []int
}

// groupLogFiles groups files by their folder, the folders sorted by path.
func groupLogFiles(files []core.GitCommitFile) []logFolder {
	at := map[string]int{}
	var folders []logFolder
	for i, file := range files {
		dir := path.Dir(file.Path)
		j, ok := at[dir]
		if !ok {
			j = len(folders)
			at[dir] = j
			folders = append(folders, logFolder{dir: dir})
		}
		folders[j].files = append(folders[j].files, i)
	}
	slices.SortFunc(folders, func(a, b logFolder) int { return strings.Compare(a.dir, b.dir) })
	return folders
}

// locateReference selects the newest loaded commit that the reference with short name
// points at.
func (a *App) locateReference(p *project, short string) {
	for _, row := range p.log.graph.Rows {
		for _, label := range row.Labels {
			if label.Title == short {
				a.selectCommit(p, row.CommitHash)
				p.log.reveal = true
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
