package workbench

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// The Remote Development window keeps the SSH connections the user saved (remoteconn) and tests
// one: the saved list on the left, under the groups Core sections it into, and on the right the
// selected connection's overview, or its form once Edit was clicked (a new connection always shows
// its form). It belongs to the window, not to a project, so it opens on the welcome screen as over
// a project.
//
// Nothing secret passes through it: a password or a key's passphrase is asked by OpenSSH through
// Core's AskPass helper while a test runs, answered in the authentication dialog and never kept;
// a private key is kept as its path, and its contents are never read (design S12, S15). Neither
// the host, the user nor OpenSSH's output is logged: the log names only the operation and Core's
// fixed status or error.

const (
	// remoteReadTimeout bounds reading or editing the saved list, a local file of at most Core's
	// size limit.
	remoteReadTimeout = 10 * time.Second
	// remoteProbeTimeout bounds a test, which may wait for the user to answer OpenSSH's questions
	// for up to Core's prompt deadline each.
	remoteProbeTimeout = 6 * time.Minute
)

// remoteState is the window's state.
type remoteState struct {
	open bool
	// hostsOnly presents the same source and discovered hosts in the title bar's dropdown,
	// without showing the connection window until a host or action is chosen.
	hostsOnly bool
	// hostReads cancels discovery started by the dropdown when it closes, rather than leaving
	// WSL/container processes running until their deadlines. A promoted window keeps ownership.
	hostReads []context.CancelFunc
	// generation counts the openings and closings, so that a result arriving after the window
	// closed is dropped.
	generation uint64
	loading    bool
	loaded     bool
	source     remoteconn.Source
	// rows are the list's rows for source, and groups the groups it names in their order; both
	// change only with source (setSource).
	rows   []remoteListRow
	groups []string
	// readErr is why the list could not be read; nothing can be saved until it can.
	readErr string
	list    ui.ListState
	// selected is the id of the saved connection the form edits, "" for a new one.
	selected string
	// editing says whether the selected connection shows its form rather than its overview.
	editing bool
	// previous is the connection selected before New, shown again when New is cancelled.
	previous string
	form     remoteForm
	saving   bool
	// confirmDelete is the footer's question whether to delete the selected connection.
	confirmDelete bool
	// probe is the running test, nil when none runs; result is the last one's outcome.
	probe  *remoteProbe
	result *remoteProbeOutcome
	// connect is the running connection to the selected host, nil when none runs; its failure is
	// shown as result. browser chooses the host folder to open over the session it opened.
	connect *remoteProbe
	browser *remoteBrowser
	// reopen is the host folder the window connects to and opens once the saved list is read, nil
	// when it opened for the user to choose (remote_worktree.go).
	reopen *remoteReopen
	// probed is what the last test of each connection found, by the connection as Core stores
	// it, so that a saved connection's overview shows its host again after the form was saved
	// or the window reopened. It lives in memory while the app runs, outlives the window and
	// holds no secret; an edited connection is a new key, so a stale result is never shown for
	// it.
	probed map[core.SSHConnection]*remoteProbeOutcome
	// err is the last failure that names no field of the form; fieldErr names one.
	err      string
	fieldErr remoteFieldRefusal

	// query filters the list through Core; found is Core's sections for it, nil while the query
	// is empty and the list shows the source's. searching counts the searches, so that an older
	// answer arriving late is dropped.
	query     ui.Field
	found     []core.RemoteConnectionSection
	searching uint64
	// collapsed are the groups whose connections the list hides, by heading ("" for none).
	collapsed map[string]bool
	// importMenu and moreMenu are open while the list's import menu and the overview's menu are.
	importMenu, moreMenu bool
	// quick is the empty page's user@host:port field, and quickErr why Core refused it.
	quick    ui.Field
	quickErr string
	// hop is the form's field that adds a jump host.
	hop ui.Field
	// effective is what OpenSSH resolves for each saved connection, by the connection as Core
	// stores it. It is read once per opening of the window, lives with it and holds no secret.
	effective map[core.SSHConnection]*remoteEffective
	// steps is the connection in progress with its stages, nil when none runs.
	steps *remoteSteps
	// trust asks whether the chosen folder's code may run, nil when nothing is asked.
	trust *remoteTrustPrompt
	// importer is the import page, nil when it is not shown; imports are the counts the empty
	// page and the import menu name.
	importer *remoteImporter
	// wsl is this computer's WSL distributions, read once per opening (remote_wsl.go).
	wsl remoteWSL
	// containers is this computer's running containers, read once per opening
	// (remote_container.go).
	containers remoteContainers
	// devcontainer is the page that opens a folder of this computer in its dev container, nil
	// when it is not shown (remote_devcontainer.go).
	devcontainer *remoteDevcontainer
	// log folds OpenSSH's words under a failed test or connection.
	log     ui.CollapsibleState
	imports remoteImportCounts
}

