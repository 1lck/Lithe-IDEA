package workbench

import (
	"context"
	"errors"
	"net/netip"
	"slices"
	"strconv"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// remoteHostPorts stands in for the host's listening ports (ports.listening) and for Core's
// forwards of each session, which it keeps as Core does: a target outside the host's loopback
// interface needs the user's confirmation (S28), the same target again is the running forward, a
// local port that is taken is replaced by a free one, and a session runs at most limit forwards
// when limit is set.
type remoteHostPorts struct {
	listening []core.RemoteListeningPort
	// listenErr fails every listing while it is set; listings counts the listings asked for.
	listenErr error
	listings  int
	forwards  map[string][]core.RemoteForward
	next      uint64
	limit     int
	// taken are the local ports other programs of this computer listen on.
	taken map[uint16]bool
	// starts are the targets forwards were asked for, and stops the forwards stopped.
	starts []core.RemoteForwardTarget
	stops  []uint64
}

func (k *remoteHostKernel) RemoteListeningPorts(context.Context, string) ([]core.RemoteListeningPort, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.ports.listings++
	if err := k.ports.listenErr; err != nil {
		return nil, err
	}
	return slices.Clone(k.ports.listening), nil
}

func (k *remoteHostKernel) RemoteForwards(_ context.Context, session string) ([]core.RemoteForward, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	return slices.Clone(k.ports.forwards[session]), nil
}

func (k *remoteHostKernel) RemoteStartForward(_ context.Context, session string, target core.RemoteForwardTarget) (core.RemoteForward, bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	p := &k.ports
	p.starts = append(p.starts, target)
	host, loopback := target.Host, target.Host == "localhost"
	if ip, err := netip.ParseAddr(host); err == nil {
		ip = ip.Unmap()
		switch {
		case ip.IsUnspecified() && ip.Is4():
			ip = netip.AddrFrom4([4]byte{127, 0, 0, 1})
		case ip.IsUnspecified():
			ip = netip.IPv6Loopback()
		}
		host, loopback = ip.String(), ip.IsLoopback()
	}
	if !loopback && !target.AllowNonLoopback {
		return core.RemoteForward{}, false, &core.Error{Command: "remote.startForward", Code: core.CodeForwardTargetNotConfirmed, Message: "not confirmed"}
	}
	for _, forward := range p.forwards[session] {
		if forward.TargetHost == host && forward.TargetPort == target.Port {
			return forward, false, nil
		}
	}
	if p.limit > 0 && len(p.forwards[session]) >= p.limit {
		return core.RemoteForward{}, false, &core.Error{Command: "remote.startForward", Code: core.CodeForwardLimitReached,
			Message: "too many forwards", Details: `{"maximum":` + strconv.Itoa(p.limit) + `}`}
	}
	p.next++
	forward := core.RemoteForward{ID: p.next, LocalHost: "127.0.0.1", LocalPort: target.LocalPort,
		TargetHost: host, TargetPort: target.Port, LoopbackTarget: loopback}
	if requested := target.LocalPort; requested != 0 {
		forward.RequestedLocalPort = &requested
	}
	if forward.LocalPort == 0 || p.taken[forward.LocalPort] || p.localInUse(forward.LocalPort) {
		forward.LocalPortChanged = forward.LocalPort != 0
		forward.LocalPort = 40000 + uint16(p.next)
	}
	if p.forwards == nil {
		p.forwards = map[string][]core.RemoteForward{}
	}
	p.forwards[session] = append(p.forwards[session], forward)
	return forward, true, nil
}

// localInUse reports whether a forward of any session listens on local port.
func (p *remoteHostPorts) localInUse(port uint16) bool {
	for _, forwards := range p.forwards {
		for _, forward := range forwards {
			if forward.LocalPort == port {
				return true
			}
		}
	}
	return false
}

func (k *remoteHostKernel) RemoteStopForward(_ context.Context, session string, id uint64) (bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	p := &k.ports
	p.stops = append(p.stops, id)
	before := len(p.forwards[session])
	p.forwards[session] = slices.DeleteFunc(p.forwards[session], func(forward core.RemoteForward) bool { return forward.ID == id })
	return len(p.forwards[session]) < before, nil
}

// takeAfter is the pending timer that waits d, which no longer is; the others stay pending. A
// workspace whose Ports window is open has its heartbeat and the window's next reading pending.
func (s *remoteTimers) takeAfter(t *testing.T, d time.Duration) *remoteTimer {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	var found []*remoteTimer
	for _, timer := range s.pending {
		if !timer.stopped && timer.after == d {
			found = append(found, timer)
		}
	}
	if len(found) != 1 {
		t.Fatalf("%d timers of %v pending, want one", len(found), d)
	}
	found[0].stopped = true
	return found[0]
}

// liveAfter counts the pending timers that wait d.
func (s *remoteTimers) liveAfter(d time.Duration) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, timer := range s.pending {
		if !timer.stopped && timer.after == d {
			n++
		}
	}
	return n
}

