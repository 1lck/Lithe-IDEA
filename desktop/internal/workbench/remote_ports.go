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
// unforwarded again.
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

// remotePortRow is one row of the window.
type remotePortRow struct {
	key remotePortKey
	// listening holds the host's listening sockets of the row, empty for a port that only the
	// user added.
	listening []core.RemoteListeningPort
	// manual reports that the user added the port.
	manual bool
	// forward is the row's running forward, nil while there is none.
	forward *core.RemoteForward
}

// target is the host the row's forward is started to: the row's own address, or the loopback
// address of the family the host's server listens on, or localhost for a port added by hand.
func (row remotePortRow) target() string {
	if row.key.host != "" {
		return row.key.host
	}
	for _, port := range row.listening {
		if ip, err := netip.ParseAddr(port.Address); err == nil && ip.Unmap().Is4() {
			return "127.0.0.1"
		}
	}
	if len(row.listening) > 0 {
		return "::1"
	}
	return "localhost"
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
	manual []remotePortKey
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
	// add is the field a port is typed into, and addInvalid is set when its text is not a port.
	add        ui.Field
	addInvalid bool
	// reading is set while a reading runs or the next one is scheduled; shown is set each time the
	// window is drawn, so a reading that finds it unset since the last one stops reading. stopTimer
	// stops the scheduled reading; timer tells its callback apart from a later schedule's.
	reading   bool
	shown     bool
	stopTimer func() bool
	timer     uint64
}

// reset forgets what belonged to the ended session: its forwards, what ran for them and the
// listing it read. The ports the user added stay.
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

// rows are the window's rows: the listening ports, the ports added by hand and the forwards, by
// port and then by address.
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
	for _, key := range ports.manual {
		row(key).manual = true
	}
	for i := range ports.forwards {
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
	case code == core.CodeForwardTargetNotConfirmed:
		a.operationRejected("remote_port_forward", "target_not_confirmed")
		ports.confirm, ports.confirmOpen = &remotePortConfirm{key: key, host: host}, true
	case code == core.CodeConnectionClosed:
		a.loseRemote(p, session, err)
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
		if forwardKey(forward) == key {
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
	for _, row := range ports.rows() {
		switch {
		case row.key != key:
			continue
		case row.forward == nil:
			a.forwardRemotePort(p, key, row.target(), false, surfaceButton)
		case row.forward.LocalPort != port:
			a.moveRemotePort(p, key, *row.forward, port)
		}
		return
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
			case remoteConnectionClosed(err):
				a.loseRemote(p, session, err)
			default:
				a.operationFailed("remote_port_stop", remoteLogError(err))
				ports.setFailed(key, remotePortsReason(err))
			}
		}
	})
}

// stopAllRemotePorts stops every forward of p's session, then reads the forwards again.
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
	for i, forward := range ports.forwards {
		ids[i] = forward.ID
		ports.setBusy(forwardKey(forward), remotePortStopping)
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

// parseRemotePort reads a port typed into the window: a port alone, on the host's loopback
// interface, or host:port, with brackets around an IPv6 host. The host is checked by Core.
func parseRemotePort(text string) (host string, port uint16, ok bool) {
	text = strings.TrimSpace(text)
	portText := text
	host = "localhost"
	if _, err := strconv.Atoi(text); err != nil {
		h, p, err := net.SplitHostPort(text)
		if err != nil || h == "" {
			return "", 0, false
		}
		host, portText = h, p
	}
	n, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || n == 0 {
		return "", 0, false
	}
	return host, uint16(n), true
}

// addRemotePort adds the port typed into the window and forwards it.
func (a *App) addRemotePort(p *project, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed {
		return
	}
	ports := &r.ports
	host, port, ok := parseRemotePort(ports.add.Text())
	if !ok {
		a.operationRejected("remote_port_add", "invalid_port")
		ports.addInvalid = true
		return
	}
	ports.addInvalid = false
	ports.add.SetText("")
	key := remotePortKey{host: remotePortHost(host), port: port}
	if !slices.Contains(ports.manual, key) {
		ports.manual = append(ports.manual, key)
	}
	for _, row := range ports.rows() {
		if row.key != key {
			continue
		}
		if row.forward != nil {
			// log-exempt: 非用户操作：这个端口已在转发，添加只让它出现在列表里。
			return
		}
		if key.host == "" && len(row.listening) == 0 {
			// A port typed alone or as localhost goes to the address the user typed.
			a.forwardRemotePort(p, key, host, false, surface)
			return
		}
		a.forwardRemotePort(p, key, row.target(), false, surface)
		return
	}
}

// removeRemotePort removes a port the user added from the window.
func (a *App) removeRemotePort(p *project, key remotePortKey) {
	ports := &p.remote.ports
	a.performed("remote.ports.remove", surfaceContextMenu)
	ports.manual = slices.DeleteFunc(ports.manual, func(k remotePortKey) bool { return k == key })
	ports.setFailed(key, "")
}

// remotePortAddress is the local address of forward, as host:port.
func remotePortAddress(forward core.RemoteForward) string {
	return net.JoinHostPort(forward.LocalHost, strconv.Itoa(int(forward.LocalPort)))
}

// openRemotePort opens the local address of forward in the system browser.
func (a *App) openRemotePort(forward core.RemoteForward, surface actionSurface) {
	a.performed("remote.ports.open", surface)
	url := "http://" + remotePortAddress(forward)
	if err := openURL(url); err != nil {
		a.operationFailed("remote_port_open", err)
		a.notifyError(a.text.Run.Ports.OpenFailed(url))
	}
}

// copyRemotePort copies the local address of forward to the clipboard.
func (a *App) copyRemotePort(forward core.RemoteForward, surface actionSurface) {
	a.performed("remote.ports.copy", surface)
	if err := app.SetClipboardText(remotePortAddress(forward)); err != nil {
		a.operationFailed("remote_port_copy", err)
	}
}
