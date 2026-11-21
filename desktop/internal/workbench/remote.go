package workbench

import (
	"context"
	"errors"
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
// one: the saved list on the left, the selected connection's form on the right. It belongs to the
// window, not to a project, so it opens on the welcome screen as over a project.
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
	// generation counts the openings and closings, so that a result arriving after the window
	// closed is dropped.
	generation uint64
	loading    bool
	loaded     bool
	source     remoteconn.Source
	// readErr is why the list could not be read; nothing can be saved until it can.
	readErr string
	list    ui.ListState
	// selected is the id of the saved connection the form edits, "" for a new one.
	selected string
	form     remoteForm
	saving   bool
	// confirmDelete is the footer's question whether to delete the selected connection.
	confirmDelete bool
	// probe is the running test, nil when none runs; result is the last one's outcome.
	probe  *remoteProbe
	result *remoteProbeOutcome
	// err is the last failure that names no field of the form; fieldErr names one.
	err      string
	fieldErr remoteFieldRefusal
}

// remoteForm is what the user types for one connection.
type remoteForm struct {
	name, host, port, user, identityFile, proxyJump, timeout, keepAlive ui.Field
	authentication                                                      string
	advanced                                                            ui.CollapsibleState
}

// remoteProbe is a test in progress, cancelled by Stop or by closing the window.
type remoteProbe struct {
	cancel context.CancelFunc
}

// remoteProbeOutcome is what a test found: Core's result, or the error that kept it from running.
type remoteProbeOutcome struct {
	result core.RemoteProbeResult
	err    error
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
		return
	}
	r.generation++
	*r = remoteState{open: true, generation: r.generation}
	r.form.clear()
	a.performed("remote.connections.open", surface)
	a.loadRemote(remoteLoadSelectFirst, "")
}

// closeRemote closes the window, stopping a running test. What was typed and not saved is
// dropped.
func (a *App) closeRemote() {
	r := &a.remote
	r.stopProbe()
	r.generation++
	r.open, r.saving, r.loading = false, false, false
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
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		source, err := remoteconn.Read(ctx, kernel, root)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation {
				// log-exempt: 用户取消：窗口关闭后不再应用读取结果。
				return
			}
			r.loading, r.loaded, r.source, r.readErr = false, true, source, ""
			if err != nil {
				a.operationFailed("remote_connections_read", documentLogError(err))
				r.readErr = remoteReadFailure(a.language(), source, err)
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
				r.selectFirst()
			}
		}
	})
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

// selectFirst selects the first saved connection, or starts a new one when there is none.
func (r *remoteState) selectFirst() {
	if len(r.source.Connections) == 0 {
		r.selectNew()
		return
	}
	r.selectEntry(r.source.Connections[0].ID)
}

// selectEntry shows the saved connection id in the form, dropping what was typed, the last test
// and its errors; a test still running for the previous form is stopped.
func (r *remoteState) selectEntry(id string) {
	entry := r.entry(id)
	if entry == nil {
		r.selectNew()
		return
	}
	r.resetEditing()
	r.selected = id
	r.form.fill(*entry)
	r.syncListSelection()
}

// selectNew starts a new connection with an empty form.
func (r *remoteState) selectNew() {
	r.resetEditing()
	r.selected = ""
	r.form.clear()
	r.syncListSelection()
}

// resetEditing drops the last test, its errors and the delete question.
func (r *remoteState) resetEditing() {
	r.stopProbe()
	r.result, r.err, r.fieldErr, r.confirmDelete = nil, "", remoteFieldRefusal{}, false
}

// syncListSelection selects the row of the edited connection, none for a new one.
func (r *remoteState) syncListSelection() {
	at := -1
	for index, entry := range r.source.Connections {
		if entry.ID == r.selected {
			at = index
			break
		}
	}
	if r.list.Selected() != at {
		r.list.Select(at)
		if at >= 0 {
			r.list.ScrollIntoView(at)
		}
	}
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
	f.advanced.Open = false
}

// fill shows a saved connection in the form; the advanced options are shown open when one is set.
func (f *remoteForm) fill(entry core.SavedRemoteConnection) {
	connection := entry.Connection
	f.name.SetText(entry.Name)
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
	return []*ui.Field{&f.name, &f.host, &f.port, &f.user, &f.identityFile, &f.proxyJump, &f.timeout, &f.keepAlive}
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
	saved := entry.Connection
	if saved.Authentication == "" {
		saved.Authentication = core.RemoteAuthenticationAuto
	}
	trim := func(text string) string { return strings.TrimSpace(text) }
	connection.Host, connection.User = trim(connection.Host), trim(connection.User)
	connection.IdentityFile, connection.ProxyJump = trim(connection.IdentityFile), trim(connection.ProxyJump)
	return r.form.saveName() != entry.Name || connection != saved
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
	edit := core.RemoteConnectionEdit{Save: &core.RemoteConnectionSave{ID: r.selected, Name: r.form.saveName(), Connection: connection}}
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
			r.source, r.loaded = after, true
			if edit.Remove != nil {
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
	generation, kernel := r.generation, a.kernel
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result, err := kernel.RemoteProbe(a.gitAuthentication(ctx), connection)
		return func(a *App) {
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
			r.result = &remoteProbeOutcome{result: result, err: err}
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
	case "name", "host", "port", "user", "authentication", "identityFile", "proxyJump", "connectTimeoutSeconds", "keepAliveSeconds":
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
		if refusal.field == "name" {
			return i18n.Shared(language, "desktop.remote.error.nameTooLong")
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
		case "name", "identityFile":
			return i18n.Shared(language, "desktop.remote.error.textInvalid")
		}
	}
	return i18n.Shared(language, "desktop.remote.error.invalid")
}