// remoteForm is what the user types for one connection.
type remoteForm struct {
	name, host, port, user, identityFile, proxyJump, timeout, keepAlive ui.Field
	// color marks the connection in the list, "" for none.
	color core.RemoteConnectionColor
	// group is the group chosen: "" for none, one of the list's groups, or remoteNewGroup for
	// the one typed in newGroup.
	group          string
	newGroup       ui.Field
	authentication string
	advanced       ui.CollapsibleState
}

// remoteNewGroup is the group choice that names a new group in the field beside it. No group can
// have this name, since Core refuses control characters in one.
const remoteNewGroup = "\x00new"

// remoteListRow is a row of the list: a section's heading, a saved connection, a WSL
// distribution or a running container.
type remoteListRow struct {
	// heading is set on a section's heading, which names group ("" for the connections without
	// one, remoteWSLHeading for the WSL distributions, remoteContainerHeading for the containers)
	// and the number of rows in the section.
	heading bool
	group   string
	count   int
	entry   *core.SavedRemoteConnection
	// wsl is the distribution of a WSL row.
	wsl string
	// container is the container of a container's row.
	container *remoteListedContainer
}

// remoteProbe is a test in progress, cancelled by Stop or by closing the window.
type remoteProbe struct {
	cancel context.CancelFunc
}

// remoteProbeOutcome is what a test found: Core's result, or the error that kept it from running.
type remoteProbeOutcome struct {
	result core.RemoteProbeResult
	// at is when the test ended, for the overview's "tested 5 minutes ago".
	at  time.Time
	err error
	// wsl is set when the host was a WSL distribution, a container in one included, and engine
	// is the engine of a container host; hosted is set when that container was on an SSH host or
	// a WSL distribution. The failures of each read differently.
	wsl    bool
	engine string
	hosted bool
}

// remoteFieldRefusal is the field of the form Core (or the form's own number check) refused, and
// why: one of Core's reasons (required, invalid, tooLong, duplicate, full, unknown).
type remoteFieldRefusal struct {
	field, reason string
}

// remoteAuthentications are the ways a connection may authenticate, in the order the form offers.
var remoteAuthentications = []string{
	core.RemoteAuthenticationAuto,
	core.RemoteAuthenticationAgent,
	core.RemoteAuthenticationPrivateKey,
	core.RemoteAuthenticationPassword,
}

// openRemote opens the window and reads the saved list.
func (a *App) openRemote(surface actionSurface) {
	r := &a.remote
	if r.open {
		if r.hostsOnly {
			r.hostsOnly = false
			a.performed("remote.connections.open", surface)
			if r.loaded && r.readErr == "" {
				a.loadRemoteImportCounts()
			}
		}
		return
	}
	r.generation++
	*r = remoteState{open: true, generation: r.generation, probed: r.probed}
	r.form.clear()
	a.performed("remote.connections.open", surface)
	a.loadRemote(remoteLoadSelectFirst, "")
	a.loadRemoteWSL()
	a.loadRemoteContainers()
}

