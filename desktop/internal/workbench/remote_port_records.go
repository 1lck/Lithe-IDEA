package workbench

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
)

// This file is what the Ports window of a remote workspace remembers after the workspace closes or
// its connection drops (#2231 R1 #46b): the ports the user added, the labels and local ports chosen
// for rows, the local forwards left running and the forwarding rules the user started on the host.
// It lives in the port records document of remoteconn (remote/ports.json under the platform
// preference directory), where Core keys it by the connection's target and the workspace's real
// path on the host, so another host, account, container or folder never sees it.
//
//   - The window keeps the records in memory and writes only the rows and rules that differ from
//     what Core last reported for the document, one edit at a time, each against the bytes it read.
//   - Every attach of a session, a reconnect or the workspace opened again, first reads the
//     records and then has Core start again the local forwards left running, each with the
//     confirmation it had (S28), as VS Code restores its forwarded ports. A forward that does not
//     start is shown as failed and forgotten.
//   - Rules are remembered but never started on their own: a remembered rule that does not run is
//     listed with Start, which opens Add Forwarding Rule filled in with it, so every question is
//     asked again; listening on every interface of the host is never remembered.
//   - A document Core cannot decode is never overwritten: the window says so and keeps its records
//     in memory only. Without a preference directory nothing is kept.
//
// The log names the outcome only, never an address, a label or a URL.

const (
	// remotePortRecordsTimeout bounds one reading, write or restore of the records.
	remotePortRecordsTimeout = 30 * time.Second
	// remotePortRecordsRetries is how often an edit is read and applied again when another window
	// changed the document meanwhile.
	remotePortRecordsRetries = 3
	// remotePortLabelMax is the longest label Core keeps, in characters.
	remotePortLabelMax = 64
)

// remotePortRunning is a local forward the user started for a row and did not stop: the target
// host it reaches, and whether the user confirmed that target outside the host's loopback
// interface (S28).
type remotePortRunning struct {
	host      string
	confirmed bool
}

// remotePortLabelTarget is what the label dialog names: a row of the list, or a rule.
type remotePortLabelTarget struct {
	key  *remotePortKey
	rule *core.RemotePortRule
}

// remotePortRecordPath is the path a record keeps of a URL's: without its query and fragment,
// which may carry a token, and "" when nothing but / remains, as Core keeps it.
func remotePortRecordPath(path string) string {
	if at := strings.IndexAny(path, "?#"); at >= 0 {
		path = path[:at]
	}
	if path == "/" {
		return ""
	}
	return path
}

// record is what the window remembers of row key.
func (ports *remotePorts) record(key remotePortKey) core.RemotePortRecord {
	record := core.RemotePortRecord{Host: key.host, Port: key.port, Label: ports.labels[key], LocalPort: ports.localPorts[key]}
	for _, added := range ports.manual {
		if added.key == key {
			record.Added = &core.RemotePortRecordAdded{Host: added.host, Scheme: added.scheme, Path: remotePortRecordPath(added.path)}
		}
	}
	if running, ok := ports.running[key]; ok {
		record.ForwardTarget, record.ConfirmedTarget = running.host, running.confirmed
	}
	return record
}

// blankRemotePortRecord reports a record with nothing but its key, which Core removes.
func blankRemotePortRecord(record core.RemotePortRecord) bool {
	return record.Added == nil && record.Label == "" && record.LocalPort == 0 && record.ForwardTarget == ""
}

// sameRemotePortRecord reports two records that remember the same.
func sameRemotePortRecord(x, y core.RemotePortRecord) bool {
	if (x.Added == nil) != (y.Added == nil) || (x.Added != nil && *x.Added != *y.Added) {
		return false
	}
	x.Added, y.Added = nil, nil
	return x == y
}

// canonicalRuleHost is a rule's target host as two rules compare it: an IP address in canonical
// form, any other name in lower case.
func canonicalRuleHost(host string) string {
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap().String()
	}
	return strings.ToLower(host)
}

// sameRemotePortRule reports the same rule, whatever the labels.
func sameRemotePortRule(x, y core.RemotePortRule) bool {
	return x.Kind == y.Kind && x.ListenPort == y.ListenPort && x.TargetPort == y.TargetPort && x.LocalPort == y.LocalPort &&
		canonicalRuleHost(x.TargetHost) == canonicalRuleHost(y.TargetHost)
}

