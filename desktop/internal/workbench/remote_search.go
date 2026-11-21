package workbench

// This file keeps the search index of a remote workspace current. Find in Files, Search
// Everywhere and Replace All run with the workspace's remote binding, so Core builds the index
// from the host's folder and answers with paths relative to it, which open in the remote editor.
// The local watch cannot observe the host, so the host watch (remote_watch.go) feeds the index in
// its place: the changed paths it reports update the index before the next query, and its start,
// and a batch it lost, build the index again. While it does not watch all of the folder, from a
// lost session until it starts again with the next one, or after the host ran out of watches,
// every query builds the index from the host again.
//
// The host watch leaves out the folders the plugins hide. A search that includes generated files
// reads some of them, so it builds the index again for every query; Search Everywhere's generated
// file names are read again each time the popup opens. Language servers do not run for a remote
// workspace yet, so Search Everywhere's symbols are only those Core finds in the host's files.

// remoteWatching reports whether p is a remote workspace whose host watch watches all of its
// folder, so the host's changes reach the search index (remoteSearchChanged).
func (p *project) remoteWatching() bool {
	r := p.remote
	return r != nil && r.watch != nil && r.watch.watching && !r.watch.partial
}

// remoteWatchMisses reports whether a search of p that includes generated files (generated)
// reads folders its host watch leaves out, whose changes never reach the index.
func (p *project) remoteWatchMisses(generated bool) bool {
	return p.remote != nil && generated
}

// remoteSearchChanged hands what p's host watch saw to Find in Files and Search Everywhere:
// names, changed paths relative to the folder, update the index before the next query, and
// resync, for a watch that started or lost changes, builds it again. The queries shown run again.
func (a *App) remoteSearchChanged(p *project, names []string, resync bool) {
	available := p.remoteWatching()
	if s := &p.search; s.watch != nil && s.watchReady {
		s.watchAvailable = available
		if resync {
			s.pending, s.fullResync = nil, true
		} else {
			a.queueSearchChanges(&s.pending, &s.fullResync, names)
		}
		a.projectSearchOutdated(p)
		a.runProjectSearch(p)
	}
	if s := &p.everywhere; s.watchAttached && s.watchReady && a.everywhereView.open {
		s.watchAvailable = available
		if resync {
			s.pending, s.fullResync = nil, true
		} else {
			a.queueSearchChanges(&s.pending, &s.fullResync, names)
		}
		a.everywhereOutdated(p)
		a.runEverywhere(p, false)
	}
}

// remoteSearchUnwatched tells p's searches that the host watch stopped, or ran out of watches:
// changes no longer reach the index, so every query builds it again until a watch starts and
// resyncs. The results shown stay; a session lost would fail the query run now, and the next
// session's watch runs it again.
func (a *App) remoteSearchUnwatched(p *project) {
	p.search.watchAvailable, p.search.pending, p.search.fullResync = false, nil, true
	p.everywhere.watchAvailable, p.everywhere.pending, p.everywhere.fullResync = false, nil, true
}