// closeRemote closes the window, stopping a running test or connection and ending the session a
// folder was being chosen over. What was typed and not saved is dropped.
func (a *App) closeRemote() {
	r := &a.remote
	if r.containers.cancel != nil {
		r.containers.cancel()
	}
	for _, cancel := range r.hostReads {
		cancel()
	}
	r.hostReads = nil
	r.stopProbe()
	r.stopConnect()
	a.leaveRemoteBrowser()
	a.leaveRemoteTrust()
	a.leaveRemoteDevcontainer()
	r.generation++
	r.open, r.saving, r.loading, r.reopen = false, false, false, nil
	r.form = remoteForm{}
}

// remoteLoad says which connection the form shows once the list is read.
type remoteLoad int

const (
	// remoteLoadSelectFirst selects the first saved connection, or a new one without any.
	remoteLoadSelectFirst remoteLoad = iota
	// remoteLoadSelect selects the connection the load names and fills the form from it.
	remoteLoadSelect
	// remoteLoadKeepForm leaves the form as typed, after a save found the list changed on disk.
	remoteLoadKeepForm
)

// loadRemote reads the saved list in the background and then applies how.
func (a *App) loadRemote(how remoteLoad, id string) {
	r := &a.remote
	r.loading = true
	generation, kernel, root := r.generation, a.kernel, a.globalToolchainRoot()
	cancel := a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		source, err := remoteconn.Read(ctx, kernel, root)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口关闭后不再应用读取结果。
				return
			}
			r.loading, r.loaded, r.readErr = false, true, ""
			r.setSource(source)
			if err != nil {
				a.operationFailed("remote_connections_read", documentLogError(err))
				r.readErr = remoteReadFailure(a.language(), source, err)
			} else if !r.hostsOnly {
				// The counts leave out the hosts already saved, so they follow every reread.
				a.loadRemoteImportCounts()
			}
			switch how {
			case remoteLoadKeepForm:
				r.syncListSelection()
			case remoteLoadSelect:
				if r.entry(id) != nil {
					r.selectEntry(id)
					return
				}
				r.selectFirst()
			default:
				if reopen := r.reopen; reopen != nil {
					r.reopen = nil
					a.connectRemoteReopen(reopen)
					return
				}
				// Discovery can finish before this read. Keep the host the user already chose,
				// including its running connection, rather than selecting the first SSH entry.
				if r.wsl.selected != "" || r.containers.selected != nil {
					r.syncListSelection()
					return
				}
				r.selectFirst()
			}
		}
	})
	if r.hostsOnly {
		r.hostReads = append(r.hostReads, cancel)
	}
}

// remoteReadFailure is the window's text for a list that could not be read.
func remoteReadFailure(language i18n.Language, source remoteconn.Source, err error) string {
	switch {
	case errors.Is(err, remoteconn.ErrUnavailable):
		return i18n.Shared(language, "desktop.remote.unavailable")
	case errors.Is(err, remoteconn.ErrDamaged):
		return i18n.SharedFormat(language, "desktop.remote.damaged", map[string]string{"path": source.Path()})
	}
	return i18n.SharedFormat(language, "desktop.remote.readFailed", map[string]string{"reason": err.Error()})
}

// setSource takes the list as read, with its rows: the connections under the sections Core lists
// them in, each section headed by its group once any connection has one.
func (r *remoteState) setSource(source remoteconn.Source) {
	r.source, r.rows, r.groups = source, nil, nil
	// A search lists what Core found in the source it searched, so a new one ends it.
	r.found = nil
	r.searching++
	r.query.SetText("")
	for _, section := range source.Sections {
		if section.Group != nil {
			r.groups = append(r.groups, *section.Group)
		}
	}
	r.buildRows()
	// Only a saved connection shows a past test, so the others' results go, which bounds probed
	// by the list.
	for connection := range r.probed {
		if !slices.ContainsFunc(source.Connections, func(entry core.SavedRemoteConnection) bool {
			return remoteStored(entry.Connection) == connection
		}) {
			delete(r.probed, connection)
		}
	}
}