// remotePortRuleOf is the rule a running host or reverse forward was started as.
func remotePortRuleOf(forward core.RemoteForward) core.RemotePortRule {
	rule := core.RemotePortRule{Kind: forward.Kind}
	if forward.RequestedHostPort != nil {
		rule.ListenPort = *forward.RequestedHostPort
	}
	if forward.Kind == core.RemoteForwardReverse {
		rule.LocalPort = forward.LocalPort
	} else {
		rule.TargetHost, rule.TargetPort = forward.TargetHost, forward.TargetPort
	}
	return rule
}

// rememberedRule is the remembered rule that is the same as rule, and whether there is one.
func (ports *remotePorts) rememberedRule(rule core.RemotePortRule) (int, bool) {
	at := slices.IndexFunc(ports.remembered, func(remembered core.RemotePortRule) bool { return sameRemotePortRule(remembered, rule) })
	return at, at >= 0
}

// idleRules are the remembered rules no forward of the session runs, in the order they were added.
func (ports *remotePorts) idleRules() []core.RemotePortRule {
	var idle []core.RemotePortRule
	for _, rule := range ports.remembered {
		if !slices.ContainsFunc(ports.rules(), func(forward core.RemoteForward) bool { return sameRemotePortRule(remotePortRuleOf(forward), rule) }) {
			idle = append(idle, rule)
		}
	}
	return idle
}

// setRunning records the local forward of row key as running to running, or as stopped for nil.
func (ports *remotePorts) setRunning(key remotePortKey, running *remotePortRunning) {
	if running == nil {
		delete(ports.running, key)
		return
	}
	if ports.running == nil {
		ports.running = map[remotePortKey]remotePortRunning{}
	}
	ports.running[key] = *running
}

// recordEdits are the edits that bring the document to what the window remembers: one per row and
// rule that differs from what Core last reported. There are none before the records were read.
func (ports *remotePorts) recordEdits() []core.RemotePortRecordEdit {
	if ports.written == nil {
		return nil
	}
	written := map[remotePortKey]core.RemotePortRecord{}
	keys := map[remotePortKey]bool{}
	for _, record := range ports.written.Ports {
		key := remotePortKey{host: remotePortHost(record.Host), port: record.Port}
		written[key], keys[key] = record, true
	}
	for _, added := range ports.manual {
		keys[added.key] = true
	}
	for key := range ports.labels {
		keys[key] = true
	}
	for key := range ports.localPorts {
		keys[key] = true
	}
	for key := range ports.running {
		keys[key] = true
	}
	sorted := make([]remotePortKey, 0, len(keys))
	for key := range keys {
		sorted = append(sorted, key)
	}
	slices.SortFunc(sorted, func(x, y remotePortKey) int {
		if x.port != y.port {
			return int(x.port) - int(y.port)
		}
		return strings.Compare(x.host, y.host)
	})
	var edits []core.RemotePortRecordEdit
	for _, key := range sorted {
		want := ports.record(key)
		have, had := written[key]
		if (!had && blankRemotePortRecord(want)) || (had && sameRemotePortRecord(have, want)) {
			continue
		}
		edits = append(edits, core.RemotePortRecordEdit{Port: &want})
	}
	for _, rule := range ports.remembered {
		at := slices.IndexFunc(ports.written.Rules, func(have core.RemotePortRule) bool { return sameRemotePortRule(have, rule) })
		if at < 0 || ports.written.Rules[at].Label != rule.Label {
			edits = append(edits, core.RemotePortRecordEdit{Rule: &rule})
		}
	}
	for _, rule := range ports.written.Rules {
		if _, kept := ports.rememberedRule(rule); !kept {
			edits = append(edits, core.RemotePortRecordEdit{RemoveRule: &rule})
		}
	}
	return edits
}

// merge takes in the records read when the workspace opened, filling only what the window does
// not remember yet.
func (ports *remotePorts) merge(records core.RemotePortRecords) {
	for _, record := range records.Ports {
		key := remotePortKey{host: remotePortHost(record.Host), port: record.Port}
		if record.Added != nil && !slices.ContainsFunc(ports.manual, func(added remotePortAdded) bool { return added.key == key }) {
			ports.manual = append(ports.manual, remotePortAdded{key: key, host: record.Added.Host, scheme: record.Added.Scheme, path: record.Added.Path})
		}
		if _, known := ports.labels[key]; record.Label != "" && !known {
			if ports.labels == nil {
				ports.labels = map[remotePortKey]string{}
			}
			ports.labels[key] = record.Label
		}
		if _, known := ports.localPorts[key]; record.LocalPort != 0 && !known {
			if ports.localPorts == nil {
				ports.localPorts = map[remotePortKey]uint16{}
			}
			ports.localPorts[key] = record.LocalPort
		}
		if _, known := ports.running[key]; record.ForwardTarget != "" && !known {
			ports.setRunning(key, &remotePortRunning{host: record.ForwardTarget, confirmed: record.ConfirmedTarget})
		}
	}
	for _, rule := range records.Rules {
		if _, known := ports.rememberedRule(rule); !known {
			ports.remembered = append(ports.remembered, rule)
		}
	}
}

