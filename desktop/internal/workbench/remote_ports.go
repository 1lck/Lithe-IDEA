package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/ui"
)

// This file is the Ports tool window of a remote workspace (#2231 R1): the TCP ports listening on
// the host, the ports the user added by hand, and the forwards Core runs to them over the
// workspace's session. Nothing is forwarded until the user asks: the window only lists the ports,
// and the user chooses which to forward and on which local port. A forward listens on this
// computer's loopback address only (S27), and the host never reaches back through it (S29); a
// target outside the host's loopback interface is forwarded only after the user confirms it (S28).
// Forwards belong to the session: when it ends, Core stops them, and the window shows the ports
// unforwarded until the next session attaches and the forwards left running start again
// (remote_port_records.go, which also keeps the ports added, labels and local ports across reopens).
//
// A port is added by typing it alone, as host:port or as a URL; Core reads the address
// (remote.parseForwardAddress), and the row keeps a URL's scheme and path, to show the row as typed
// and to open and copy the forwarded address the same way. Each row shows the address the host
// serves the port on, its IP address included.
//
// The window reads the host's listening ports and the session's forwards while it is shown, every
// remotePortsInterval, and stops reading once it is hidden; nothing reads them in the background.

const (
	// remotePortsInterval is the pause between two readings of the shown window.
	remotePortsInterval = 3 * time.Second
	// remotePortsTimeout bounds one reading, and one start or stop of a forward.
	remotePortsTimeout = 15 * time.Second
)

// remotePortKey names a row of the window: a port of the host's own loopback address, which a
// server listening on every interface also serves, has host ""; a port bound to one other address
// of the host, another loopback address such as 127.0.0.2 included, has that address.
type remotePortKey struct {
	host string
	port uint16
}

// remotePortHost is the row host of address, as remotePortKey keeps it: "" for localhost,
// 127.0.0.1, ::1 and the every-interface addresses, the canonical text of any other IP address,
// and any other name in lower case.
func remotePortHost(address string) string {
	address = strings.TrimSuffix(strings.TrimPrefix(address, "["), "]")
	if ip, err := netip.ParseAddr(address); err == nil {
		ip = ip.Unmap()
		if ip.IsUnspecified() || ip == netip.AddrFrom4([4]byte{127, 0, 0, 1}) || ip == netip.IPv6Loopback() {
			return ""
		}
		return ip.String()
	}
	address = strings.ToLower(address)
	if address == "localhost" {
		return ""
	}
	return address
}

// forwardKey is the row of forward, by the target Core forwards to.
func forwardKey(forward core.RemoteForward) remotePortKey {
	return remotePortKey{host: remotePortHost(forward.TargetHost), port: forward.TargetPort}
}

// remotePortAdded is a port the user added, as Core read the address typed: host is the host as
// typed, localhost for a port alone, and scheme and path are the URL's, "" for an address that is
// not a URL and for a URL without a path. The same row typed again replaces them.
type remotePortAdded struct {
	key    remotePortKey
	host   string
	scheme string
	path   string
}

// remotePortRow is one row of the window.
type remotePortRow struct {
	key remotePortKey
	// listening holds the host's listening sockets of the row, empty for a port that only the
	// user added.
	listening []core.RemoteListeningPort
	// added is the address the user added the port with, nil for a port the user did not add.
	added *remotePortAdded
	// forward is the row's running forward, nil while there is none.
	forward *core.RemoteForward
}

// target is the host the row's forward is started to: the row's own address, or the loopback
// address of the family the host's server listens on, or the host typed for a port added by hand,
// or the target of the row's running forward.
func (row remotePortRow) target() string {
	if row.key.host != "" {
		return row.key.host
	}
	for _, port := range row.listening {
		if ip, err := netip.ParseAddr(port.Address); err == nil && ip.Unmap().Is4() {
			return "127.0.0.1"
		}
	}
	switch {
	case len(row.listening) > 0:
		return "::1"
	case row.added != nil:
		return row.added.host
	case row.forward != nil:
		return row.forward.TargetHost
	}
	return "localhost"
}

