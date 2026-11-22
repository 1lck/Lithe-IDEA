package workbench

import (
	"context"
	"path"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/vivaui/viva/ui"
)

// Open File on Host, in the menu of a remote workspace's connection, opens a file of the host by
// its path, as Zed's path prompt does in a remote project (#2231, R0, §7.3). The field takes an
// absolute host path or one under ~, the account's home directory. Below it are the entries of
// the folder the text names up to its last "/" whose names start with what follows, ignoring
// case, folders first; hidden entries show once that rest starts with ".". Choosing a folder
// enters it and choosing a file opens it. Enter with no entry shown opens the path as typed, and
// the editor says why when it cannot.
//
// A file in the workspace's folder opens as every file of the project does. A file outside it
// opens read-only (S25): the user opened and trusted the folder, not the rest of the host, so
// the editor never writes there. Its document lives below the placeholder Core maps host paths
// outside the workspace to (remoteplaceholder.HostSuffix); the host watch covers only the
// folder, so a change to such a file is found when the connection opens again and before its
// tab closes. Host paths, names and what the user typed are never logged.

// remoteHostFilesQueryID names the path field, so the popup can give it the keyboard.
var remoteHostFilesQueryID = tree.ID(shellPage, "remote-host-files-query")

// remoteHostEntry is an entry of the folder the popup lists.
type remoteHostEntry struct {
	name   string
	folder bool
}

// remoteHostFiles is the popup's state (remoteProject.hostFiles).
type remoteHostFiles struct {
	open, focus bool
	query       ui.Field
	list        ui.ListState
	// head is the text up to its last "/" that dir was listed for over session, dir the host
	// folder it names ("" when the text names none), and entries its folders, then its other
	// entries. A new session lists the folder again.
	head    string
	session string
	dir     string
	entries []remoteHostEntry
	skipped uint32
	loading bool
	// listing counts the listings, so that only the latest applies.
	listing uint64
	// readErr is why dir could not be listed, or that the text names no host folder.
	readErr string
	// rowsFor is the text rows were chosen for; rows are the indexes of the entries shown, and
	// selected the row Enter chooses.
	rowsFor    string
	rows       []int
	selected   int
	scrolledTo int
}

// openRemoteHostFiles shows the popup over p's window with the home directory typed, or the
// host's root when the host did not report one.
func (a *App) openRemoteHostFiles(p *project, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed {
		return
	}
	a.performed("remote.workspace.openHostFile", surface)
	f := &r.hostFiles
	start := "/"
	if path.IsAbs(r.home) {
		start = "~/"
	}
	f.open, f.focus = true, true
	// The first paint lists the folder the text names.
	f.head = "\x00"
	f.query.SetText(start)
}

// closeRemoteHostFiles hides the popup; a listing still running is dropped.
func (p *project) closeRemoteHostFiles() {
	if p.remote == nil {
		return
	}
	f := &p.remote.hostFiles
	f.open, f.focus, f.loading = false, false, false
	f.listing++
	f.entries, f.rows, f.head, f.session, f.dir, f.rowsFor, f.readErr, f.skipped = nil, nil, "", "", "", "", "", 0
	f.list = ui.ListState{}
	f.query.SetText("")
}

// splitRemoteHostQuery cuts text at its last "/": head names the folder and prefix starts the
// names shown. ok is false for text without a "/".
func splitRemoteHostQuery(text string) (head, prefix string, ok bool) {
	at := strings.LastIndexByte(text, '/')
	if at < 0 {
		return "", "", false
	}
	return text[:at+1], text[at+1:], true
}

// syncRemoteHostFiles lists the folder the text names when it changed, and chooses the rows for
// the text. It runs on each paint of the popup.
func (a *App) syncRemoteHostFiles(p *project) {
	r := p.remote
	f := &r.hostFiles
	text := f.query.Text()
	head, _, ok := splitRemoteHostQuery(strings.TrimLeft(text, " "))
	if !ok {
		head = ""
	}
	if session := r.binding.SessionID(); head != f.head || session != f.session {
		f.head, f.session = head, session
		f.entries, f.skipped, f.readErr, f.dir, f.loading, f.rowsFor = nil, 0, "", "", false, "\x00"
		f.listing++
		dir, valid := "", false
		if head != "" {
			dir, valid = remoteFolderPath(head, r.home)
		}
		if !valid {
			f.readErr = i18n.Shared(a.language(), "desktop.remote.hostFile.pathHint")
		} else {
			a.listRemoteHostFolder(p, dir)
		}
	}
	if f.rowsFor != text {
		f.rowsFor = text
		_, prefix, _ := splitRemoteHostQuery(text)
		f.rows = remoteHostRows(f.entries, prefix)
		f.selected, f.scrolledTo = 0, -1
	}
}