// entry is the saved connection id, nil when the list has none of that id.
func (r *remoteState) entry(id string) *core.SavedRemoteConnection {
	if id == "" {
		return nil
	}
	for index := range r.source.Connections {
		if r.source.Connections[index].ID == id {
			return &r.source.Connections[index]
		}
	}
	return nil
}

// selectFirst selects the first connection the list shows, else the first saved one, and shows
// the empty page when nothing is saved.
func (r *remoteState) selectFirst() {
	for _, row := range r.rows {
		if row.entry != nil {
			r.selectEntry(row.entry.ID)
			return
		}
	}
	if len(r.source.Connections) > 0 {
		r.selectEntry(r.source.Connections[0].ID)
		return
	}
	r.resetEditing()
	r.selected, r.editing, r.quickErr = "", false, ""
	r.form.clear()
	r.syncListSelection()
}

// selectEntry shows the overview of the saved connection id, with the form filled from it,
// dropping what was typed, the last test and its errors; a test still running for the previous
// form is stopped.
func (r *remoteState) selectEntry(id string) {
	entry := r.entry(id)
	if entry == nil {
		r.selectNew()
		return
	}
	r.resetEditing()
	r.selected, r.editing = id, false
	r.form.fill(*entry)
	r.syncListSelection()
}

// selectNew starts a new connection with an empty form.
func (r *remoteState) selectNew() {
	r.resetEditing()
	r.selected, r.editing = "", true
	r.form.clear()
	r.syncListSelection()
}

// editingForm says whether the window shows the form: for a new connection, or for a saved one
// once Edit was clicked.
func (r *remoteState) editingForm() bool {
	return r.editing
}

// newRemote starts a new connection; Cancel goes back to the one selected before.
func (a *App) newRemote() {
	r := &a.remote
	if !a.leaveRemoteFlows() {
		return
	}
	a.performed("remote.connection.new", surfaceButton)
	if r.selected != "" {
		r.previous = r.selected
	}
	r.selectNew()
}

// editSelectedRemote shows the form of the selected connection instead of its overview.
func (a *App) editSelectedRemote() {
	r := &a.remote
	if r.editingForm() {
		return
	}
	a.performed("remote.connection.edit", surfaceButton)
	r.editing, r.confirmDelete = true, false
}

// cancelRemoteEdit drops what was typed: a saved connection shows its overview again, and a new
// one gives way to the connection selected before it.
func (a *App) cancelRemoteEdit() {
	r := &a.remote
	a.performed("remote.connection.edit.cancel", surfaceButton)
	switch {
	case r.entry(r.selected) != nil:
		r.selectEntry(r.selected)
	case r.entry(r.previous) != nil:
		r.selectEntry(r.previous)
	default:
		r.selectFirst()
	}
}

// probedOutcome is what the last test of connection found while the app runs, nil when it was
// not tested.
func (r *remoteState) probedOutcome(connection core.SSHConnection) *remoteProbeOutcome {
	return r.probed[remoteStored(connection)]
}

// resetEditing drops the last test or connection, its errors, the delete question and the WSL
// distribution or container shown.
func (r *remoteState) resetEditing() {
	r.stopProbe()
	r.stopConnect()
	r.result, r.err, r.fieldErr, r.confirmDelete = nil, "", remoteFieldRefusal{}, false
	r.wsl.selected = ""
	r.containers.selected = nil
}

// syncListSelection selects the row of the edited connection, or of the WSL distribution or
// container shown, none for a new connection.
func (r *remoteState) syncListSelection() {
	at := r.rowOf(r.selected)
	switch {
	case r.wsl.selected != "":
		at = r.wslRow(r.wsl.selected)
	case r.containers.selected != nil:
		at = r.containerRow(r.containers.selected.key())
	}
	if r.list.Selected() != at {
		r.list.Select(at)
		if at >= 0 {
			r.list.ScrollIntoView(at)
		}
	}
}