// addresses are the distinct addresses the host listens on for the row, as address:port, IPv4
// first and otherwise in the host's order.
func (row remotePortRow) addresses() []string {
	var v4, v6 []string
	port := strconv.Itoa(int(row.key.port))
	for _, listening := range row.listening {
		address := net.JoinHostPort(listening.Address, port)
		if slices.Contains(v4, address) || slices.Contains(v6, address) {
			continue
		}
		if ip, err := netip.ParseAddr(listening.Address); err == nil && !ip.Unmap().Is4() {
			v6 = append(v6, address)
		} else {
			v4 = append(v4, address)
		}
	}
	return append(v4, v6...)
}

// url reports whether the user added the row as a URL.
func (row remotePortRow) url() bool {
	return row.added != nil && row.added.scheme != ""
}

// browserURL is the address Open in Browser opens for the row's forward: the URL the user added,
// with this computer's local address in place of the host's, or http on the local address. ok is
// false for a row without a forward and for a URL a browser does not open, such as ws or postgres.
func (row remotePortRow) browserURL() (url string, ok bool) {
	if row.forward == nil {
		return "", false
	}
	if !row.url() {
		return "http://" + remotePortAddress(*row.forward), true
	}
	if row.added.scheme != "http" && row.added.scheme != "https" {
		return "", false
	}
	return row.added.scheme + "://" + remotePortAddress(*row.forward) + row.added.path, true
}

// copyText is what Copy Local Address copies for the row's forward: the URL the user added, with
// this computer's local address in place of the host's, or the local address as host:port.
func (row remotePortRow) copyText() string {
	switch {
	case row.forward == nil:
		return ""
	case row.url():
		return row.added.scheme + "://" + remotePortAddress(*row.forward) + row.added.path
	}
	return remotePortAddress(*row.forward)
}

// remotePortsBusy is what runs for a row.
type remotePortsBusy int

const (
	remotePortForwarding remotePortsBusy = iota + 1
	remotePortStopping
)

// remotePortConfirm is a forward that waits for the user to confirm its target (S28).
type remotePortConfirm struct {
	key  remotePortKey
	host string
}

// remotePorts is the state of the Ports window of a remote workspace (remoteProject.ports).
type remotePorts struct {
	// listening is the host's last listing of its listening ports; listed is set once one arrived
	// over the current session. readFailed is why the last reading failed, "" when it did not.
	listening  []core.RemoteListeningPort
	listed     bool
	readFailed string
	// forwards are the session's running forwards by id.
	forwards []core.RemoteForward
	// manual are the ports the user added, kept while the workspace is open, across sessions.
	manual []remotePortAdded
	// localPorts are the local ports the user chose for rows, kept like manual; a row without one
	// is forwarded on its own port number.
	localPorts map[remotePortKey]uint16
	// local is the row whose local port the user is choosing, nil while none is; localField is the
	// port typed for it, and localInvalid is set when that text is not a port.
	local        *remotePortKey
	localOpen    bool
	localField   ui.Field
	localInvalid bool
	// busy is what runs for a row, and failed why the last start or stop of a row failed.
	busy   map[remotePortKey]remotePortsBusy
	failed map[remotePortKey]string
	// stoppingAll is set while Stop All Forwards runs.
	stoppingAll bool
	// confirm is the forward waiting for the user's confirmation, nil while none does.
	confirm     *remotePortConfirm
	confirmOpen bool
	// notice is the window's message about the last action, such as the forward limit, "" for none.
	notice string
	// add is the field a port is typed into; adding is set while Core reads the address typed, and
	// addRefused is the reason Core refused the last one, "" when it did not.
	add        ui.Field
	adding     bool
	addRefused string
	// reading is set while a reading runs or the next one is scheduled; shown is set each time the
	// window is drawn, so a reading that finds it unset since the last one stops reading. stopTimer
	// stops the scheduled reading; timer tells its callback apart from a later schedule's.
	reading   bool
	shown     bool
	stopTimer func() bool
	timer     uint64
	// rule is the Add Forwarding Rule dialog, nil while it is closed (remote_port_rules.go).
	rule     *remotePortRuleDraft
	ruleOpen bool
	// ruleStopping are the host and reverse rules being stopped, and ruleFailed why the last stop
	// of one failed, by forward id.
	ruleStopping map[uint64]bool
	ruleFailed   map[uint64]string
	// labels are the names the user gave rows, and running the local forwards the user started and
	// did not stop, kept across sessions and in the port records (remote_port_records.go);
	// remembered are the rules the user started, which never start on their own.
	labels     map[remotePortKey]string
	running    map[remotePortKey]remotePortRunning
	remembered []core.RemotePortRule
	// written is what Core last reported of the port records, nil until they were read or when
	// they cannot be kept. recordsBusy is set while a reading or write runs, recordsAttach once a
	// session attached and the forwards wait to be restored, and recordsRevision counts the
	// changes of what the window remembers.
	written         *core.RemotePortRecords
	recordsBusy     bool
	recordsAttach   bool
	recordsRevision uint64
	// label is the row or rule whose label the user is typing, nil while none is; labelField is
	// the label typed, and labelInvalid is set when Core would not keep it.
	label        *remotePortLabelTarget
	labelOpen    bool
	labelField   ui.Field
	labelInvalid bool
}

