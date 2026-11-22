package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// remoteHostRecords stands in for Core's port records (remote.portRecords, remote.editPortRecords
// and remote.restoreForwards): the document is a JSON object of each workspace's records, read and
// edited as Core does, and the forwards left running start again through the host's ports.
type remoteHostRecords struct {
	// edits are the edits the window asked for, and restores how often it restored forwards.
	edits    []core.RemotePortRecordEdit
	restores int
	// failRestore are the ports whose forwards do not start again.
	failRestore map[uint16]bool
}

// remoteTestRecordsStorage is where the stand-in names the document.
var remoteTestRecordsStorage = core.RemotePreferenceStorage{RelativePath: "remote/ports.json", MaximumBytes: 256 * 1024}

// remoteTestRecords decodes document into the records of every workspace.
func remoteTestRecords(document *string) (map[string]core.RemotePortRecords, error) {
	all := map[string]core.RemotePortRecords{}
	if document == nil {
		return all, nil
	}
	if err := json.Unmarshal([]byte(*document), &all); err != nil {
		return nil, &core.Error{Command: "remote.portRecords", Code: core.CodeParseFailed, Message: "damaged"}
	}
	return all, nil
}

func (k *remoteHostKernel) RemotePortRecords(_ context.Context, document *string, _, workspace string) (core.RemotePortRecordsState, error) {
	all, err := remoteTestRecords(document)
	if err != nil {
		return core.RemotePortRecordsState{}, err
	}
	return core.RemotePortRecordsState{Records: all[workspace], Workspace: workspace, Storage: remoteTestRecordsStorage}, nil
}

func (k *remoteHostKernel) EditRemotePortRecords(_ context.Context, document *string, _, workspace string, edit core.RemotePortRecordEdit) (bool, *string, core.RemotePortRecords, error) {
	k.mu.Lock()
	k.ports.records.edits = append(k.ports.records.edits, edit)
	k.mu.Unlock()
	all, err := remoteTestRecords(document)
	if err != nil {
		return false, nil, core.RemotePortRecords{}, err
	}
	before := all[workspace]
	records := core.RemotePortRecords{Ports: slices.Clone(before.Ports), Rules: slices.Clone(before.Rules)}
	refused := func(label string) bool {
		return utf8.RuneCountInString(label) > remotePortLabelMax || strings.ContainsFunc(label, unicode.IsControl)
	}
	switch {
	case edit.Port != nil:
		if refused(edit.Port.Label) {
			return false, nil, before, &core.Error{Command: "remote.editPortRecords", Code: core.CodeInvalidRequest, Message: "label"}
		}
		record := *edit.Port
		record.Host = remotePortHost(record.Host)
		records.Ports = slices.DeleteFunc(records.Ports, func(have core.RemotePortRecord) bool {
			return have.Host == record.Host && have.Port == record.Port
		})
		if !blankRemotePortRecord(record) {
			records.Ports = append(records.Ports, record)
		}
		slices.SortFunc(records.Ports, func(x, y core.RemotePortRecord) int {
			if x.Port != y.Port {
				return int(x.Port) - int(y.Port)
			}
			return strings.Compare(x.Host, y.Host)
		})
	case edit.RemovePort != nil:
		host := remotePortHost(edit.RemovePort.Host)
		records.Ports = slices.DeleteFunc(records.Ports, func(have core.RemotePortRecord) bool {
			return have.Host == host && have.Port == edit.RemovePort.Port
		})
	case edit.Rule != nil:
		if refused(edit.Rule.Label) {
			return false, nil, before, &core.Error{Command: "remote.editPortRecords", Code: core.CodeInvalidRequest, Message: "label"}
		}
		if at := slices.IndexFunc(records.Rules, func(have core.RemotePortRule) bool { return sameRemotePortRule(have, *edit.Rule) }); at >= 0 {
			records.Rules[at].Label = edit.Rule.Label
		} else {
			records.Rules = append(records.Rules, *edit.Rule)
		}
	case edit.RemoveRule != nil:
		records.Rules = slices.DeleteFunc(records.Rules, func(have core.RemotePortRule) bool { return sameRemotePortRule(have, *edit.RemoveRule) })
	}
	was, _ := json.Marshal(before)
	now, _ := json.Marshal(records)
	if string(was) == string(now) {
		return false, nil, records, nil
	}
	all[workspace] = records
	text, _ := json.Marshal(all)
	updated := string(text)
	return true, &updated, records, nil
}