// rowOf is the list row of the saved connection id, -1 when the list has none.
func (r *remoteState) rowOf(id string) int {
	if id == "" {
		return -1
	}
	return slices.IndexFunc(r.rows, func(row remoteListRow) bool { return row.entry != nil && row.entry.ID == id })
}

// stopProbe cancels a running test; its result is dropped when it returns.
func (r *remoteState) stopProbe() {
	if r.probe != nil {
		r.probe.cancel()
		r.probe = nil
	}
}

// clear empties the form for a new connection, which authenticates the way OpenSSH's own
// configuration says.
func (f *remoteForm) clear() {
	for _, field := range f.fields() {
		field.SetText("")
	}
	f.authentication = core.RemoteAuthenticationAuto
	f.color, f.group = "", ""
	f.advanced.Open = false
}

// fill shows a saved connection in the form; the advanced options are shown open when one is set.
func (f *remoteForm) fill(entry core.SavedRemoteConnection) {
	connection := entry.Connection
	f.name.SetText(entry.Name)
	f.color, f.group = entry.Color, entry.Group
	f.newGroup.SetText("")
	f.host.SetText(connection.Host)
	f.port.SetText(optionalNumber(uint64(connection.Port)))
	f.user.SetText(connection.User)
	f.identityFile.SetText(connection.IdentityFile)
	f.proxyJump.SetText(connection.ProxyJump)
	f.timeout.SetText(optionalNumber(uint64(connection.ConnectTimeoutSeconds)))
	f.keepAlive.SetText(optionalNumber(uint64(connection.KeepAliveSeconds)))
	f.authentication = connection.Authentication
	if f.authentication == "" {
		f.authentication = core.RemoteAuthenticationAuto
	}
	f.advanced.Open = connection.ProxyJump != "" || connection.ConnectTimeoutSeconds != 0 || connection.KeepAliveSeconds != 0
}

// fields are the form's text fields.
func (f *remoteForm) fields() []*ui.Field {
	return []*ui.Field{&f.name, &f.host, &f.port, &f.user, &f.identityFile, &f.proxyJump, &f.timeout, &f.keepAlive, &f.newGroup}
}

// groupName is the group the form saves, as chosen or typed: Core trims it, a blank one is no
// group, and one that differs from a group of the list only in case is that group.
func (f *remoteForm) groupName() string {
	if f.group == remoteNewGroup {
		return f.newGroup.Text()
	}
	return f.group
}

// optionalNumber is value as the form shows it: empty for an unset 0.
func optionalNumber(value uint64) string {
	if value == 0 {
		return ""
	}
	return strconv.FormatUint(value, 10)
}

// connection is the connection the form describes. A number field that is not a whole number in
// range is refused here, naming Core's field, since Core receives only numbers; every other check
// is Core's. Text is passed as typed, and Core trims it.
func (f *remoteForm) connection() (core.SSHConnection, *remoteFieldRefusal) {
	port, refused := formNumber(&f.port, "port", 16)
	if refused != nil {
		return core.SSHConnection{}, refused
	}
	timeout, refused := formNumber(&f.timeout, "connectTimeoutSeconds", 32)
	if refused != nil {
		return core.SSHConnection{}, refused
	}
	keepAlive, refused := formNumber(&f.keepAlive, "keepAliveSeconds", 32)
	if refused != nil {
		return core.SSHConnection{}, refused
	}
	connection := core.SSHConnection{
		Host:                  f.host.Text(),
		Port:                  uint16(port),
		User:                  f.user.Text(),
		Authentication:        f.authentication,
		ProxyJump:             f.proxyJump.Text(),
		ConnectTimeoutSeconds: uint32(timeout),
		KeepAliveSeconds:      uint32(keepAlive),
	}
	if f.authentication == core.RemoteAuthenticationPrivateKey {
		connection.IdentityFile = f.identityFile.Text()
	}
	return connection, nil
}