// reset forgets what belonged to the ended session: its forwards, what ran for them and the
// listing it read. What the window remembers stays: the ports the user added, the labels, local
// ports and remembered rules, and the forwards left running, which the next session restores.
func (ports *remotePorts) reset() {
	ports.stopReading()
	ports.listening, ports.listed, ports.readFailed = nil, false, ""
	ports.forwards = nil
	clear(ports.busy)
	clear(ports.failed)
	ports.stoppingAll = false
	ports.confirm, ports.confirmOpen = nil, false
	ports.local, ports.localOpen, ports.localInvalid = nil, false, false
	ports.notice = ""
	// The rules ended with the session and are never started again on their own.
	ports.rule, ports.ruleOpen = nil, false
	clear(ports.ruleStopping)
	clear(ports.ruleFailed)
}

// localPort is the local port a forward of row key asks for: the one the user chose, or the
// host's port number, so the address reads as it does on the host.
func (ports *remotePorts) localPort(key remotePortKey) uint16 {
	if port := ports.localPorts[key]; port != 0 {
		return port
	}
	return key.port
}

// stopReading stops the scheduled reading; a callback already queued finds its token outdated.
func (ports *remotePorts) stopReading() {
	if ports.stopTimer != nil {
		ports.stopTimer()
		ports.stopTimer = nil
	}
	ports.timer++
	ports.reading = false
}

// rows are the window's rows: the listening ports, the ports added by hand and the local forwards,
// by port and then by address. Host and reverse forwards are listed as rules instead.
func (ports *remotePorts) rows() []remotePortRow {
	index := map[remotePortKey]int{}
	var rows []remotePortRow
	row := func(key remotePortKey) *remotePortRow {
		at, known := index[key]
		if !known {
			at = len(rows)
			index[key] = at
			rows = append(rows, remotePortRow{key: key})
		}
		return &rows[at]
	}
	for _, port := range ports.listening {
		r := row(remotePortKey{host: remotePortHost(port.Address), port: port.Port})
		r.listening = append(r.listening, port)
	}
	for _, added := range ports.manual {
		// A copy: a row outlives a later change of ports.manual in the callbacks it is given to.
		row(added.key).added = &added
	}
	for i := range ports.forwards {
		if !ports.forwards[i].IsLocal() {
			continue
		}
		r := row(forwardKey(ports.forwards[i]))
		if r.forward == nil {
			r.forward = &ports.forwards[i]
		}
	}
	slices.SortFunc(rows, func(x, y remotePortRow) int {
		if x.key.port != y.key.port {
			return int(x.key.port) - int(y.key.port)
		}
		return strings.Compare(x.key.host, y.key.host)
	})
	return rows
}

// row is the window's row key, and whether there is one.
func (ports *remotePorts) row(key remotePortKey) (remotePortRow, bool) {
	for _, row := range ports.rows() {
		if row.key == key {
			return row, true
		}
	}
	return remotePortRow{key: key}, false
}