// fireAfter runs the pending timer that waits d and applies what it started.
func (h *harness) fireAfter(t *testing.T, timers *remoteTimers, d time.Duration) {
	t.Helper()
	timers.takeAfter(t, d).run()
	h.settle()
	h.settle()
	h.settle()
}

// openRemotePortsWindow opens the remote test workspace on a host listening on listening, shows
// its Ports window and waits for the window's first reading.
func (h *harness) openRemotePortsWindow(t *testing.T, k *remoteHostKernel, listening ...core.RemoteListeningPort) *project {
	t.Helper()
	k.set(func(k *remoteHostKernel) { k.ports.listening = listening })
	p := h.openRemoteTestProject(t)
	h.app.openToolWindow(itemPorts)
	h.redraw()
	h.await("the Ports window's first reading", func() bool { return p.remote.ports.listed || p.remote.ports.readFailed != "" })
	h.settle()
	return p
}

// portRowControl is where the control named label of the Ports window's row remote, as its Remote
// Port column reads, was laid out in the last frame.
func (h *harness) portRowControl(remote, label string) gfx.Rect {
	h.t.Helper()
	hits := h.driver.Snapshot().Hits
	var row *gfx.Hit
	for i := range hits {
		if hits[i].Label == remote && !hits[i].IsLabel {
			row = &hits[i]
		}
	}
	if row == nil {
		h.t.Fatalf("no row %q is shown", remote)
		return gfx.Rect{}
	}
	for _, hit := range hits {
		if hit.Label == label && !hit.IsLabel && hit.Bounds.Y >= row.Bounds.Y && hit.Bounds.Y+hit.Bounds.Height <= row.Bounds.Y+row.Bounds.Height {
			return hit.Bounds
		}
	}
	h.t.Fatalf("row %q has no control named %q", remote, label)
	return gfx.Rect{}
}

// hasControl reports whether a control named label was laid out in the last frame.
func (h *harness) hasControl(label string) bool {
	return slices.ContainsFunc(h.driver.Snapshot().Hits, func(hit gfx.Hit) bool { return hit.Label == label && !hit.IsLabel })
}

// remotePortKeys are the keys of rows, in order.
func remotePortKeys(rows []remotePortRow) []remotePortKey {
	keys := make([]remotePortKey, len(rows))
	for i, row := range rows {
		keys[i] = row.key
	}
	return keys
}

// The Ports tool window exists only in a remote workspace: a local window neither shows its
// button nor lists it among the tool windows, and closing the workspace takes it away again.
func TestRemotePortsWindowIsOnlyInARemoteWorkspace(t *testing.T) {
	h, _, _, _ := remoteWorkspaceHarness(t)
	index := catalogIndex[itemPorts]
	listed := func() bool {
		return slices.ContainsFunc(h.app.commands(), func(c command) bool { return c.id == toolCommandPrefix+itemPorts })
	}
	if h.app.chrome.present(index) || listed() {
		t.Fatal("a window without a remote workspace offers the Ports window")
	}
	h.openRemoteTestProject(t)
	h.settle()
	if !h.app.chrome.present(index) || !listed() {
		t.Fatal("the remote workspace does not offer the Ports window")
	}
	h.button(itemPorts)

	h.app.openToolWindow(itemPorts)
	h.redraw()
	h.app.closeProject()
	h.settle()
	if h.app.chrome.present(index) || h.app.chrome.isOpen(index) || listed() {
		t.Fatal("the Ports window outlived the remote workspace")
	}
}

