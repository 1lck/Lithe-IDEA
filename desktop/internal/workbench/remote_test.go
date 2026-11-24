package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// redraw repaints the window after a test changed its state directly, as SetText does without
// invalidating, and lets the work it started finish.
func (h *harness) redraw() {
	h.t.Helper()
	h.app.invalidator.Invalidate()
	h.settle()
}

// pressTest clicks Test Connection and paints the frame that started the test, without waiting
// for background work: the test waits on the question the window has yet to show.
func (h *harness) pressTest() {
	h.t.Helper()
	point := center(h.hitLabeled(i18n.Shared(h.app.language(), "desktop.remote.test")))
	if err := h.driver.Click(point.X, point.Y); err != nil {
		h.t.Fatal(err)
	}
	if err := h.driver.Pump(); err != nil {
		h.t.Fatal(err)
	}
	if h.app.remote.probe == nil {
		h.t.Fatal("clicking Test Connection did not start a test")
	}
}

// remoteProbeKernel reports a fixed probe outcome instead of starting OpenSSH; everything else
// is testKernel.
type remoteProbeKernel struct {
	*testKernel
	result core.RemoteProbeResult
}

func (k *remoteProbeKernel) RemoteProbe(context.Context, core.SSHConnection, *string) (core.RemoteProbeResult, error) {
	return k.result, nil
}

// remoteHarness is an English window with the Remote Development window open and its saved list
// read, through the real Core.
func remoteHarness(t *testing.T) (*harness, *treeRecordingLog) {
	t.Helper()
	return remoteHarnessWith(t, &testKernel{Client: core.NewClient()})
}

// remoteHarnessWith is remoteHarness through kernel.
func remoteHarnessWith(t *testing.T, kernel Kernel) (*harness, *treeRecordingLog) {
	t.Helper()
	h := newHarnessWithLanguages(t, kernel, []string{"en-US"})
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	if !h.app.remote.loaded || h.app.remote.readErr != "" {
		t.Fatalf("loaded = %v, read error = %q", h.app.remote.loaded, h.app.remote.readErr)
	}
	return h, logger
}