// putAdded records a port the user added, replacing the address its row was added with before.
func (ports *remotePorts) putAdded(added remotePortAdded) {
	for i := range ports.manual {
		if ports.manual[i].key == added.key {
			ports.manual[i] = added
			return
		}
	}
	ports.manual = append(ports.manual, added)
}

// putForward records forward as running, replacing the one of the same id.
func (ports *remotePorts) putForward(forward core.RemoteForward) {
	for i := range ports.forwards {
		if ports.forwards[i].ID == forward.ID {
			ports.forwards[i] = forward
			return
		}
	}
	ports.forwards = append(ports.forwards, forward)
	slices.SortFunc(ports.forwards, func(x, y core.RemoteForward) int {
		switch {
		case x.ID < y.ID:
			return -1
		case x.ID > y.ID:
			return 1
		}
		return 0
	})
}

// dropForward forgets the forward id.
func (ports *remotePorts) dropForward(id uint64) {
	ports.forwards = slices.DeleteFunc(ports.forwards, func(forward core.RemoteForward) bool { return forward.ID == id })
}

// setBusy records what runs for key, or that nothing does for 0.
func (ports *remotePorts) setBusy(key remotePortKey, busy remotePortsBusy) {
	if busy == 0 {
		delete(ports.busy, key)
		return
	}
	if ports.busy == nil {
		ports.busy = map[remotePortKey]remotePortsBusy{}
	}
	ports.busy[key] = busy
}

// setFailed records why the last action of key failed, or that it did not for "".
func (ports *remotePorts) setFailed(key remotePortKey, reason string) {
	if reason == "" {
		delete(ports.failed, key)
		return
	}
	if ports.failed == nil {
		ports.failed = map[remotePortKey]string{}
	}
	ports.failed[key] = reason
}

// remotePortsReason is the text a failure of the window shows: Core's summary, which is meant for
// the user's diagnostics, or the error's own text.
func remotePortsReason(err error) string {
	var coreErr *core.Error
	if errors.As(err, &coreErr) && coreErr.Message != "" {
		return coreErr.Message
	}
	return err.Error()
}

// remotePortsLimit is the maximum the details of a CodeForwardLimitReached failure carry, or
// fallback when they carry none.
func remotePortsLimit(err error, fallback int) int {
	var coreErr *core.Error
	if !errors.As(err, &coreErr) {
		return fallback
	}
	var details struct {
		Maximum int `json:"maximum"`
	}
	if json.Unmarshal([]byte(coreErr.Details), &details) != nil || details.Maximum <= 0 {
		return fallback
	}
	return details.Maximum
}

// remotePortsCode is the code of a Core failure, "" for any other error.
func remotePortsCode(err error) core.ErrorCode {
	var coreErr *core.Error
	if errors.As(err, &coreErr) {
		return coreErr.Code
	}
	return ""
}

// showRemotePorts is called each time the Ports window of p is drawn: it starts reading while the
// workspace has a session and no reading runs.
func (a *App) showRemotePorts(p *project) {
	r := p.remote
	if r == nil || r.closed {
		return
	}
	r.ports.shown = true
	if r.ports.reading || r.session == "" {
		return
	}
	a.readRemotePorts(p)
}

// readRemotePorts reads the host's listening ports and the session's forwards, and schedules the
// next reading while the window stays shown. A closed connection is lost; another failure is
// shown in the window and logged once until a reading succeeds again.
func (a *App) readRemotePorts(p *project) {
	r := p.remote
	ports := &r.ports
	ports.reading, ports.shown = true, false
	session, kernel := r.session, a.kernel
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		listening, listenErr := kernel.RemoteListeningPorts(ctx, session)
		forwards, forwardsErr := kernel.RemoteForwards(ctx, session)
		return func(a *App) {
			if r.closed || r.session != session || !ports.reading {
				// log-exempt: 用户取消：工作区已关闭、会话已结束或端口读取已停止，这次读取的结果不再适用。
				return
			}
			for _, err := range []error{listenErr, forwardsErr} {
				if err != nil && remoteConnectionClosed(err) {
					a.loseRemote(p, session, err)
					return
				}
			}
			if forwardsErr == nil {
				ports.forwards = forwards
			}
			if listenErr == nil {
				ports.listening, ports.listed = listening, true
			}
			if err := errors.Join(listenErr, forwardsErr); err != nil {
				if ports.readFailed == "" {
					a.backgroundFailed("remote_ports_read", remoteLogError(err))
				}
				ports.readFailed = remotePortsReason(err)
			} else {
				ports.readFailed = ""
			}
			a.scheduleRemotePorts(p)
		}
	})
}