// formNumber reads an optional whole number of at most bits bits from field; empty is 0, unset.
func formNumber(field *ui.Field, name string, bits int) (uint64, *remoteFieldRefusal) {
	text := strings.TrimSpace(field.Text())
	if text == "" {
		return 0, nil
	}
	value, err := strconv.ParseUint(text, 10, bits)
	if err != nil {
		return 0, &remoteFieldRefusal{field: name, reason: "invalid"}
	}
	return value, nil
}

// saveName is the name the form saves: the name typed, or the host when none was.
func (f *remoteForm) saveName() string {
	if name := strings.TrimSpace(f.name.Text()); name != "" {
		return name
	}
	return strings.TrimSpace(f.host.Text())
}

// dirty says whether the form differs from the saved connection it shows. A new connection is
// dirty once a host is typed.
func (r *remoteState) dirty() bool {
	entry := r.entry(r.selected)
	if entry == nil {
		return strings.TrimSpace(r.form.host.Text()) != ""
	}
	connection, refused := r.form.connection()
	if refused != nil {
		return true
	}
	return r.form.saveName() != entry.Name || remoteStored(connection) != remoteStored(entry.Connection) ||
		r.form.color != entry.Color || strings.TrimSpace(r.form.groupName()) != entry.Group
}

// remoteStored is connection as Core stores it: its text trimmed and automatic authentication
// named.
func remoteStored(connection core.SSHConnection) core.SSHConnection {
	trim := strings.TrimSpace
	connection.Host, connection.User = trim(connection.Host), trim(connection.User)
	connection.IdentityFile, connection.ProxyJump = trim(connection.IdentityFile), trim(connection.ProxyJump)
	if connection.Authentication == "" {
		connection.Authentication = core.RemoteAuthenticationAuto
	}
	return connection
}

// editable says whether the list can take an edit now.
func (r *remoteState) editable() bool {
	return r.loaded && !r.loading && !r.saving && r.readErr == ""
}

// saveRemote saves the form as a new connection or over the selected one, then reads the list
// again and shows what was stored.
func (a *App) saveRemote() {
	r := &a.remote
	if !r.open || !r.editable() {
		return
	}
	r.err, r.fieldErr, r.confirmDelete = "", remoteFieldRefusal{}, false
	connection, refused := r.form.connection()
	if refused != nil {
		a.operationRejected("remote_connection_save", "number_invalid")
		r.fieldErr = *refused
		return
	}
	a.performed("remote.connection.save", surfaceButton)
	edit := core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{
		ID:         r.selected,
		Name:       r.form.saveName(),
		Connection: connection,
		Color:      r.form.color,
		Group:      r.form.groupName(),
	}}
	a.editRemote("remote_connection_save", edit)
}

// removeRemote deletes the selected connection once the user confirmed it.
func (a *App) removeRemote() {
	r := &a.remote
	if !r.open || !r.editable() || r.entry(r.selected) == nil {
		return
	}
	r.err, r.fieldErr, r.confirmDelete = "", remoteFieldRefusal{}, false
	a.performed("remote.connection.remove", surfaceButton)
	a.editRemote("remote_connection_remove", core.RemoteConnectionEdit{Remove: &core.RemoteConnectionID{ID: r.selected}})
}

// forgetRemovedRemote forgets the answers the deleted connection id remembered, which no
// connection can use any more.
func (a *App) forgetRemovedRemote(id string) {
	secrets := a.remoteSecrets()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		err := remoteconn.ForgetAnswers(ctx, secrets, id)
		return func(a *App) { a.remoteAnswersSettled(err, true) }
	})
}