// savedRemoteDocument reports whether the saved list exists on disk, in the preference directory.
func savedRemoteDocument(t *testing.T, h *harness) bool {
	t.Helper()
	_, err := os.Stat(filepath.Join(h.store.Dir(), "remote", "connections.json"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		t.Fatal(err)
	}
	return err == nil
}

// savedRemoteConnections are the entries of the saved list on disk, as Core reads them back.
func savedRemoteConnections(t *testing.T, h *harness) []core.SavedRemoteConnection {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	source, err := remoteconn.Read(ctx, core.NewClient(), h.store.Dir())
	if err != nil {
		t.Fatalf("read the saved list: %v", err)
	}
	return source.Connections
}

// remoteActions are the actions of the window and of its authentication dialog logged as
// performed, in order.
func remoteActions(logger *treeRecordingLog) []string {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	var actions []string
	for _, event := range logger.events {
		if action, _ := event.Fields["action"].(string); event.Event == "app.action.performed" && strings.HasPrefix(action, "remote.") {
			actions = append(actions, action)
		}
	}
	return actions
}

// loggedAny reports whether any logged field holds one of values.
func loggedAny(t *testing.T, logger *treeRecordingLog, values ...string) string {
	t.Helper()
	logger.mu.Lock()
	defer logger.mu.Unlock()
	for _, event := range logger.events {
		encoded, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		for _, value := range values {
			if strings.Contains(string(encoded), value) {
				return string(encoded)
			}
		}
	}
	return ""
}

// rejected reports whether operation was logged as rejected for reason.
func rejected(logger *treeRecordingLog, operation, reason string) bool {
	logger.mu.Lock()
	defer logger.mu.Unlock()
	return slices.ContainsFunc(logger.events, func(event core.LogEvent) bool {
		return event.Event == operationRejectedEvent && event.Fields["operation"] == operation && event.Fields["reason"] == reason
	})
}

// A connection typed into the window is saved to the preference directory under the host's name
// and shown in its overview, edited in place from the overview's Edit and deleted after the
// footer's question; only the operations are logged, never the host or the user.
func TestRemoteConnectionsSaveEditAndDelete(t *testing.T) {
	h, logger := remoteHarness(t)
	lang := h.app.language()
	if !h.shows(i18n.Shared(lang, "desktop.remote.title")) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.empty")) {
		t.Fatal("the window does not open on the empty list")
	}
	if savedRemoteDocument(t, h) {
		t.Fatal("opening the window wrote the list")
	}
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("build.example")
	r.form.user.SetText("dev")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	entries := savedRemoteConnections(t, h)
	if len(entries) != 1 || entries[0].Name != "build.example" {
		t.Fatalf("saved %+v, want one connection named after its host", entries)
	}
	if connection := entries[0].Connection; connection.Host != "build.example" || connection.User != "dev" {
		t.Fatalf("saved connection %+v", connection)
	}
	if r.selected == "" || r.selected != entries[0].ID || !h.shows("dev@build.example") || r.dirty() {
		t.Fatalf("selected = %q, dirty = %v: the saved connection is not the one the form edits", r.selected, r.dirty())
	}
	if r.editingForm() || !h.shows(i18n.Shared(lang, "desktop.remote.recentFolders")) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.untested")) {
		t.Fatal("a saved connection does not show its overview")
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.edit"))
	if !r.editingForm() || r.selected != entries[0].ID {
		t.Fatal("Edit does not show the saved connection's form")
	}
	r.form.name.SetText("Build box")
	r.form.port.SetText("2222")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	entries = savedRemoteConnections(t, h)
	if len(entries) != 1 || entries[0].Name != "Build box" || entries[0].Connection.Port != 2222 || !h.shows("Build box") {
		t.Fatalf("edited %+v, want the one connection renamed with its port", entries)
	}
	if r.editingForm() || !h.shows("dev@build.example:2222") {
		t.Fatal("saving the edit does not go back to the overview")
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.more"))
	h.settle()
	h.clickFront(i18n.SharedFormat(lang, "desktop.remote.deleteNamed", map[string]string{"name": "Build box"}))
	h.settle()
	if !r.confirmDelete || !h.shows(i18n.SharedFormat(lang, "desktop.remote.deleteConfirm", map[string]string{"name": "Build box"})) {
		t.Fatal("Delete does not ask first")
	}
	if len(savedRemoteConnections(t, h)) != 1 {
		t.Fatal("Delete deleted before it was confirmed")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.delete"))
	h.settle()
	if got := savedRemoteConnections(t, h); len(got) != 0 || r.selected != "" || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.empty")) {
		t.Fatalf("after deleting: saved %v, selected %q", got, r.selected)
	}
	want := []string{"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connection.edit", "remote.connection.save", "remote.connection.deleteAsk", "remote.connection.remove"}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, "build.example", "Build box", h.store.Dir()); event != "" {
		t.Fatalf("logged the connection: %s", event)
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.close"))
	h.settle()
	// The welcome page's own Remote Development button stays behind the window, so the
	// window is looked for by what only it shows: the empty list's text and its Close.
	_, closeShown := h.findPageHit(i18n.Shared(lang, "desktop.remote.close"))
	if r.open || closeShown || h.showsWrapped(i18n.Shared(lang, "desktop.remote.empty")) {
		t.Fatal("Close left the window open")
	}
}

// A connection saved from New is the list's selected row, also when the list had fewer rows the
// frame before: the keyboard moves from the connection the form edits.
func TestRemoteSavedConnectionIsTheSelectedRow(t *testing.T) {
	h, _ := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	for _, host := range []string{"lab-arm.internal", "build.example"} {
		h.clickLabeled(i18n.Shared(lang, "desktop.remote.new"))
		r.form.host.SetText(host)
		h.redraw()
		h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
		h.redraw()
		at := r.list.Selected()
		if r.selected == "" || at < 0 || at >= len(r.rows) || r.rows[at].entry == nil || r.rows[at].entry.ID != r.selected {
			t.Fatalf("after saving %d: list row %d, want the row of %q, the connection the form edits", len(r.source.Connections), at, r.selected)
		}
	}
}

// A connection's color and group are kept with it in Core's list, a new group named in the field
// beside the choice; the list heads its sections with their groups once any connection has one,
// the connections without one last.
func TestRemoteConnectionsColorAndGroup(t *testing.T) {
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("lab-arm.internal")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.color.green"))
	if r.form.color != core.RemoteConnectionGreen {
		t.Fatalf("color = %q after clicking Green", r.form.color)
	}
	r.form.group = remoteNewGroup
	h.redraw()
	if got := h.focusedName(); got != i18n.Shared(lang, "desktop.remote.groupPlaceholder") {
		t.Fatalf("focused %q, want the new group's name", got)
	}
	h.typeText("Lab")
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	entries := savedRemoteConnections(t, h)
	if len(entries) != 1 || entries[0].Color != core.RemoteConnectionGreen || entries[0].Group != "Lab" {
		t.Fatalf("saved %+v, want the green connection in Lab", entries)
	}
	if len(r.rows) != 2 || !r.rows[0].heading || r.rows[0].group != "Lab" || r.rows[0].count != 1 || !slices.Equal(r.groups, []string{"Lab"}) {
		t.Fatalf("rows %+v, groups %q: want Lab's heading over its connection", r.rows, r.groups)
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.new"))
	if r.form.color != "" || r.form.group != "" {
		t.Fatalf("a new connection starts with color %q, group %q", r.form.color, r.form.group)
	}
	r.form.host.SetText("build.example")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	headings := func() (groups []string) {
		for _, row := range r.rows {
			if row.heading {
				groups = append(groups, remoteGroupHeading(lang, row.group))
			}
		}
		return groups
	}
	if got := headings(); !slices.Equal(got, []string{"Lab", i18n.Shared(lang, "desktop.remote.ungrouped")}) || !h.shows(i18n.Shared(lang, "desktop.remote.ungrouped")) {
		t.Fatalf("headings %q, want Lab, then the connections without a group", got)
	}

	// An existing group is a choice of its own; choosing it moves the connection under it.
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.edit"))
	r.form.group = "Lab"
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	if got := headings(); !slices.Equal(got, []string{"Lab"}) || r.rows[0].count != 2 {
		t.Fatalf("headings %q, rows %+v, want both connections under Lab", got, r.rows)
	}
	if event := loggedAny(t, logger, "lab-arm.internal", "build.example"); event != "" {
		t.Fatalf("logged the connection: %s", event)
	}
}

// Cancel drops what was typed: an edited connection shows its overview as saved, and a new one
// gives way to the connection selected before New.
func TestRemoteCancelGoesBackToTheSavedConnection(t *testing.T) {
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	for _, host := range []string{"lab-arm.internal", "build.example"} {
		h.clickLabeled(i18n.Shared(lang, "desktop.remote.new"))
		r.form.host.SetText(host)
		h.redraw()
		h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
		h.settle()
	}
	build := r.selected
	if entry := r.entry(build); entry == nil || entry.Name != "build.example" || r.editingForm() {
		t.Fatalf("selected %q, want the overview of the second connection", build)
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.edit"))
	r.form.name.SetText("Renamed")
	h.redraw()
	if !r.dirty() {
		t.Fatal("a renamed connection is not dirty")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.cancel"))
	if r.editingForm() || r.selected != build || r.form.name.Text() != "build.example" || h.shows("Renamed") {
		t.Fatalf("after Cancel: editing = %v, selected = %q, name = %q", r.editingForm(), r.selected, r.form.name.Text())
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.new"))
	if !r.editingForm() || r.selected != "" {
		t.Fatal("New does not show an empty form")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.cancel"))
	if r.editingForm() || r.selected != build {
		t.Fatalf("after cancelling New: selected %q, want %q", r.selected, build)
	}
	if got := savedRemoteConnections(t, h); len(got) != 2 || got[1].Name != "build.example" {
		t.Fatalf("saved %+v, want both connections as saved", got)
	}
	want := []string{
		"remote.connections.open", "remote.connection.new", "remote.connection.save", "remote.connection.new", "remote.connection.save",
		"remote.connection.edit", "remote.connection.edit.cancel", "remote.connection.new", "remote.connection.edit.cancel",
	}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
}

// What a test found about the host shows in the overview of the connection it tested, after the
// connection is saved and again after the window is opened anew; a connection never tested says
// how to find out.
func TestRemoteOverviewShowsTheTestedHost(t *testing.T) {
	const gib = uint64(1) << 30
	kernel := &remoteProbeKernel{testKernel: &testKernel{Client: core.NewClient()}, result: core.RemoteProbeResult{
		Status: core.RemoteProbeConnected,
		Host: &core.RemoteProbedHost{
			System: "Linux", Machine: "x86_64", HomeDirectory: "/home/dev",
			Details: core.RemoteHostDetails{HostName: "build-01", CPUCount: 16, MemoryBytes: 64 * gib},
		},
	}}
	h, _ := remoteHarnessWith(t, kernel)
	lang := h.app.language()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("build.example")
	r.form.user.SetText(" dev ")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.test"))
	h.await("the test to finish", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if !h.shows("build-01") {
		t.Fatal("the form does not show what the test found")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	shown := func() bool {
		return !r.editingForm() && h.shows("build-01") && h.shows(i18n.Shared(lang, "desktop.remote.probe.cpu")) &&
			!h.showsWrapped(i18n.Shared(lang, "desktop.remote.untested"))
	}
	if !shown() {
		t.Fatal("the saved connection's overview does not show the host the test found")
	}

	h.app.closeRemote()
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	if !shown() {
		t.Fatal("the overview forgot the tested host when the window opened again")
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.new"))
	r.form.host.SetText("lab-arm.internal")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	if h.shows("build-01") || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.untested")) {
		t.Fatal("a connection never tested shows another one's host")
	}
}

// A successful probe can have no optional host details. Its empty tag list must
// not leave a name for the next text or for a later repaint.
func TestRemoteProbeWithoutDetailsKeepsFollowingTextAnonymous(t *testing.T) {
	a := &App{theme: ui.LightTheme()}
	outcome := &remoteProbeOutcome{result: core.RemoteProbeResult{
		Status: core.RemoteProbeConnected, Host: &core.RemoteProbedHost{},
	}}
	page := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
		ui.Column(c).Fill().Children(func() {
			a.remoteOutcomeBox(c, a.language(), outcome)
			ui.Text(c, "After the probe")
			ui.Text(c, "End")
		})
	}})
	driver, err := app.NewDriver(ui.Configure(page, app.Config{Width: 800, Height: 600}), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	if err := driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
}

// Jump hosts and the target are anonymous route labels. Redrawing that route must
// not leave a host's key on a chevron or on the following text.
func TestRemoteJumpRouteRepaintsWithMultipleHosts(t *testing.T) {
	a := &App{theme: ui.LightTheme()}
	a.remote.form.proxyJump.SetText("first.example,second.example")
	a.remote.form.host.SetText("target.example")
	a.remote.form.user.SetText("dev")
	page := ui.NewPage(ui.PageConfig{Theme: &a.theme, View: func(c ui.C) {
		ui.Column(c).Fill().Children(func() {
			a.remoteHops(c, a.language(), false)
			ui.Text(c, "After the route")
		})
	}})
	driver, err := app.NewDriver(ui.Configure(page, app.Config{Width: 800, Height: 600}), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(driver.Close)
	if err := driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"first.example", "second.example", "dev@target.example", "After the route"} {
		found := false
		for _, label := range driver.Snapshot().Labels {
			found = found || label.Value == want
		}
		if !found {
			t.Errorf("the route did not show %q", want)
		}
	}
}

// A field Core refuses is named under that field and nothing is written; a number the form
// cannot parse is refused before it reaches Core.
func TestRemoteConnectionRefusedFieldsAreShownUnderTheField(t *testing.T) {
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("dev@box")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	if r.fieldErr != (remoteFieldRefusal{field: "host", reason: "invalid"}) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.error.hostInvalid")) {
		t.Fatalf("field refusal = %+v, want the host refused under its field", r.fieldErr)
	}
	if savedRemoteDocument(t, h) || !rejected(logger, "remote_connection_save", "field_refused") {
		t.Fatal("a refused connection was written, or the refusal was not logged")
	}

	r.form.host.SetText("box")
	r.form.port.SetText("70000")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	if r.fieldErr != (remoteFieldRefusal{field: "port", reason: "invalid"}) || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.error.portInvalid")) {
		t.Fatalf("field refusal = %+v, want the port refused under its field", r.fieldErr)
	}
	if savedRemoteDocument(t, h) || !rejected(logger, "remote_connection_save", "number_invalid") {
		t.Fatal("a port out of range was written, or the refusal was not logged")
	}

	// The private key path is only asked for, and only kept, with private key authentication.
	if h.shows(i18n.Shared(lang, "desktop.remote.identityFile")) {
		t.Fatal("the private key field shows for automatic authentication")
	}
	r.form.authentication = core.RemoteAuthenticationPrivateKey
	r.form.port.SetText("")
	r.form.identityFile.SetText("~/.ssh/id_ed25519")
	h.redraw()
	if !h.shows(i18n.Shared(lang, "desktop.remote.identityFile")) {
		t.Fatal("the private key field is missing for private key authentication")
	}
	r.form.authentication = core.RemoteAuthenticationAgent
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.save"))
	h.settle()
	entries := savedRemoteConnections(t, h)
	if len(entries) != 1 || entries[0].Connection.Authentication != core.RemoteAuthenticationAgent || entries[0].Connection.IdentityFile != "" {
		t.Fatalf("saved %+v, want the agent connection without a key path", entries)
	}
}

// standInSSH puts an ssh on PATH that ignores its options and, after asking for a password
// through the AskPass helper Core names, runs the remote command with the local shell. A wrong
// or cancelled answer fails like a server rejecting it.
func standInSSH(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in SSH client is a POSIX shell script")
	}
	dir := t.TempDir()
	script := `#!/bin/sh
for last; do :; done
answer=$("$SSH_ASKPASS" "dev@devbox's password: ") || answer=
if [ "$answer" != "s3cret" ]; then
  echo 'dev@devbox: Permission denied (password).' >&2
  exit 255
fi
exec /bin/sh -c "$last"
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// Testing a connection asks OpenSSH's password question in the SSH authentication dialog over
// the window, and shows what the host reported once it is answered; cancelling the question
// shows the server's refusal with OpenSSH's output. A connection that is not saved offers to
// remember nothing. Neither the password, the host nor the user is logged.
func TestRemoteTestAsksInTheWindowAndReportsTheHost(t *testing.T) {
	standInSSH(t)
	h, logger := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("devbox")
	r.form.user.SetText("dev")
	h.redraw()

	h.pressTest()
	h.awaitGitQuestion("the password question", func(c core.GitAuthChallenge) bool { return c.Remote && c.Secret })
	if !h.shows(i18n.Shared(lang, "desktop.remoteAuth.title")) || !h.shows("password") || !h.showsWrapped(i18n.Shared(lang, "desktop.remoteAuth.secretHint")) {
		t.Fatal("the dialog does not show OpenSSH's question as the SSH client's")
	}
	if h.shows(i18n.Shared(lang, "desktop.gitAuth.title")) {
		t.Fatal("the remote question is titled as Git's")
	}
	if h.shows(i18n.Shared(lang, "desktop.remoteAuth.rememberPassword")) {
		t.Fatal("a connection that is not saved offers to remember its password")
	}
	if got := h.focusedName(); got != i18n.Shared(lang, "desktop.gitAuth.answer") {
		t.Fatalf("focused %q, want the answer field", got)
	}
	h.typeText("s3cret")
	h.key(gfx.KeyEnter)
	h.await("the test to finish", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	result := r.result.result
	if r.result.err != nil || result.Host == nil {
		t.Fatalf("outcome = %+v, want the host's report", r.result)
	}
	// The local machine is the host here, so whether a server build exists depends on it.
	key := "desktop.remote.probe.unsupported"
	if result.Status == core.RemoteProbeConnected {
		key = "desktop.remote.probe.connected"
	}
	platform := map[string]string{"system": result.Host.System, "machine": result.Host.Machine}
	usable := result.Status != core.RemoteProbeConnected || h.shows(i18n.Shared(lang, "desktop.remote.probe.usable"))
	if !h.showsWrapped(i18n.SharedFormat(lang, key, platform)) || !usable {
		t.Fatalf("the window does not show the platform the host reported (%s)", result.Status)
	}

	h.pressTest()
	h.awaitGitQuestion("the password question again", func(c core.GitAuthChallenge) bool { return c.Remote })
	// Escape dismisses the topmost dialog, the question, and leaves the window open.
	h.key(gfx.KeyEscape)
	h.await("the test to fail", func() bool { return r.probe == nil && r.result != nil })
	h.settle()
	if !r.open || r.result.result.Status != core.RemoteProbeAuthenticationFailed {
		t.Fatalf("open = %v, outcome = %+v, want the refusal in the open window", r.open, r.result)
	}
	if !h.showsWrapped(i18n.Shared(lang, "desktop.remote.probe.authenticationFailed")) || !h.showsWrapped("Permission denied (password).") {
		t.Fatal("the window does not show the refusal with OpenSSH's output")
	}
	want := []string{"remote.connections.open", "remote.connection.new", "remote.connection.test", "remote.authentication.answer", "remote.connection.test", "remote.authentication.cancel"}
	if got := remoteActions(logger); !slices.Equal(got, want) {
		t.Fatalf("performed %q, want %q", got, want)
	}
	if event := loggedAny(t, logger, "s3cret", "devbox", "Permission denied"); event != "" {
		t.Fatalf("logged what the connection is or OpenSSH said: %s", event)
	}
}

// Stopping a test drops its result, and closing the window stops a test that waits on a question.
func TestRemoteTestStopsWithTheWindow(t *testing.T) {
	standInSSH(t)
	h, _ := remoteHarness(t)
	lang := h.app.language()
	r := &h.app.remote
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("devbox")
	h.redraw()
	h.pressTest()
	h.awaitGitQuestion("the password question", func(c core.GitAuthChallenge) bool { return c.Remote })
	// The question covers the window, so Stop is the window's own action here.
	h.app.stopRemoteTest()
	h.await("the question to leave after Stop", func() bool { return len(h.app.gitAuth.queue) == 0 })
	h.settle()
	if !r.open || r.probe != nil || r.result != nil || h.showsWrapped(i18n.Shared(lang, "desktop.remote.probe.authenticationFailed")) {
		t.Fatalf("open = %v, probe = %v, result = %+v after Stop, want the open window without an outcome", r.open, r.probe, r.result)
	}

	h.pressTest()
	h.awaitGitQuestion("the password question again", func(c core.GitAuthChallenge) bool { return c.Remote })
	h.app.closeRemote()
	h.await("the question to leave after closing", func() bool { return len(h.app.gitAuth.queue) == 0 })
	h.settle()
	if r.open || r.probe != nil || r.result != nil {
		t.Fatalf("open = %v, probe = %v, result = %+v after closing", r.open, r.probe, r.result)
	}
}

// importCountKernel answers the import lists the way Core does for hosts already saved: a host is
// "exists" once the saved list it is handed holds it. Nothing runs ssh or reads the account's files.
type importCountKernel struct {
	*testKernel
	documents []*string
}

func (k *importCountKernel) RemoteSSHConfigHosts(_ context.Context, _ string, document, _ *string) (core.RemoteSSHConfigHosts, error) {
	k.documents = append(k.documents, document)
	var hosts core.RemoteSSHConfigHosts
	for _, alias := range []string{"alpha", "beta"} {
		status := core.RemoteImportable
		if document != nil && strings.Contains(*document, `"`+alias+`"`) {
			status = core.RemoteImportExists
		}
		hosts.Hosts = append(hosts.Hosts, core.RemoteSSHConfigHost{Alias: alias, Status: status})
	}
	return hosts, nil
}

func (k *importCountKernel) RemoteMottyHosts(context.Context, string, *string) (core.RemoteMottyHosts, error) {
	return core.RemoteMottyHosts{Unavailable: core.RemoteMottyMissing}, nil
}

// The empty page's import counts leave out the hosts already saved, and follow the list each time
// a save changes it.
func TestRemoteImportCountsLeaveOutSavedHosts(t *testing.T) {
	kernel := &importCountKernel{testKernel: &testKernel{Client: core.NewClient()}}
	h, _ := remoteHarnessWith(t, kernel)
	r := &h.app.remote
	h.settle()
	if !r.imports.loaded || r.imports.sshConfig != 2 {
		t.Fatalf("counts = %+v, want both hosts", r.imports)
	}
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.new"))
	r.form.host.SetText("alpha")
	r.form.user.SetText("dev")
	h.redraw()
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.save"))
	h.settle()
	h.settle()
	if r.err != "" || len(r.source.Connections) != 1 {
		t.Fatalf("saving: %q, %d saved", r.err, len(r.source.Connections))
	}
	if r.imports.sshConfig != 1 {
		t.Fatalf("counts = %+v after saving alpha, want only beta", r.imports)
	}
}

// The import's footer names only the groups the chosen Motty hosts bring that the list lacks, once
// each in Motty's order, and none when the import does not keep groups.
func TestRemoteImportNewGroupsAreTheChosenOnesTheListLacks(t *testing.T) {
	app := &App{}
	app.remote.groups = []string{"Production"}
	m := &remoteImporter{source: remoteImportMotty, keepGroups: true, motty: core.RemoteMottyHosts{Candidates: []core.RemoteMottyCandidate{
		{Key: "1", Group: "Production"}, {Key: "2", Group: "Staging"}, {Key: "3", Group: "Lab"}, {Key: "4", Group: "Staging"}, {Key: "5"},
	}}, mottyChosen: []bool{true, true, false, true, true}}
	if got, want := app.remoteImportNewGroups(m), []string{"Staging"}; !slices.Equal(got, want) {
		t.Fatalf("new groups = %q, want %q", got, want)
	}
	m.keepGroups = false
	if got := app.remoteImportNewGroups(m); got != nil {
		t.Fatalf("new groups without keeping groups = %q", got)
	}
}