// scheduleRemotePorts reads again after remotePortsInterval if the window is open and was drawn
// meanwhile; it stops reading otherwise, until the window is shown again.
func (a *App) scheduleRemotePorts(p *project) {
	r := p.remote
	ports := &r.ports
	if ports.stopTimer != nil {
		ports.stopTimer()
	}
	ports.timer++
	token := ports.timer
	ports.stopTimer = a.remoteAfterFunc(remotePortsInterval, func() {
		a.post(func(a *App) {
			if a.project != p || r.closed || ports.timer != token {
				return
			}
			ports.stopTimer = nil
			if !ports.shown || r.session == "" || !a.chrome.isOpen(catalogIndex[itemPorts]) {
				ports.reading = false
				return
			}
			a.readRemotePorts(p)
		})
	})
}

// forwardRemotePort starts a forward of row key to host over p's session, on the row's local port
// (remotePorts.localPort); when another program holds it, Core listens on a free port and reports
// the change. confirmed records that the user confirmed a target outside the host's loopback
// interface; without it Core refuses such a target and the window asks.
func (a *App) forwardRemotePort(p *project, key remotePortKey, host string, confirmed bool, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.busy[key] != 0 {
		// log-exempt: 非用户操作：没有会话或这一行已有操作在进行，按钮此时不可用。
		return
	}
	a.performed("remote.ports.forward", surface)
	ports := &r.ports
	ports.setBusy(key, remotePortForwarding)
	ports.setFailed(key, "")
	ports.notice = ""
	session, kernel := r.session, a.kernel
	target := core.RemoteForwardTarget{Host: host, Port: key.port, LocalPort: ports.localPort(key), AllowNonLoopback: confirmed}
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		forward, _, err := kernel.RemoteStartForward(ctx, session, target)
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			ports.setBusy(key, 0)
			a.forwardStarted(p, session, key, host, forward, err)
		}
	})
}

// forwardStarted records how starting the forward of row key to host over session ended.
func (a *App) forwardStarted(p *project, session string, key remotePortKey, host string, forward core.RemoteForward, err error) {
	ports := &p.remote.ports
	switch code := remotePortsCode(err); {
	case err == nil:
		ports.putForward(forward)
		ports.setRunning(forwardKey(forward), &remotePortRunning{host: forward.TargetHost, confirmed: !forward.LoopbackTarget})
		a.remotePortsChanged(p)
		return
	case code == core.CodeConnectionClosed:
		// The forward that ran before stays remembered, so the next session starts it again.
		a.loseRemote(p, session, err)
		return
	case code == core.CodeForwardTargetNotConfirmed:
		a.operationRejected("remote_port_forward", "target_not_confirmed")
		ports.confirm, ports.confirmOpen = &remotePortConfirm{key: key, host: host}, true
	case code == core.CodeForwardLimitReached:
		a.operationFailed("remote_port_forward", remoteLogError(err))
		ports.notice = i18n.SharedFormat(a.language(), "desktop.remote.ports.limit",
			map[string]string{"maximum": strconv.Itoa(remotePortsLimit(err, len(ports.forwards)))})
	case code == core.CodeInvalidRequest:
		a.operationFailed("remote_port_forward", remoteLogError(err))
		ports.setFailed(key, i18n.Shared(a.language(), "desktop.remote.ports.invalidTarget"))
	default:
		a.operationFailed("remote_port_forward", remoteLogError(err))
		ports.setFailed(key, remotePortsReason(err))
	}
	// A forward moved to another local port stopped before its new start failed.
	ports.setRunning(key, nil)
	a.remotePortsChanged(p)
}