// editRemote applies edit to the list as it was read, in the background. site names the
// operation in the log.
func (a *App) editRemote(site string, edit core.RemoteConnectionEdit) {
	r := &a.remote
	r.saving = true
	generation, kernel, source := r.generation, a.kernel, r.source
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		after, id, committed, err := source.Edit(ctx, kernel, edit)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				if err != nil {
					a.operationFailed(site, documentLogError(err))
				}
				// log-exempt: 用户取消：窗口关闭后不再应用保存结果；文件已按原子方式写入或未写入。
				return
			}
			r.saving = false
			language := a.language()
			if field, reason, ok := core.RemoteConnectionFieldError(err); ok {
				a.operationRejected(site, "field_refused")
				refusal := remoteFieldRefusal{field: field, reason: reason}
				if remoteFormField(field) {
					r.fieldErr = refusal
				} else {
					r.err = remoteRefusalText(language, refusal)
				}
				return
			}
			switch {
			case errors.Is(err, remoteconn.ErrConflict):
				a.operationRejected(site, "changed_on_disk")
				r.err = i18n.Shared(language, "desktop.remote.conflict")
				a.loadRemote(remoteLoadKeepForm, "")
				return
			case err != nil && committed:
				// The list reached the disk, but reading it back failed: the read shows why.
				a.operationFailed(site, documentLogError(err))
				a.loadRemote(remoteLoadSelect, id)
				return
			case err != nil:
				a.operationFailed(site, documentLogError(err))
				if errors.Is(err, remoteconn.ErrDamaged) {
					r.readErr = remoteReadFailure(language, source, err)
					return
				}
				if edit.Remove != nil {
					r.err = i18n.SharedFormat(language, "desktop.remote.deleteFailed", map[string]string{"reason": err.Error()})
				} else {
					r.err = i18n.SharedFormat(language, "desktop.remote.saveFailed", map[string]string{"reason": err.Error()})
				}
				return
			}
			r.loaded = true
			r.setSource(after)
			a.loadRemoteImportCounts()
			if edit.Remove != nil {
				a.forgetRemovedRemote(edit.Remove.ID)
				r.selectFirst()
				return
			}
			r.selectEntry(id)
		}
	})
}

// chooseRemoteIdentity lets the user pick the private key file; only its path is kept.
func (a *App) chooseRemoteIdentity() {
	r := &a.remote
	generation := r.generation
	title := i18n.Shared(a.language(), "desktop.remote.identityFile")
	a.background(nil, 0, func(context.Context) func(*App) {
		paths, err := app.OpenFiles(app.OpenFileOptions{Title: title})
		return func(a *App) {
			r := &a.remote
			if errors.Is(err, app.ErrCanceled) {
				// log-exempt: 用户取消：文件选择器没有选择结果。
				return
			}
			if err != nil {
				a.operationFailed("remote_choose_identity", documentLogError(err))
				if r.open && r.generation == generation {
					r.err = i18n.SharedFormat(a.language(), "desktop.remote.chooseFailed", map[string]string{"reason": documentLogError(err).Error()})
				}
				return
			}
			if !r.open || r.generation != generation || len(paths) == 0 {
				// log-exempt: 用户取消：窗口关闭后不再应用选择结果。
				return
			}
			r.form.identityFile.SetText(paths[0])
		}
	})
}