// writeRemotePortEdits applies edits in order to the port records under root, each against the
// bytes it read, and reads again when another window changed the document meanwhile. after is
// what Core reported after the last edit applied, nil when none was; it stops at the first edit
// that fails. It runs off the window thread.
func writeRemotePortEdits(ctx context.Context, kernel remoteconn.PortsKernel, root, session, workspace string, edits []core.RemotePortRecordEdit) (*core.RemotePortRecords, error) {
	var after *core.RemotePortRecords
	for _, edit := range edits {
		for attempt := 1; ; attempt++ {
			records, err := remoteconn.ReadPortRecords(ctx, kernel, root, session, workspace)
			if err == nil {
				var updated core.RemotePortRecords
				if updated, _, err = records.Edit(ctx, kernel, edit); err == nil {
					after = &updated
					break
				}
			}
			if errors.Is(err, remoteconn.ErrConflict) && attempt < remotePortRecordsRetries {
				continue
			}
			return after, err
		}
	}
	return after, nil
}

// remotePortsChanged records that what the window remembers changed, and writes it.
func (a *App) remotePortsChanged(p *project) {
	if p.remote == nil {
		return
	}
	p.remote.ports.recordsRevision++
	a.syncRemotePorts(p)
}

// syncRemotePorts reads the records and restores the forwards once a session attached, or writes
// what changed since Core last reported the records. One runs at a time; the one that ends starts
// the next.
func (a *App) syncRemotePorts(p *project) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.recordsBusy {
		// log-exempt: 非用户操作：没有会话或上一次记录读写还在进行，它结束时会再同步。
		return
	}
	ports := &r.ports
	if ports.recordsAttach {
		ports.recordsAttach = false
		a.restoreRemotePorts(p)
		return
	}
	edits := ports.recordEdits()
	if len(edits) == 0 {
		return
	}
	ports.recordsBusy = true
	revision := ports.recordsRevision
	session, kernel, root, workspace := r.session, a.kernel, a.globalToolchainRoot(), r.binding.RemoteRoot()
	a.background(p, remotePortRecordsTimeout, func(ctx context.Context) func(*App) {
		after, err := writeRemotePortEdits(ctx, kernel, root, session, workspace, edits)
		return func(a *App) {
			ports.recordsBusy = false
			if r.closed {
				// log-exempt: 用户取消：工作区已关闭，写入结果不再显示。
				return
			}
			a.remotePortsWritten(p, session, after, err)
			// Only a change made meanwhile or a new session writes again, so an edit Core keeps
			// differently from the window never loops.
			if ports.recordsRevision != revision || ports.recordsAttach {
				a.syncRemotePorts(p)
			}
		}
	})
}

// remotePortsWritten records how writing the records over session ended: after is what Core
// reported after the last edit applied, nil when none was.
func (a *App) remotePortsWritten(p *project, session string, after *core.RemotePortRecords, err error) {
	r := p.remote
	ports := &r.ports
	if after != nil {
		ports.written = after
	}
	switch {
	case err == nil:
	case errors.Is(err, remoteconn.ErrUnavailable):
		// log-exempt: 非用户操作：没有用户偏好目录，端口记录只留在内存里，与远程偏好相同。
		ports.written = nil
	case remoteConnectionClosed(err):
		if r.session == session {
			a.loseRemote(p, session, err)
		}
	default:
		a.backgroundFailed("remote_port_records", remoteLogError(err))
		ports.notice = a.remotePortRecordsNotice(err)
		if errors.Is(err, remoteconn.ErrDamaged) {
			// A document Core cannot decode is never overwritten.
			ports.written = nil
		}
	}
}

// remotePortRecordsNotice is the window's message about records that could not be read or kept.
func (a *App) remotePortRecordsNotice(err error) string {
	if errors.Is(err, remoteconn.ErrDamaged) {
		return i18n.Shared(a.language(), "desktop.remote.ports.recordsDamaged")
	}
	return i18n.SharedFormat(a.language(), "desktop.remote.ports.recordsFailed", map[string]string{"reason": remotePortsReason(err)})
}