// chooseRemoteLocalPort asks for the local port of row key, starting from the one it uses now.
func (a *App) chooseRemoteLocalPort(p *project, key remotePortKey, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.busy[key] != 0 {
		// log-exempt: 非用户操作：没有会话或这一行已有操作在进行，菜单项此时不可用。
		return
	}
	a.performed("remote.ports.localPort", surface)
	ports := &r.ports
	port := ports.localPort(key)
	for _, forward := range ports.forwards {
		if forward.IsLocal() && forwardKey(forward) == key {
			port = forward.LocalPort
			break
		}
	}
	ports.local, ports.localOpen, ports.localInvalid = &key, true, false
	ports.localField.SetText(strconv.Itoa(int(port)))
}

// applyRemoteLocalPort forwards the row whose local port the user chose on the typed port: it
// starts the forward of a row that has none, and moves a running one, which Core keeps on the
// local port it listens on, by stopping it and starting it again. A forward already on that port
// stays as it is.
func (a *App) applyRemoteLocalPort(p *project) {
	ports := &p.remote.ports
	if ports.local == nil {
		return
	}
	key := *ports.local
	n, err := strconv.ParseUint(strings.TrimSpace(ports.localField.Text()), 10, 16)
	if err != nil || n == 0 {
		a.operationRejected("remote_port_local", "invalid_port")
		ports.localInvalid = true
		return
	}
	port := uint16(n)
	ports.local, ports.localOpen, ports.localInvalid = nil, false, false
	if ports.localPorts == nil {
		ports.localPorts = map[remotePortKey]uint16{}
	}
	ports.localPorts[key] = port
	a.remotePortsChanged(p)
	switch row, ok := ports.row(key); {
	case !ok:
	case row.forward == nil:
		a.forwardRemotePort(p, key, row.target(), false, surfaceButton)
	case row.forward.LocalPort != port:
		a.moveRemotePort(p, key, *row.forward, port)
	}
}

// moveRemotePort stops forward of row key and starts it again on local port. The target was
// confirmed when the forward started, so it is not asked about again.
func (a *App) moveRemotePort(p *project, key remotePortKey, forward core.RemoteForward, port uint16) {
	r := p.remote
	if r.closed || r.session == "" || r.ports.busy[key] != 0 {
		// log-exempt: 非用户操作：没有会话或这一行已有操作在进行，按钮此时不可用。
		return
	}
	a.performed("remote.ports.move", surfaceButton)
	ports := &r.ports
	ports.setBusy(key, remotePortForwarding)
	ports.setFailed(key, "")
	ports.notice = ""
	session, kernel := r.session, a.kernel
	target := core.RemoteForwardTarget{Host: forward.TargetHost, Port: forward.TargetPort, LocalPort: port,
		AllowNonLoopback: !forward.LoopbackTarget}
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		_, stopErr := kernel.RemoteStopForward(ctx, session, forward.ID)
		var started core.RemoteForward
		var startErr error
		if stopErr == nil {
			started, _, startErr = kernel.RemoteStartForward(ctx, session, target)
		}
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			ports.setBusy(key, 0)
			switch {
			case stopErr != nil && remoteConnectionClosed(stopErr):
				a.loseRemote(p, session, stopErr)
			case stopErr != nil:
				a.operationFailed("remote_port_stop", remoteLogError(stopErr))
				ports.setFailed(key, remotePortsReason(stopErr))
			default:
				ports.dropForward(forward.ID)
				a.forwardStarted(p, session, key, forward.TargetHost, started, startErr)
			}
		}
	})
}

// confirmRemotePort forwards the target waiting for confirmation, which the user confirmed.
func (a *App) confirmRemotePort(p *project) {
	ports := &p.remote.ports
	pending := ports.confirm
	ports.confirm, ports.confirmOpen = nil, false
	if pending == nil {
		return
	}
	a.forwardRemotePort(p, pending.key, pending.host, true, surfaceButton)
}