func (k *remoteHostKernel) RestoreRemoteForwards(_ context.Context, document *string, session, workspace string) ([]core.RemoteRestoredForward, error) {
	all, err := remoteTestRecords(document)
	if err != nil {
		return nil, err
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	k.ports.records.restores++
	var restored []core.RemoteRestoredForward
	for _, record := range all[workspace].Ports {
		if record.ForwardTarget == "" {
			continue
		}
		item := core.RemoteRestoredForward{Host: record.Host, Port: record.Port}
		if k.ports.records.failRestore[record.Port] {
			item.Err = &core.Error{Command: "remote.restoreForwards", Code: core.CodeForwardLimitReached, Message: "too many forwards"}
			restored = append(restored, item)
			continue
		}
		forward, created, err := k.ports.start(session, core.RemoteForwardTarget{Host: record.ForwardTarget, Port: record.Port,
			LocalPort: record.LocalPort, AllowNonLoopback: record.ConfirmedTarget})
		if err != nil {
			item.Err = err.(*core.Error)
		} else {
			item.Forward, item.Created = &forward, created
		}
		restored = append(restored, item)
	}
	return restored, nil
}

// remoteTestRecordsFile is the port records document under the harness's preference directory.
func remoteTestRecordsFile(h *harness) string {
	return filepath.Join(h.store.Dir(), filepath.FromSlash(remoteTestRecordsStorage.RelativePath))
}

// remoteTestRecordsOnDisk is the one workspace's records the document on disk holds.
func remoteTestRecordsOnDisk(t *testing.T, h *harness) core.RemotePortRecords {
	t.Helper()
	data, err := os.ReadFile(remoteTestRecordsFile(h))
	if errors.Is(err, fs.ErrNotExist) {
		return core.RemotePortRecords{}
	}
	if err != nil {
		t.Fatal(err)
	}
	all := map[string]core.RemotePortRecords{}
	if err := json.Unmarshal(data, &all); err != nil || len(all) != 1 {
		t.Fatalf("the document holds %d workspaces, want one", len(all))
	}
	for _, records := range all {
		return records
	}
	return core.RemotePortRecords{}
}

// labelRemotePort types label into the label dialog of target and saves it.
func (h *harness) labelRemotePort(t *testing.T, p *project, target remotePortLabelTarget, label string) {
	t.Helper()
	ports := &p.remote.ports
	h.app.editRemotePortLabel(p, target, surfaceContextMenu)
	h.redraw()
	if !ports.labelOpen || !h.shows(i18n.Shared(h.app.language(), "desktop.remote.ports.labelTitle")) {
		t.Fatal("the label dialog did not open")
	}
	ports.labelField.SetText(label)
	h.redraw()
	h.click(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.remote.ports.labelApply"))))
	h.settle()
}

// awaitRemotePortRecords waits until no reading or write of the records runs.
func (h *harness) awaitRemotePortRecords(p *project) {
	h.await("the port records", func() bool { return !p.remote.ports.recordsBusy })
	h.settle()
}

// The window remembers the labels, the local forwards left running and the rules of a workspace:
// they are written to the document under the preference directory as they change, and the
// workspace opened again lists them, starts the forward again and lists the rule with Start, which
// fills in Add Forwarding Rule. A label Core would refuse is refused in the dialog, an empty label
// forgets the row's, and the log names neither the host nor a label.
func TestRemotePortsRememberLabelsForwardsAndRulesWhenTheWorkspaceOpensAgain(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080},
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 9090})
	ports := &p.remote.ports
	web := remotePortKey{port: 8080}
	h.click(center(h.portRowControl("127.0.0.1:8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()

	h.app.editRemotePortLabel(p, remotePortLabelTarget{key: &web}, surfaceContextMenu)
	ports.labelField.SetText("web\tfrontend")
	h.redraw()
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.labelApply"))))
	h.settle()
	if !ports.labelInvalid || !ports.labelOpen || !h.shows(i18n.Shared(lang, "desktop.remote.ports.labelInvalid")) ||
		!rejected(logger, "remote_port_label", "invalid_label") {
		t.Fatal("a label with a tab was not refused in the dialog")
	}
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.labelCancel"))))
	h.settle()
	h.labelRemotePort(t, p, remotePortLabelTarget{key: &web}, "  Web UI  ")
	h.labelRemotePort(t, p, remotePortLabelTarget{key: &remotePortKey{port: 9090}}, "metrics")

	h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "15432", "5432")
	rule := remotePortRuleOf(ports.rules()[0])
	h.labelRemotePort(t, p, remotePortLabelTarget{rule: &rule}, "Database")
	h.awaitRemotePortRecords(p)
	if !h.shows("Web UI") || !h.shows("Database") {
		t.Fatal("the labels are not shown")
	}
	disk := remoteTestRecordsOnDisk(t, h)
	if len(disk.Ports) != 2 || disk.Ports[0].Label != "Web UI" || disk.Ports[0].ForwardTarget == "" || disk.Ports[1].Label != "metrics" ||
		len(disk.Rules) != 1 || disk.Rules[0].Label != "Database" || disk.Rules[0].ListenPort != 15432 || disk.Rules[0].TargetPort != 5432 {
		t.Fatalf("the document remembers %d rows and %d rules, want the labels, the forward and the rule", len(disk.Ports), len(disk.Rules))
	}

	h.rightClickAt(h.portRowControl("127.0.0.1:9090", "127.0.0.1:9090"))
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.editLabel"))))
	h.settle()
	if ports.labelField.Text() != "metrics" {
		t.Fatal("Edit Label does not start from the row's label")
	}
	ports.labelField.SetText("")
	h.redraw()
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.labelApply"))))
	h.settle()
	h.awaitRemotePortRecords(p)
	if disk := remoteTestRecordsOnDisk(t, h); len(disk.Ports) != 1 || h.shows("metrics") {
		t.Fatal("an empty label did not forget the row's label")
	}

	h.app.closeProject()
	h.awaitClosed(t)
	h.app.openRemote(surfaceMenu)
	h.settle()
	h.settle()
	p = h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	ports = &p.remote.ports
	h.awaitRemotePortRecords(p)
	if ports.labels[web] != "Web UI" || !h.shows("Web UI") || !h.shows("Database") {
		t.Fatal("the workspace opened again does not show the labels")
	}
	if !slices.ContainsFunc(ports.forwards, func(forward core.RemoteForward) bool {
		return forward.Kind != core.RemoteForwardHost && forward.TargetPort == 8080
	}) {
		t.Fatal("the forward left running did not start again")
	}
	if idle := ports.idleRules(); len(idle) != 1 || len(ports.rules()) != 0 || !h.shows(i18n.Shared(lang, "desktop.remote.ports.statusNotRunning")) {
		t.Fatal("the rule is not listed as remembered, or started without the user")
	}
	started := len(k.ports.rules.hostStarts)
	h.click(center(h.portRowControl("127.0.0.1:15432", i18n.Shared(lang, "desktop.remote.ports.ruleStart"))))
	h.settle()
	h.settle()
	if ports.rule == nil || ports.rule.listen.Text() != "15432" || ports.rule.target.Text() != "localhost:5432" || len(k.ports.rules.hostStarts) != started {
		t.Fatal("Start did not fill in Add Forwarding Rule with the rule, or started it at once")
	}
	draft := ports.rule
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.ruleSubmit"))))
	h.awaitRemotePortRule(p, draft)
	h.awaitRemotePortRecords(p)
	if len(ports.rules()) != 1 || len(ports.idleRules()) != 0 || len(remoteTestRecordsOnDisk(t, h).Rules) != 1 {
		t.Fatal("the started rule is listed twice or remembered twice")
	}

	actions := remoteActions(logger)
	for _, action := range []string{"remote.ports.label", "remote.ports.ruleStart"} {
		if !slices.Contains(actions, action) {
			t.Fatalf("performed %q, want %s", actions, action)
		}
	}
	if event := loggedAny(t, logger, remoteTestHost, "Web UI", "Database", "metrics", "15432"); event != "" {
		t.Fatalf("logged the host, a label or a port: %s", event)
	}
}

// A forward that does not start again after a reconnect is shown failed with Core's reason and
// forgotten, and the window says how many did not start.
func TestRemotePortsShowTheForwardsThatDidNotStartAgain(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	r := p.remote
	h.click(center(h.portRowControl("127.0.0.1:8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward", func() bool { return len(r.ports.forwards) == 1 && len(r.ports.busy) == 0 })
	h.awaitRemotePortRecords(p)

	k.set(func(k *remoteHostKernel) {
		k.ports.records.failRestore = map[uint16]bool{8080: true}
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fireAfter(t, timers, remoteHeartbeatInterval)
	h.fireReconnect(t, timers, r)
	h.await("the new session's reading", func() bool {
		return r.session == "session-2" && !r.beating && r.ports.listed && !p.tree.reading && !r.ports.recordsBusy
	})
	h.settle()
	notice := i18n.SharedFormat(lang, "desktop.remote.ports.restoreFailed", map[string]string{"count": "1"})
	failed := i18n.SharedFormat(lang, "desktop.remote.ports.statusFailed", map[string]string{"reason": "too many forwards"})
	if len(r.ports.forwards) != 0 || r.ports.notice != notice || !h.showsWrapped(notice) || !h.shows(failed) {
		t.Fatal("the forward that did not start again is not shown failed")
	}
	if got := countFailures(logger, "remote_port_restore"); got != 1 {
		t.Fatalf("remote_port_restore failed %d times, want once", got)
	}
	h.awaitRemotePortRecords(p)
	if disk := remoteTestRecordsOnDisk(t, h); len(disk.Ports) != 0 {
		t.Fatal("the forward that did not start is still remembered as running")
	}
}

// A document Core cannot decode is never overwritten: the window says so, keeps what the user
// changes in memory only, and leaves the file's bytes as they were.
func TestRemotePortsNeverOverwriteADamagedDocument(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	damaged := []byte("{not json")
	if err := os.MkdirAll(filepath.Dir(remoteTestRecordsFile(h)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(remoteTestRecordsFile(h), damaged, 0o600); err != nil {
		t.Fatal(err)
	}
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	ports := &p.remote.ports
	h.awaitRemotePortRecords(p)
	notice := i18n.Shared(lang, "desktop.remote.ports.recordsDamaged")
	if ports.notice != notice || !h.showsWrapped(notice) || countFailures(logger, "remote_port_records") != 1 {
		t.Fatal("the damaged document is not reported")
	}
	h.labelRemotePort(t, p, remotePortLabelTarget{key: &remotePortKey{port: 8080}}, "web")
	h.click(center(h.portRowControl("127.0.0.1:8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.awaitRemotePortRecords(p)
	if data, err := os.ReadFile(remoteTestRecordsFile(h)); err != nil || string(data) != string(damaged) || !h.shows("web") {
		t.Fatal("the damaged document was overwritten, or the label was not kept in memory")
	}
}