// restoreRemotePorts runs once a session attached: it writes what changed while there was none,
// reads the records — taking them in when the workspace has just opened — and has Core start again
// the local forwards left running.
func (a *App) restoreRemotePorts(p *project) {
	r := p.remote
	ports := &r.ports
	ports.recordsBusy = true
	edits := ports.recordEdits()
	session, kernel, root, workspace := r.session, a.kernel, a.globalToolchainRoot(), r.binding.RemoteRoot()
	a.background(p, remotePortRecordsTimeout, func(ctx context.Context) func(*App) {
		after, writeErr := writeRemotePortEdits(ctx, kernel, root, session, workspace, edits)
		var state remoteconn.PortRecords
		var readErr, restoreErr error
		var restored []core.RemoteRestoredForward
		if writeErr == nil || !remoteConnectionClosed(writeErr) {
			if state, readErr = remoteconn.ReadPortRecords(ctx, kernel, root, session, workspace); readErr == nil {
				restored, restoreErr = state.Restore(ctx, kernel)
			}
		}
		return func(a *App) {
			ports.recordsBusy = false
			if r.closed {
				// log-exempt: 用户取消：工作区已关闭，读到的记录和恢复的转发不再显示，Core 已随会话停止转发。
				return
			}
			if len(edits) > 0 {
				a.remotePortsWritten(p, session, after, writeErr)
			}
			if r.session != session {
				// log-exempt: 非用户操作：会话已换，新会话接上时会重新读取并恢复。
				a.syncRemotePorts(p)
				return
			}
			if readErr == nil {
				records := state.State.Records
				if ports.written == nil {
					ports.merge(records)
				}
				ports.written = &records
			}
			if writeErr == nil || !remoteConnectionClosed(writeErr) {
				a.remotePortsRestored(p, session, readErr, restored, restoreErr)
			}
			a.syncRemotePorts(p)
		}
	})
}

// remotePortsRestored records how reading the records and restoring the forwards over session
// ended. A forward that did not start is shown as failed and forgotten.
func (a *App) remotePortsRestored(p *project, session string, readErr error, restored []core.RemoteRestoredForward, restoreErr error) {
	ports := &p.remote.ports
	err := readErr
	if err == nil {
		err = restoreErr
	}
	switch {
	case err == nil:
	case errors.Is(err, remoteconn.ErrUnavailable):
		// log-exempt: 非用户操作：没有用户偏好目录，没有可恢复的记录。
		return
	case remoteConnectionClosed(err):
		a.loseRemote(p, session, err)
		return
	default:
		a.backgroundFailed("remote_port_records", remoteLogError(err))
		ports.notice = a.remotePortRecordsNotice(err)
		return
	}
	var failed *core.Error
	count := 0
	for _, item := range restored {
		key := remotePortKey{host: remotePortHost(item.Host), port: item.Port}
		if item.Forward != nil {
			ports.putForward(*item.Forward)
			ports.setRunning(forwardKey(*item.Forward), &remotePortRunning{host: item.Forward.TargetHost, confirmed: !item.Forward.LoopbackTarget})
			ports.setFailed(key, "")
			continue
		}
		count++
		if failed == nil {
			failed = item.Err
		}
		ports.setRunning(key, nil)
		reason := item.Err.Message
		if item.Err.Code == core.CodeInvalidRequest || reason == "" {
			reason = i18n.Shared(a.language(), "desktop.remote.ports.invalidTarget")
		}
		ports.setFailed(key, reason)
	}
	if count > 0 {
		a.backgroundFailed("remote_port_restore", remoteLogError(failed))
		ports.notice = i18n.SharedFormat(a.language(), "desktop.remote.ports.restoreFailed", map[string]string{"count": strconv.Itoa(count)})
	}
}

// remotePortRuleRecord is the rule the dialog started, as the window remembers it: never with the
// choice to listen on every interface of the host.
func remotePortRuleRecord(kind remotePortRuleKind, host core.RemoteHostForwardRule, reverse core.RemoteReverseForwardRule) core.RemotePortRule {
	if kind == remotePortRuleReverse {
		return core.RemotePortRule{Kind: core.RemoteForwardReverse, ListenPort: reverse.ListenPort, LocalPort: reverse.LocalPort}
	}
	return core.RemotePortRule{Kind: core.RemoteForwardHost, ListenPort: host.ListenPort, TargetHost: host.Host, TargetPort: host.Port}
}