// stopRemotePort stops the forward of row key.
func (a *App) stopRemotePort(p *project, key remotePortKey, id uint64, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.busy[key] != 0 {
		// log-exempt: 非用户操作：没有会话或这一行已有操作在进行，按钮此时不可用。
		return
	}
	a.performed("remote.ports.stop", surface)
	ports := &r.ports
	ports.setBusy(key, remotePortStopping)
	ports.setFailed(key, "")
	session, kernel := r.session, a.kernel
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		_, err := kernel.RemoteStopForward(ctx, session, id)
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			ports.setBusy(key, 0)
			switch {
			case err == nil:
				// A forward Core no longer knows has stopped as well.
				ports.dropForward(id)
				ports.setRunning(key, nil)
				a.remotePortsChanged(p)
			case remoteConnectionClosed(err):
				// The user stopped it: the next session does not start it again.
				ports.setRunning(key, nil)
				a.loseRemote(p, session, err)
			default:
				a.operationFailed("remote_port_stop", remoteLogError(err))
				ports.setFailed(key, remotePortsReason(err))
			}
		}
	})
}

// stopAllRemotePorts stops every forward of p's session, the rules included, then reads the
// forwards again.
func (a *App) stopAllRemotePorts(p *project, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.stoppingAll || len(r.ports.forwards) == 0 {
		// log-exempt: 非用户操作：没有会话、没有转发或停止全部已在进行，按钮此时不可用。
		return
	}
	a.performed("remote.ports.stopAll", surface)
	ports := &r.ports
	ports.stoppingAll = true
	ids := make([]uint64, len(ports.forwards))
	var keys []remotePortKey
	for i, forward := range ports.forwards {
		ids[i] = forward.ID
		if forward.IsLocal() {
			keys = append(keys, forwardKey(forward))
			ports.setBusy(forwardKey(forward), remotePortStopping)
		} else {
			ports.setRuleStopping(forward.ID, true)
		}
	}
	session, kernel := r.session, a.kernel
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		var stopErr error
		for _, id := range ids {
			if _, err := kernel.RemoteStopForward(ctx, session, id); err != nil {
				stopErr = err
				break
			}
		}
		forwards, listErr := kernel.RemoteForwards(ctx, session)
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			ports.stoppingAll = false
			clear(ports.busy)
			clear(ports.ruleStopping)
			clear(ports.ruleFailed)
			// The user stopped them: only a forward the listing still shows stays remembered.
			for _, key := range keys {
				if listErr != nil || !slices.ContainsFunc(forwards, func(forward core.RemoteForward) bool {
					return forward.IsLocal() && forwardKey(forward) == key
				}) {
					ports.setRunning(key, nil)
				}
			}
			a.remotePortsChanged(p)
			err := errors.Join(stopErr, listErr)
			switch {
			case err != nil && (remoteConnectionClosed(stopErr) || remoteConnectionClosed(listErr)):
				a.loseRemote(p, session, err)
				return
			case err != nil:
				a.operationFailed("remote_port_stop_all", remoteLogError(err))
				ports.notice = i18n.SharedFormat(a.language(), "desktop.remote.ports.statusFailed",
					map[string]string{"reason": remotePortsReason(err)})
			}
			if listErr == nil {
				ports.forwards = forwards
			}
		}
	})
}

// addRemotePort has Core read the address typed into the window — a port, host:port or a URL —
// then adds its port and forwards it. A refused address is shown under the field, which keeps the
// text so it can be corrected.
func (a *App) addRemotePort(p *project, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.ports.adding {
		// log-exempt: 非用户操作：工作区已关闭或上一个地址正在解析，按钮此时不可用。
		return
	}
	ports := &r.ports
	text := strings.TrimSpace(ports.add.Text())
	if text == "" {
		// log-exempt: 非用户操作：输入为空，按钮此时不可用。
		return
	}
	ports.adding = true
	kernel := a.kernel
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		address, err := kernel.RemoteParseForwardAddress(ctx, text)
		return func(a *App) {
			ports.adding = false
			if r.closed {
				// log-exempt: 用户取消：工作区已关闭，添加的端口随窗口一起丢弃。
				return
			}
			if _, reason, refused := core.RemoteConnectionFieldError(err); refused {
				a.operationRejected("remote_port_add", remotePortsAddRejection(reason))
				ports.addRefused = reason
				return
			}
			if err != nil {
				a.operationFailed("remote_port_add", remoteLogError(err))
				ports.notice = i18n.SharedFormat(a.language(), "desktop.remote.ports.statusFailed",
					map[string]string{"reason": remotePortsReason(err)})
				return
			}
			ports.addRefused = ""
			if strings.TrimSpace(ports.add.Text()) == text {
				ports.add.SetText("")
			}
			a.addRemoteAddress(p, address, surface)
		}
	})
}