// The window lists the host's listening ports, one row for a server listening on every interface
// of both families, with its process; Forward forwards the row to the host's loopback address on
// the same local port, or a free one when that is taken, the row and the status bar show the
// local address and the count, and the count opens the window.
func TestRemotePortsListsAndForwardsTheHostsPorts(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k,
		core.RemoteListeningPort{Address: "0.0.0.0", Port: 8080, PID: 41, Process: "node"},
		core.RemoteListeningPort{Address: "::", Port: 8080, PID: 41, Process: "node"},
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 5432, PID: 7, Process: "postgres"},
		core.RemoteListeningPort{Address: "127.0.0.2", Port: 5432},
		core.RemoteListeningPort{Address: "10.0.0.5", Port: 9000},
	)
	k.set(func(k *remoteHostKernel) { k.ports.taken = map[uint16]bool{5432: true} })
	ports := &p.remote.ports
	want := []remotePortKey{{port: 5432}, {host: "127.0.0.2", port: 5432}, {port: 8080}, {host: "10.0.0.5", port: 9000}}
	if got := remotePortKeys(ports.rows()); !slices.Equal(got, want) {
		t.Fatalf("rows %v, want %v", got, want)
	}
	if len(k.ports.starts) != 0 || len(ports.forwards) != 0 {
		t.Fatal("a port was forwarded before the user asked")
	}
	node := i18n.SharedFormat(lang, "desktop.remote.ports.process", map[string]string{"process": "node", "pid": "41"})
	if !h.shows(node) || !h.shows("10.0.0.5:9000") || !h.shows(i18n.Shared(lang, "desktop.remote.ports.processUnknown")) {
		t.Fatal("the rows do not show the ports and their processes")
	}

	forward := i18n.Shared(lang, "desktop.remote.ports.forward")
	h.click(center(h.portRowControl("8080", forward)))
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()
	if got := k.ports.starts; len(got) != 1 || got[0] != (core.RemoteForwardTarget{Host: "127.0.0.1", Port: 8080, LocalPort: 8080}) {
		t.Fatalf("started %+v, want one forward to the IPv4 loopback address on the same local port", got)
	}
	label := i18n.Shared(lang, "desktop.remote.ports.statusLabel")
	if !h.shows("127.0.0.1:8080") || !h.shows(i18n.Shared(lang, "desktop.remote.ports.statusForwarded")) || !h.hasControl(label) {
		t.Fatal("the forward is not shown in its row and in the status bar")
	}
	h.click(center(h.portRowControl("5432", forward)))
	h.await("the forward on a free port", func() bool { return len(ports.forwards) == 2 && len(ports.busy) == 0 })
	h.settle()
	if changed := ports.forwards[1]; !changed.LocalPortChanged || changed.LocalPort == 5432 || !h.shows(remotePortAddress(changed)) {
		t.Fatalf("forward %+v: the taken local port was not replaced and shown", changed)
	}

	h.app.reduceChrome(core.SetChromeOpen(itemPorts, false))
	h.redraw()
	h.clickLabeled(label)
	if !h.app.chrome.isOpen(catalogIndex[itemPorts]) {
		t.Fatal("the status bar's count did not open the Ports window")
	}
	actions := remoteActions(logger)
	if !slices.Contains(actions, "remote.ports.forward") || !slices.Contains(actions, "remote.ports.status") {
		t.Fatalf("performed %q, want the forward and the status bar's click", actions)
	}
	if event := loggedAny(t, logger, remoteTestHost, "10.0.0.5", "node", "postgres"); event != "" {
		t.Fatalf("logged the host, an address or a process: %s", event)
	}
}