// rememberRemotePortRule remembers a rule that started, keeping the label of the same rule.
func (a *App) rememberRemotePortRule(p *project, rule core.RemotePortRule) {
	ports := &p.remote.ports
	if _, known := ports.rememberedRule(rule); known {
		return
	}
	ports.remembered = append(ports.remembered, rule)
	a.remotePortsChanged(p)
}

// forgetRemotePortRule forgets a remembered rule; a running one keeps running until it stops.
func (a *App) forgetRemotePortRule(p *project, rule core.RemotePortRule, surface actionSurface) {
	ports := &p.remote.ports
	at, known := ports.rememberedRule(rule)
	if !known {
		// log-exempt: 非用户操作：这条规则已被忘记，菜单项此时不显示。
		return
	}
	a.performed("remote.ports.ruleForget", surface)
	ports.remembered = slices.Delete(ports.remembered, at, at+1)
	a.remotePortsChanged(p)
}

// startRememberedRule opens Add Forwarding Rule filled in with a remembered rule.
func (a *App) startRememberedRule(p *project, rule core.RemotePortRule, surface actionSurface) {
	a.openRemotePortRule(p, &rule, surface)
}

// remotePortRuleDraftOf fills a new dialog with rule: its direction, host port and what it
// reaches. Listening on every interface is never filled in.
func remotePortRuleDraftOf(rule core.RemotePortRule) *remotePortRuleDraft {
	draft := &remotePortRuleDraft{}
	if rule.ListenPort != 0 {
		draft.listen.SetText(strconv.Itoa(int(rule.ListenPort)))
	}
	if rule.Kind == core.RemoteForwardReverse {
		draft.kind = remotePortRuleReverse
		draft.target.SetText(strconv.Itoa(int(rule.LocalPort)))
		return draft
	}
	draft.target.SetText(net.JoinHostPort(rule.TargetHost, strconv.Itoa(int(rule.TargetPort))))
	return draft
}

// labelOf is the label of what target names, "" for none.
func (ports *remotePorts) labelOf(target remotePortLabelTarget) string {
	if target.key != nil {
		return ports.labels[*target.key]
	}
	if at, known := ports.rememberedRule(*target.rule); known {
		return ports.remembered[at].Label
	}
	return ""
}

// ruleLabel is the label of the rule a running forward was started as, "" for none.
func (ports *remotePorts) ruleLabel(forward core.RemoteForward) string {
	rule := remotePortRuleOf(forward)
	return ports.labelOf(remotePortLabelTarget{rule: &rule})
}

// editRemotePortLabel opens the dialog the label of a row or a rule is typed in.
func (a *App) editRemotePortLabel(p *project, target remotePortLabelTarget, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed {
		// log-exempt: 非用户操作：工作区已关闭，菜单项此时不可用。
		return
	}
	a.performed("remote.ports.label", surface)
	ports := &r.ports
	ports.label, ports.labelOpen, ports.labelInvalid = &target, true, false
	ports.labelField.SetText(ports.labelOf(target))
}

// validRemotePortLabel reports a label Core keeps: at most remotePortLabelMax characters and no
// control character.
func validRemotePortLabel(label string) bool {
	return utf8.RuneCountInString(label) <= remotePortLabelMax && !strings.ContainsFunc(label, unicode.IsControl)
}

// applyRemotePortLabel gives the dialog's label to its row or rule; an empty one removes it.
func (a *App) applyRemotePortLabel(p *project) {
	ports := &p.remote.ports
	target := ports.label
	if target == nil {
		// log-exempt: 非用户操作：标签对话框已关闭，没有要改的标签。
		return
	}
	label := strings.TrimSpace(ports.labelField.Text())
	if !validRemotePortLabel(label) {
		a.operationRejected("remote_port_label", "invalid_label")
		ports.labelInvalid = true
		return
	}
	ports.label, ports.labelOpen, ports.labelInvalid = nil, false, false
	switch {
	case target.key != nil && label == "":
		delete(ports.labels, *target.key)
	case target.key != nil:
		if ports.labels == nil {
			ports.labels = map[remotePortKey]string{}
		}
		ports.labels[*target.key] = label
	default:
		rule := *target.rule
		rule.Label = label
		if at, known := ports.rememberedRule(rule); known {
			ports.remembered[at].Label = label
		} else {
			ports.remembered = append(ports.remembered, rule)
		}
	}
	a.remotePortsChanged(p)
}