// remotePortsAddRejections are the log reasons of the reasons Core refuses an address typed into
// the window with (remote.parseForwardAddress); a reason Core adds later is logged as
// invalid_address.
var remotePortsAddRejections = map[string]string{
	"empty":       "empty_address",
	"tooLong":     "address_too_long",
	"malformed":   "malformed_address",
	"scheme":      "invalid_scheme",
	"credentials": "credentials_in_address",
	"host":        "invalid_host",
	"port":        "invalid_port",
}

// remotePortsAddRejection is the log reason of reason, a fixed token whatever Core sends.
func remotePortsAddRejection(reason string) string {
	if token, known := remotePortsAddRejections[reason]; known {
		return token
	}
	return "invalid_address"
}

// addRemoteAddress adds the port of address, which Core read, and forwards it unless it is
// forwarded already.
func (a *App) addRemoteAddress(p *project, address core.RemoteForwardAddress, surface actionSurface) {
	ports := &p.remote.ports
	key := remotePortKey{host: remotePortHost(address.TargetHost), port: address.TargetPort}
	ports.putAdded(remotePortAdded{key: key, host: address.TargetHost, scheme: address.Scheme, path: address.Path})
	a.remotePortsChanged(p)
	row, _ := ports.row(key)
	if row.forward != nil {
		// log-exempt: 非用户操作：这个端口已在转发，添加只让它出现在列表里，或换成新输入的网址。
		return
	}
	a.forwardRemotePort(p, key, row.target(), false, surface)
}

// removeRemotePort removes a port the user added from the window, with its label and local port.
func (a *App) removeRemotePort(p *project, key remotePortKey) {
	ports := &p.remote.ports
	a.performed("remote.ports.remove", surfaceContextMenu)
	ports.manual = slices.DeleteFunc(ports.manual, func(added remotePortAdded) bool { return added.key == key })
	delete(ports.labels, key)
	delete(ports.localPorts, key)
	ports.setFailed(key, "")
	a.remotePortsChanged(p)
}

// remotePortAddress is the local address of forward, as host:port.
func remotePortAddress(forward core.RemoteForward) string {
	return net.JoinHostPort(forward.LocalHost, strconv.Itoa(int(forward.LocalPort)))
}

// openRemotePort opens the forward of row in the system browser (remotePortRow.browserURL).
func (a *App) openRemotePort(row remotePortRow, surface actionSurface) {
	url, ok := row.browserURL()
	if !ok {
		// log-exempt: 非用户操作：这一行没有转发，或它的网址不是浏览器打开的协议，按钮此时不显示。
		return
	}
	a.performed("remote.ports.open", surface)
	if err := openURL(url); err != nil {
		// The error can name the URL, whose path and query the user typed and which may hold a
		// token, so the log keeps only that the browser did not open it; the notice shows the URL.
		a.operationFailed("remote_port_open", errRemotePortOpen)
		a.notifyError(a.text.Run.Ports.OpenFailed(url))
	}
}

// errRemotePortOpen is what the log keeps of a forward's address the system did not open.
var errRemotePortOpen = errors.New("the system did not open the forwarded address")

// copyRemotePort copies the local address of row's forward to the clipboard
// (remotePortRow.copyText).
func (a *App) copyRemotePort(row remotePortRow, surface actionSurface) {
	if row.forward == nil {
		// log-exempt: 非用户操作：这一行没有转发，按钮此时不显示。
		return
	}
	a.performed("remote.ports.copy", surface)
	if err := app.SetClipboardText(row.copyText()); err != nil {
		a.operationFailed("remote_port_copy", err)
	}
}