// A target outside the host's loopback interface is forwarded only after the window asked: Forward
// in the question forwards it, and Cancel forwards nothing and is logged as declined.
func TestRemotePortsAsksBeforeForwardingOutsideTheLoopback(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "10.0.0.5", Port: 9000})
	ports := &p.remote.ports
	title := i18n.Shared(lang, "desktop.remote.ports.confirmTitle")

	h.click(center(h.portRowControl("10.0.0.5:9000", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the question", func() bool { return ports.confirm != nil && len(ports.busy) == 0 })
	h.settle()
	if !h.shows(title) || !rejected(logger, "remote_port_forward", "target_not_confirmed") || len(ports.forwards) != 0 {
		t.Fatal("the unconfirmed target was not asked about")
	}
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.confirmForward"))))
	h.await("the confirmed forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()
	if got := k.ports.starts; len(got) != 2 || got[1] != (core.RemoteForwardTarget{Host: "10.0.0.5", Port: 9000, LocalPort: 9000, AllowNonLoopback: true}) {
		t.Fatalf("started %+v, want the target again once confirmed", got)
	}
	if ports.confirm != nil || h.shows(title) {
		t.Fatal("the question stayed open")
	}

	ports.add.SetText("10.0.0.6:7000")
	h.redraw()
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.ports.add"))
	h.await("the second question", func() bool { return ports.confirm != nil && len(ports.busy) == 0 })
	h.settle()
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.confirmCancel"))))
	h.settle()
	if ports.confirm != nil || len(ports.forwards) != 1 || len(k.ports.starts) != 3 {
		t.Fatalf("forwards %d, starts %d: Cancel forwarded the target", len(ports.forwards), len(k.ports.starts))
	}
	if !rejected(logger, "remote_port_forward", "target_declined") {
		t.Fatal("Cancel was not logged as declined")
	}
}

// A port typed into the window is checked, added and forwarded to the address typed; added again
// it is not forwarded twice, and once stopped the menu removes it.
func TestRemotePortsAddsStopsAndRemovesAPort(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k)
	ports := &p.remote.ports
	empty := i18n.Shared(lang, "desktop.remote.ports.empty")
	if !h.showsWrapped(empty) {
		t.Fatal("the window does not say the host listens on nothing")
	}
	add := i18n.Shared(lang, "desktop.remote.ports.add")
	ports.add.SetText("not a port")
	h.redraw()
	h.clickLabeled(add)
	if !ports.addInvalid || !rejected(logger, "remote_port_add", "invalid_port") || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.ports.addInvalid")) {
		t.Fatal("a text that is not a port was not refused")
	}

	ports.add.SetText("3000")
	h.redraw()
	h.clickLabeled(add)
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()
	if got := k.ports.starts; len(got) != 1 || got[0] != (core.RemoteForwardTarget{Host: "localhost", Port: 3000, LocalPort: 3000}) {
		t.Fatalf("started %+v, want the port on localhost", got)
	}
	if ports.addInvalid || ports.add.Text() != "" || !h.shows(i18n.Shared(lang, "desktop.remote.ports.sourceManual")) {
		t.Fatal("the added port is not shown as added by hand")
	}
	ports.add.SetText("localhost:3000")
	h.redraw()
	h.clickLabeled(add)
	if len(k.ports.starts) != 1 || len(ports.manual) != 1 {
		t.Fatalf("starts %d, manual %d: the port was added twice", len(k.ports.starts), len(ports.manual))
	}

	h.click(center(h.portRowControl("3000", i18n.Shared(lang, "desktop.remote.ports.stop"))))
	h.await("the stop", func() bool { return len(ports.forwards) == 0 && len(ports.busy) == 0 })
	h.settle()
	if !slices.Equal(k.ports.stops, []uint64{1}) || !h.shows(i18n.Shared(lang, "desktop.remote.ports.statusNotForwarded")) {
		t.Fatalf("stopped %v: the row does not show the stopped forward", k.ports.stops)
	}
	h.rightClickAt(h.portRowControl("3000", "3000"))
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.remove"))))
	h.settle()
	if len(ports.manual) != 0 || !h.showsWrapped(empty) {
		t.Fatal("Remove left the port in the window")
	}
	want := []string{"remote.ports.forward", "remote.ports.stop", "remote.ports.remove"}
	if got := remoteActions(logger); !slices.Equal(got[len(got)-len(want):], want) {
		t.Fatalf("performed %q, want it to end with %q", got, want)
	}
}

// The menu forwards a row on a local port the user types, which the row keeps: a text that is not
// a port is refused, Cancel changes nothing, another port moves the running forward by stopping
// and starting it, the same port leaves it alone, and a confirmed target is not asked about again.
func TestRemotePortsForwardOnAChosenLocalPort(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k,
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080},
		core.RemoteListeningPort{Address: "10.0.0.5", Port: 9000},
	)
	ports := &p.remote.ports
	apply := i18n.Shared(lang, "desktop.remote.ports.localApply")
	choose := func(remote, item, port string) {
		t.Helper()
		h.rightClickAt(h.portRowControl(remote, remote))
		h.click(center(h.popupHit(i18n.Shared(lang, item))))
		h.settle()
		if ports.local == nil || !h.shows(i18n.Shared(lang, "desktop.remote.ports.localTitle")) {
			t.Fatal("the local port dialog did not open")
		}
		if got := ports.localField.Text(); got != port {
			t.Fatalf("the dialog starts from %q, want %q", got, port)
		}
	}
	submit := func(text string) {
		t.Helper()
		ports.localField.SetText(text)
		h.redraw()
		h.click(center(h.popupHit(apply)))
		h.settle()
	}

	choose("8080", "desktop.remote.ports.forwardLocal", "8080")
	submit("70000")
	if !ports.localInvalid || ports.local == nil || len(k.ports.starts) != 0 || !rejected(logger, "remote_port_local", "invalid_port") ||
		!h.shows(i18n.Shared(lang, "desktop.remote.ports.localInvalid")) {
		t.Fatal("a text that is not a port was not refused in the dialog")
	}
	submit("18080")
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()
	if got := k.ports.starts; len(got) != 1 || got[0] != (core.RemoteForwardTarget{Host: "127.0.0.1", Port: 8080, LocalPort: 18080}) {
		t.Fatalf("started %+v, want the chosen local port", got)
	}
	if ports.local != nil || !h.shows("127.0.0.1:18080") {
		t.Fatal("the forward on the chosen port is not shown")
	}

	choose("8080", "desktop.remote.ports.changeLocal", "18080")
	ports.localField.SetText("1")
	h.redraw()
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.localCancel"))))
	h.settle()
	if ports.local != nil || len(k.ports.starts) != 1 || len(k.ports.stops) != 0 || ports.localPorts[remotePortKey{port: 8080}] != 18080 {
		t.Fatal("Cancel changed the forward")
	}
	choose("8080", "desktop.remote.ports.changeLocal", "18080")
	submit("18080")
	if len(k.ports.starts) != 1 || len(k.ports.stops) != 0 {
		t.Fatal("the same local port restarted the forward")
	}
	choose("8080", "desktop.remote.ports.changeLocal", "18080")
	submit("18081")
	h.await("the moved forward", func() bool {
		return len(ports.forwards) == 1 && ports.forwards[0].LocalPort == 18081 && len(ports.busy) == 0
	})
	h.settle()
	if !slices.Equal(k.ports.stops, []uint64{1}) || !h.shows("127.0.0.1:18081") {
		t.Fatalf("stopped %v: the forward was not moved to the new port", k.ports.stops)
	}

	h.click(center(h.portRowControl("8080", i18n.Shared(lang, "desktop.remote.ports.stop"))))
	h.await("the stop", func() bool { return len(ports.forwards) == 0 && len(ports.busy) == 0 })
	h.settle()
	h.click(center(h.portRowControl("8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward again", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	if got := k.ports.starts[len(k.ports.starts)-1]; got.LocalPort != 18081 {
		t.Fatalf("forwarded again on %d, want the chosen port the row keeps", got.LocalPort)
	}

	h.click(center(h.portRowControl("10.0.0.5:9000", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the question", func() bool { return ports.confirm != nil && len(ports.busy) == 0 })
	h.settle()
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.confirmForward"))))
	h.await("the confirmed forward", func() bool { return len(ports.forwards) == 2 && len(ports.busy) == 0 })
	h.settle()
	choose("10.0.0.5:9000", "desktop.remote.ports.changeLocal", "9000")
	submit("19000")
	h.await("the moved confirmed forward", func() bool {
		return len(ports.forwards) == 2 && ports.forwards[1].LocalPort == 19000 && len(ports.busy) == 0
	})
	h.settle()
	want := core.RemoteForwardTarget{Host: "10.0.0.5", Port: 9000, LocalPort: 19000, AllowNonLoopback: true}
	if got := k.ports.starts[len(k.ports.starts)-1]; got != want || ports.confirm != nil {
		t.Fatalf("started %+v, want the confirmed target without asking again", got)
	}
	actions := remoteActions(logger)
	if !slices.Contains(actions, "remote.ports.localPort") || !slices.Contains(actions, "remote.ports.move") {
		t.Fatalf("performed %q, want the dialog and the move", actions)
	}
}

// Past the session's limit the window says how many forwards Core runs, and Stop All Forwards
// stops every forward and takes the status bar's count away.
func TestRemotePortsStopsAllAndReportsTheLimit(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.set(func(k *remoteHostKernel) { k.ports.limit = 2 })
	p := h.openRemotePortsWindow(t, k,
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 3000},
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 3001},
		core.RemoteListeningPort{Address: "127.0.0.1", Port: 3002},
	)
	ports := &p.remote.ports
	forward := i18n.Shared(lang, "desktop.remote.ports.forward")
	for i, port := range []string{"3000", "3001", "3002"} {
		h.click(center(h.portRowControl(port, forward)))
		h.await("the forward of "+port, func() bool { return len(ports.busy) == 0 && (len(ports.forwards) == i+1 || ports.notice != "") })
		h.settle()
	}
	limit := i18n.SharedFormat(lang, "desktop.remote.ports.limit", map[string]string{"maximum": "2"})
	if len(ports.forwards) != 2 || ports.notice != limit || !h.showsWrapped(limit) {
		t.Fatalf("forwards %d: the limit is not reported", len(ports.forwards))
	}
	if got := countFailures(logger, "remote_port_forward"); got != 1 {
		t.Fatalf("remote_port_forward failed %d times, want once", got)
	}

	h.clickLabeled(i18n.Shared(lang, "desktop.remote.ports.stopAll"))
	h.await("Stop All Forwards", func() bool { return !ports.stoppingAll && len(ports.forwards) == 0 })
	h.settle()
	if len(k.ports.forwards[p.remote.session]) != 0 || h.hasControl(i18n.Shared(lang, "desktop.remote.ports.statusLabel")) {
		t.Fatal("Stop All Forwards left a forward running or counted")
	}
	if !slices.Contains(remoteActions(logger), "remote.ports.stopAll") {
		t.Fatal("Stop All Forwards was not logged")
	}
}

// A lost session takes its forwards with it: the window shows the port unforwarded and reads the
// new session's forwards once the workspace connects again.
func TestRemotePortsForgetTheForwardsOfALostSession(t *testing.T) {
	h, k, timers, _ := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	r := p.remote
	h.click(center(h.portRowControl("8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward", func() bool { return len(r.ports.forwards) == 1 && len(r.ports.busy) == 0 })
	h.settle()

	k.set(func(k *remoteHostKernel) {
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fireAfter(t, timers, remoteHeartbeatInterval)
	h.await("the new session's reading", func() bool {
		return r.session == "session-2" && !r.beating && r.ports.listed && !p.tree.reading
	})
	h.settle()
	if len(r.ports.forwards) != 0 || h.hasControl(i18n.Shared(lang, "desktop.remote.ports.statusLabel")) {
		t.Fatal("the lost session's forward is still shown")
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.ports.statusNotForwarded")) {
		t.Fatal("the port is not shown unforwarded")
	}
	if got := timers.liveAfter(remotePortsInterval); got != 1 {
		t.Fatalf("%d readings of the window pending, want the new session's one", got)
	}
}

// The window reads the host while it is open, and stops once it is hidden until it is shown again.
func TestRemotePortsReadOnlyWhileTheWindowIsOpen(t *testing.T) {
	h, k, timers, _ := remoteWorkspaceHarness(t)
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	listings := func() int { return k.count(func(k *remoteHostKernel) int { return k.ports.listings }) }
	if got := listings(); got != 1 {
		t.Fatalf("listed %d times on opening, want once", got)
	}
	h.fireAfter(t, timers, remotePortsInterval)
	if got := listings(); got != 2 {
		t.Fatalf("listed %d times, want the open window read again", got)
	}

	h.app.reduceChrome(core.SetChromeOpen(itemPorts, false))
	h.redraw()
	h.fireAfter(t, timers, remotePortsInterval)
	if got := listings(); got != 2 || p.remote.ports.reading || timers.liveAfter(remotePortsInterval) != 0 {
		t.Fatalf("listed %d times: the hidden window kept reading", got)
	}

	h.app.openToolWindow(itemPorts)
	h.redraw()
	h.await("the shown window's reading", func() bool { return listings() == 3 && timers.liveAfter(remotePortsInterval) == 1 })
}

// A reading that fails is shown in the window and logged once until a reading succeeds again.
func TestRemotePortsReportAFailedReadingOnce(t *testing.T) {
	h, k, timers, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	k.set(func(k *remoteHostKernel) { k.ports.listenErr = errors.New("ss: not found") })
	p := h.openRemotePortsWindow(t, k)
	ports := &p.remote.ports
	failed := i18n.SharedFormat(lang, "desktop.remote.ports.readFailed", map[string]string{"reason": "ss: not found"})
	if ports.readFailed == "" || !h.showsWrapped(failed) {
		t.Fatal("the failed reading is not shown")
	}
	h.fireAfter(t, timers, remotePortsInterval)
	if got := countFailures(logger, "remote_ports_read"); got != 1 {
		t.Fatalf("remote_ports_read failed %d times, want once while it keeps failing", got)
	}

	k.set(func(k *remoteHostKernel) { k.ports.listenErr = nil })
	h.fireAfter(t, timers, remotePortsInterval)
	if ports.readFailed != "" || !ports.listed || h.showsWrapped(failed) {
		t.Fatal("the successful reading did not clear the failure")
	}
	k.set(func(k *remoteHostKernel) { k.ports.listenErr = errors.New("ss: not found") })
	h.fireAfter(t, timers, remotePortsInterval)
	if got := countFailures(logger, "remote_ports_read"); got != 2 {
		t.Fatalf("remote_ports_read failed %d times, want a new failure logged again", got)
	}
}

func TestParseRemotePort(t *testing.T) {
	cases := []struct {
		text string
		host string
		port uint16
		ok   bool
	}{
		{text: "8080", host: "localhost", port: 8080, ok: true},
		{text: " 3000 ", host: "localhost", port: 3000, ok: true},
		{text: "localhost:3000", host: "localhost", port: 3000, ok: true},
		{text: "10.0.0.5:9000", host: "10.0.0.5", port: 9000, ok: true},
		{text: "[::1]:8080", host: "::1", port: 8080, ok: true},
		{text: "65535", host: "localhost", port: 65535, ok: true},
		{text: "0"},
		{text: "65536"},
		{text: "-1"},
		{text: "not a port"},
		{text: ":8080"},
		{text: "host:"},
		{text: "::1"},
		{text: ""},
	}
	for _, c := range cases {
		host, port, ok := parseRemotePort(c.text)
		if host != c.host || port != c.port || ok != c.ok {
			t.Errorf("parseRemotePort(%q) = %q, %d, %v; want %q, %d, %v", c.text, host, port, ok, c.host, c.port, c.ok)
		}
	}
}

func TestRemotePortHost(t *testing.T) {
	cases := map[string]string{
		"0.0.0.0":          "",
		"::":               "",
		"127.0.0.1":        "",
		"::1":              "",
		"[::1]":            "",
		"::ffff:127.0.0.1": "",
		"LocalHost":        "",
		"127.0.0.2":        "127.0.0.2",
		"::ffff:10.0.0.5":  "10.0.0.5",
		"fe80::1":          "fe80::1",
		"Build.Example":    "build.example",
	}
	for address, want := range cases {
		if got := remotePortHost(address); got != want {
			t.Errorf("remotePortHost(%q) = %q, want %q", address, got, want)
		}
	}
}
