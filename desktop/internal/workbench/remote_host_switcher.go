package workbench

// openRemoteHostMenu reads the real saved connections and discovers local WSL distributions and
// containers using the connection window's existing, bounded loaders. No modal opens yet.
func (a *App) openRemoteHostMenu() {
	p := a.project
	if p == nil || p.remote == nil || a.remote.open && !a.remote.hostsOnly {
		return
	}
	a.closeRemoteHostMenu()
	a.title.projectOpen, a.title.gearOpen, a.title.runConfigOpen = false, false, false
	a.closeBranches()
	r := &a.remote
	r.generation++
	*r = remoteState{open: true, hostsOnly: true, generation: r.generation, probed: r.probed}
	r.form.clear()
	p.remote.menuOpen = true
	a.performed("remote.hosts.open", surfaceMenu)
	a.loadRemote(remoteLoadSelectFirst, "")
	a.loadRemoteWSL()
	a.loadRemoteContainers()
}

// closeRemoteHostMenu releases its presentation state and invalidates outstanding reads. Once a
// choice promoted it to the connection window, that window owns the state until it closes.
func (a *App) closeRemoteHostMenu() {
	if p := a.project; p != nil && p.remote != nil {
		p.remote.menuOpen = false
	}
	if a.remote.hostsOnly {
		a.closeRemote()
		a.remote.hostsOnly = false
	}
}

// chooseRemoteHost opens the existing connection flow with no preset folder. Connecting must
// succeed before the folder chooser appears; cancelling leaves the original workspace intact.
func (a *App) chooseRemoteHost(target remoteReopen) {
	a.openRemote(surfaceMenu)
	r := &a.remote
	if target.host.container != nil && !target.host.hosted() {
		for _, container := range r.containers.list {
			if container.engine == target.host.container.Engine && container.Name == target.host.container.Container {
				r.selectRemoteContainer(container)
				r.containers.user.SetText(target.host.container.User)
				break
			}
		}
	}
	if r.loaded {
		a.connectRemoteReopen(&target)
	} else {
		r.reopen = &target
	}
}

// switchRemoteHostRow selects the same overview the connection window would show, then starts
// its Connect action. Keeping that selection makes the folder chooser highlight its own host.
func (a *App) switchRemoteHostRow(row remoteListRow) {
	a.openRemote(surfaceMenu)
	r := &a.remote
	switch {
	case row.entry != nil:
		r.selectEntry(row.entry.ID)
	case row.wsl != "":
		r.selectRemoteWSL(row.wsl)
	case row.container != nil:
		r.selectRemoteContainer(*row.container)
	}
	a.connectRemote("")
}