// listRemoteHostFolder lists dir, an absolute clean host path, over the workspace's session.
func (a *App) listRemoteHostFolder(p *project, dir string) {
	r := p.remote
	f := &r.hostFiles
	f.dir = dir
	session := f.session
	if session == "" {
		f.readErr = i18n.Shared(a.language(), "desktop.remote.document.disconnected")
		return
	}
	f.loading = true
	listing, kernel, lost := f.listing, a.kernel, a.remoteSessionLost(p)
	a.background(p, remoteReadDirTimeout, func(ctx context.Context) func(*App) {
		directory, err := kernel.RemoteReadDir(ctx, session, dir)
		return func(a *App) {
			if r.closed || !f.open || f.listing != listing {
				// log-exempt: 用户取消：弹窗已关闭或路径已改，不再应用列出结果。
				return
			}
			f.loading, f.rowsFor = false, "\x00"
			if err != nil {
				a.operationFailed("remote_read_dir", remoteLogError(err))
				if remoteConnectionClosed(err) {
					lost(session)
					f.readErr = i18n.Shared(a.language(), "desktop.remote.document.disconnected")
					return
				}
				f.readErr = remoteReadDirFailureText(a.language(), err)
				return
			}
			f.entries = nil
			for _, name := range remoteEntryNames(directory, true) {
				f.entries = append(f.entries, remoteHostEntry{name: name, folder: true})
			}
			for _, name := range remoteEntryNames(directory, false) {
				f.entries = append(f.entries, remoteHostEntry{name: name})
			}
			f.skipped = directory.SkippedNonUTF8
		}
	})
}

// remoteHostRows are the indexes of the entries whose names start with prefix, ignoring case.
// A hidden entry shows only when prefix starts with ".".
func remoteHostRows(entries []remoteHostEntry, prefix string) []int {
	lower, hidden := strings.ToLower(prefix), strings.HasPrefix(prefix, ".")
	rows := make([]int, 0, len(entries))
	for i, entry := range entries {
		if strings.HasPrefix(entry.name, ".") && !hidden {
			continue
		}
		if strings.HasPrefix(strings.ToLower(entry.name), lower) {
			rows = append(rows, i)
		}
	}
	return rows
}

// chooseRemoteHostRow enters the folder of row, or opens its file.
func (a *App) chooseRemoteHostRow(p *project, row int, surface actionSurface) {
	f := &p.remote.hostFiles
	if row < 0 || row >= len(f.rows) {
		return
	}
	entry := f.entries[f.rows[row]]
	if entry.folder {
		a.performed("remote.workspace.openHostFile.enter", surface)
		f.query.SetText(f.head + entry.name + "/")
		f.focus = true
		return
	}
	a.openRemoteHostFile(p, path.Join(f.dir, entry.name), surface)
}

// completeRemoteHostRow puts the name of row after the folder in the field, a folder with its
// "/", so the next paint lists it.
func (p *project) completeRemoteHostRow(row int) {
	f := &p.remote.hostFiles
	if row < 0 || row >= len(f.rows) {
		return
	}
	entry := f.entries[f.rows[row]]
	text := f.head + entry.name
	if entry.folder {
		text += "/"
	}
	f.query.SetText(text)
}

// submitRemoteHostFiles is Enter: the selected row, or the path as typed when no row shows.
func (a *App) submitRemoteHostFiles(p *project, surface actionSurface) {
	f := &p.remote.hostFiles
	if f.selected >= 0 && f.selected < len(f.rows) {
		a.chooseRemoteHostRow(p, f.selected, surface)
		return
	}
	text := strings.TrimLeft(f.query.Text(), " ")
	if text == "" || strings.HasSuffix(text, "/") {
		return
	}
	host, ok := remoteFolderPath(text, p.remote.home)
	if !ok {
		a.operationRejected("remote_open_host_file", "path_not_absolute")
		f.readErr = i18n.Shared(a.language(), "desktop.remote.hostFile.pathHint")
		return
	}
	a.openRemoteHostFile(p, host, surface)
}

// openRemoteHostFile closes the popup and opens host, an absolute clean host path, in the editor:
// read-only when it lies outside the workspace's folder.
func (a *App) openRemoteHostFile(p *project, host string, surface actionSurface) {
	r := p.remote
	local, ok := remoteplaceholder.LocalPath(p.root, r.binding.RemoteRoot(), host)
	if !ok {
		// A name holding "\" cannot be named on Windows.
		a.operationRejected("remote_open_host_file", "path_unrepresentable")
		r.hostFiles.readErr = i18n.Shared(a.language(), "desktop.remote.hostFile.unrepresentable")
		return
	}
	a.performed("remote.workspace.openHostFile.open", surface)
	p.closeRemoteHostFiles()
	a.openFile(p, local)
}

// remoteOutsideDocument says whether path names a host file outside p's remote folder: one the
// editor shows read-only.
func (p *project) remoteOutsideDocument(path string) bool {
	return p.remote != nil && remoteplaceholder.Outside(p.root, path)
}