// testRemote connects with what the form holds, saved or not, and reports what the host is.
// OpenSSH's questions (a password, a passphrase, an unknown host key) are asked in the
// authentication dialog while it runs.
func (a *App) testRemote() {
	r := &a.remote
	if !r.open || r.probe != nil {
		return
	}
	r.result, r.err, r.fieldErr = nil, "", remoteFieldRefusal{}
	connection, refused := r.form.connection()
	if refused != nil {
		a.operationRejected("remote_probe", "number_invalid")
		r.fieldErr = *refused
		return
	}
	a.performed("remote.connection.test", surfaceButton)
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), remoteProbeTimeout)
	probe := &remoteProbe{cancel: cancel}
	r.probe = probe
	// A saved connection's test remembers its answers as connecting does, under the questions of
	// the login the form holds.
	answers := a.remoteAnswersFor(r.selected, remoteHost{ssh: connection})
	generation, kernel, root := r.generation, a.kernel, a.globalToolchainRoot()
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		var result core.RemoteProbeResult
		preferences, err := remotePreferencesDocument(ctx, kernel, root)
		if err == nil {
			result, err = kernel.RemoteProbe(a.remoteAuthentication(ctx, answers, true), connection, preferences)
		}
		settled := answers.settle(result.Status, err)
		return func(a *App) {
			a.remoteAnswersSettled(settled, true)
			r := &a.remote
			if !r.open || r.generation != generation || r.probe != probe {
				// log-exempt: 用户取消：测试已停止、换了连接或窗口已关闭，不再应用结果。
				return
			}
			r.probe = nil
			switch {
			case err != nil:
				if field, reason, ok := core.RemoteConnectionFieldError(err); ok {
					a.operationRejected("remote_probe", "field_refused")
					refusal := remoteFieldRefusal{field: field, reason: reason}
					if remoteFormField(field) {
						r.fieldErr = refusal
					} else {
						r.err = remoteRefusalText(a.language(), refusal)
					}
					return
				}
				a.operationFailed("remote_probe", documentLogError(err))
			case result.Status != core.RemoteProbeConnected:
				// The status is Core's fixed token; OpenSSH's output may name the host and user
				// and is only shown.
				a.operationFailed("remote_probe", errors.New("remote probe: "+string(result.Status)))
			}
			r.result = &remoteProbeOutcome{result: result, err: err, at: a.now()}
			// A refusal shows what OpenSSH said at once; a host reached keeps it folded.
			r.log.Open = err == nil && result.Status != core.RemoteProbeConnected
			if err == nil {
				// What the host is outlives the form; an error that kept the test from
				// running says nothing about the host and is only shown.
				if r.probed == nil {
					r.probed = map[core.SSHConnection]*remoteProbeOutcome{}
				}
				r.probed[remoteStored(connection)] = r.result
			}
		}
	})
}

// stopRemoteTest stops the running test.
func (a *App) stopRemoteTest() {
	r := &a.remote
	if r.probe == nil {
		return
	}
	a.performed("remote.connection.test.stop", surfaceButton)
	r.stopProbe()
}

// remoteFormField says whether the form shows field, Core's name of a connection's field.
func remoteFormField(field string) bool {
	switch field {
	case "name", "host", "port", "user", "authentication", "identityFile", "proxyJump", "connectTimeoutSeconds", "keepAliveSeconds", "group":
		return true
	}
	return false
}

// remoteRefusalText says why Core, or the form's number check, refused a field.
func remoteRefusalText(language i18n.Language, refusal remoteFieldRefusal) string {
	switch refusal.reason {
	case "required":
		return i18n.Shared(language, "desktop.remote.error.required")
	case "tooLong":
		switch refusal.field {
		case "name":
			return i18n.Shared(language, "desktop.remote.error.nameTooLong")
		case "group":
			return i18n.Shared(language, "desktop.remote.error.groupTooLong")
		}
		return i18n.Shared(language, "desktop.remote.error.fieldTooLong")
	case "duplicate":
		if refusal.field == "name" {
			return i18n.Shared(language, "desktop.remote.error.nameDuplicate")
		}
		return i18n.Shared(language, "desktop.remote.error.duplicate")
	case "full":
		return i18n.Shared(language, "desktop.remote.error.full")
	case "unknown":
		return i18n.Shared(language, "desktop.remote.error.unknown")
	case "invalid":
		switch refusal.field {
		case "host":
			return i18n.Shared(language, "desktop.remote.error.hostInvalid")
		case "port":
			return i18n.Shared(language, "desktop.remote.error.portInvalid")
		case "user":
			return i18n.Shared(language, "desktop.remote.error.userInvalid")
		case "proxyJump":
			return i18n.Shared(language, "desktop.remote.error.proxyJumpInvalid")
		case "connectTimeoutSeconds":
			return i18n.Shared(language, "desktop.remote.error.timeoutInvalid")
		case "keepAliveSeconds":
			return i18n.Shared(language, "desktop.remote.error.keepAliveInvalid")
		case "group":
			return i18n.Shared(language, "desktop.remote.error.groupInvalid")
		case "name", "identityFile":
			return i18n.Shared(language, "desktop.remote.error.textInvalid")
		}
	}
	return i18n.Shared(language, "desktop.remote.error.invalid")
}
