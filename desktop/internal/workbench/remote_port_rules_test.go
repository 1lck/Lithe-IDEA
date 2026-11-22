package workbench

import (
	"context"
	"net/netip"
	"slices"
	"strconv"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
)

// remoteHostRules stands in for the host side of Core's host and reverse forwards, kept as Core
// does: a host target outside the host's loopback interface needs the user's confirmation, a reverse
// forward needs preferences that allow it, a host port that is taken or refused is never replaced
// by another one, and every kind counts toward the session's limit.
type remoteHostRules struct {
	// allowReverse is what the remote preferences answer for reverse forwards.
	allowReverse bool
	// inUse are the host ports other programs of the host listen on, and denied those the host
	// does not let the user listen on; unsupported refuses every rule.
	inUse, denied map[uint16]bool
	unsupported   bool
	// hostStarts and reverseStarts are the rules asked for.
	hostStarts    []core.RemoteHostForwardRule
	reverseStarts []core.RemoteReverseForwardRule
}

// RemotePreferences is Core's answer with reverse forwards allowed while rules.allowReverse is set.
func (k *remoteHostKernel) RemotePreferences(ctx context.Context, document *string, home string) (core.RemotePreferences, error) {
	state, err := k.testKernel.RemotePreferences(ctx, document, home)
	k.mu.Lock()
	defer k.mu.Unlock()
	if err == nil && k.ports.rules.allowReverse {
		state.Reverse = core.RemoteReverseForwarding{Source: core.RemotePreferenceFromSetting, Allowed: true}
	}
	return state, err
}

func (k *remoteHostKernel) RemoteStartHostForward(_ context.Context, session string, rule core.RemoteHostForwardRule) (core.RemoteForward, bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	p := &k.ports
	p.rules.hostStarts = append(p.rules.hostStarts, rule)
	loopback := rule.Host == "localhost"
	if ip, err := netip.ParseAddr(rule.Host); err == nil {
		loopback = ip.Unmap().IsLoopback()
	}
	if !loopback && !rule.AllowNonLoopback {
		return core.RemoteForward{}, false, remoteRuleError(core.CodeForwardTargetNotConfirmed, "")
	}
	listen := "127.0.0.1"
	if rule.AllInterfaces {
		listen = "0.0.0.0"
	}
	forward, err := p.listenRule(session, rule.ListenPort, listen)
	if err != nil {
		return core.RemoteForward{}, false, err
	}
	forward.Kind, forward.AllInterfaces = core.RemoteForwardHost, rule.AllInterfaces
	forward.TargetHost, forward.TargetPort, forward.LoopbackTarget = rule.Host, rule.Port, loopback
	p.forwards[session] = append(p.forwards[session], forward)
	return forward, true, nil
}

func (k *remoteHostKernel) RemoteStartReverseForward(_ context.Context, session string, rule core.RemoteReverseForwardRule, _ *string) (core.RemoteForward, bool, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	p := &k.ports
	p.rules.reverseStarts = append(p.rules.reverseStarts, rule)
	if !p.rules.allowReverse {
		return core.RemoteForward{}, false, remoteRuleError(core.CodeReverseForwardDisabled, "")
	}
	forward, err := p.listenRule(session, rule.ListenPort, "127.0.0.1")
	if err != nil {
		return core.RemoteForward{}, false, err
	}
	forward.Kind, forward.LocalHost, forward.LocalPort = core.RemoteForwardReverse, "127.0.0.1", rule.LocalPort
	p.forwards[session] = append(p.forwards[session], forward)
	return forward, true, nil
}

// listenRule listens on port of the host, or on one the host chooses for 0, for a rule of
// session; the caller fills in the rest of the forward and keeps it.
func (p *remoteHostPorts) listenRule(session string, port uint16, host string) (core.RemoteForward, error) {
	switch {
	case p.rules.unsupported:
		return core.RemoteForward{}, remoteRuleError(core.CodeForwardHostUnsupported, "")
	case port != 0 && p.rules.denied[port]:
		return core.RemoteForward{}, remoteRuleError(core.CodeForwardHostPortDenied, "")
	case port != 0 && p.rules.inUse[port]:
		return core.RemoteForward{}, remoteRuleError(core.CodeForwardHostPortInUse, "")
	case p.limit > 0 && len(p.forwards[session]) >= p.limit:
		return core.RemoteForward{}, remoteRuleError(core.CodeForwardLimitReached, `{"maximum":`+strconv.Itoa(p.limit)+`}`)
	}
	p.next++
	forward := core.RemoteForward{ID: p.next, HostListenHost: host, HostListenPort: port}
	if port == 0 {
		forward.HostListenPort = 41000 + uint16(p.next)
	} else {
		forward.RequestedHostPort = &port
	}
	if p.forwards == nil {
		p.forwards = map[string][]core.RemoteForward{}
	}
	return forward, nil
}

// remoteRuleError is Core refusing a rule with code.
func remoteRuleError(code core.ErrorCode, details string) error {
	return &core.Error{Command: "remote.startHostForward", Code: code, Message: "refused", Details: details}
}

// openRemotePortRule opens the Add Forwarding Rule dialog from the Ports window's header and waits
// until it read the remote preferences.
func (h *harness) openRemotePortRule(t *testing.T, p *project) *remotePortRuleDraft {
	t.Helper()
	h.clickLabeled(i18n.Shared(h.app.language(), "desktop.remote.ports.ruleAdd"))
	h.settle()
	h.settle()
	h.settle()
	draft := p.remote.ports.rule
	if draft == nil || !p.remote.ports.ruleOpen || !h.shows(i18n.Shared(h.app.language(), "desktop.remote.ports.ruleTitle")) {
		t.Fatal("the Add Forwarding Rule dialog did not open")
	}
	return draft
}

// submitRemotePortRule types listen and target into the dialog, presses Add and waits until the
// rule is asked about, refused or running.
func (h *harness) submitRemotePortRule(t *testing.T, p *project, listen, target string) {
	t.Helper()
	draft := p.remote.ports.rule
	draft.listen.SetText(listen)
	draft.target.SetText(target)
	h.redraw()
	h.click(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.remote.ports.ruleSubmit"))))
	h.awaitRemotePortRule(p, draft)
}

// confirmRemotePortRule presses the dialog's Confirm and Start and waits for the rule.
func (h *harness) confirmRemotePortRule(t *testing.T, p *project) {
	t.Helper()
	draft := p.remote.ports.rule
	h.click(center(h.popupHit(i18n.Shared(h.app.language(), "desktop.remote.ports.ruleConfirm"))))
	h.awaitRemotePortRule(p, draft)
}

// awaitRemotePortRule waits until draft no longer waits for Core.
func (h *harness) awaitRemotePortRule(p *project, draft *remotePortRuleDraft) {
	h.await("the rule", func() bool { return p.remote.ports.rule != draft || !draft.starting })
	h.settle()
}

// A host rule listens on the host's loopback address and reaches the target from the host; a target
// outside the host's loopback interface is asked about first. The rule is listed apart from the
// host's ports with where it listens and what it reaches, Stop stops it, and the log names the
// outcomes only.
func TestRemotePortRulesForwardAHostPortToAnotherServer(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	ports := &p.remote.ports

	h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "abc", "db.internal:5432")
	if want := i18n.Shared(lang, "desktop.remote.ports.ruleInvalidListen"); ports.rule.message != want || len(k.ports.rules.hostStarts) != 0 {
		t.Fatal("a host port that is not a number was not refused before Core")
	}
	h.submitRemotePortRule(t, p, "15432", "db.internal:5432")
	if ports.rule == nil || ports.rule.confirm != remotePortRuleConfirmTarget || !h.shows(i18n.Shared(lang, "desktop.remote.ports.confirmTitle")) {
		t.Fatal("the target outside the host's loopback interface was not asked about")
	}
	h.confirmRemotePortRule(t, p)
	starts := k.ports.rules.hostStarts
	want := core.RemoteHostForwardRule{Host: "db.internal", Port: 5432, ListenPort: 15432, AllowNonLoopback: true}
	if len(starts) != 2 || starts[0].AllowNonLoopback || starts[1] != want {
		t.Fatalf("started %+v, want the rule again once its target was confirmed", starts)
	}
	if ports.rule != nil || ports.ruleOpen {
		t.Fatal("the dialog stayed open once the rule ran")
	}
	if got := ports.rules(); len(got) != 1 || len(ports.rows()) != 1 {
		t.Fatalf("rules %d, port rows %d: the rule is not listed apart from the host's ports", len(got), len(ports.rows()))
	}
	if !h.shows(i18n.Shared(lang, "desktop.remote.ports.rulesHeading")) || !h.shows("127.0.0.1:15432") || !h.shows("db.internal:5432") {
		t.Fatal("the rule's host address and target are not shown")
	}

	h.click(center(h.portRowControl("127.0.0.1:15432", i18n.Shared(lang, "desktop.remote.ports.stop"))))
	h.await("the stopped rule", func() bool { return len(ports.rules()) == 0 && len(ports.ruleStopping) == 0 && !ports.recordsBusy })
	h.settle()
	if len(k.ports.forwards[p.remote.session]) != 0 || len(ports.idleRules()) != 1 ||
		!h.shows(i18n.Shared(lang, "desktop.remote.ports.statusNotRunning")) {
		t.Fatal("Stop left the rule running, or the stopped rule is not listed as remembered")
	}
	h.click(center(h.portRowControl("127.0.0.1:15432", i18n.Shared(lang, "desktop.remote.ports.ruleForget"))))
	h.await("the forgotten rule", func() bool { return !ports.recordsBusy })
	h.settle()
	if len(ports.remembered) != 0 || h.shows(i18n.Shared(lang, "desktop.remote.ports.rulesHeading")) {
		t.Fatal("Forget Rule left the rule listed")
	}
	actions := remoteActions(logger)
	for _, action := range []string{"remote.ports.addRule", "remote.ports.ruleHost", "remote.ports.ruleConfirm", "remote.ports.stopRule", "remote.ports.ruleForget"} {
		if !slices.Contains(actions, action) {
			t.Fatalf("performed %q, want %s", actions, action)
		}
	}
	if !rejected(logger, "remote_port_rule", "invalid_listen_port") || !rejected(logger, "remote_port_rule", "target_not_confirmed") {
		t.Fatal("the refused host port and the unconfirmed target were not logged")
	}
	if event := loggedAny(t, logger, remoteTestHost, "db.internal", "15432"); event != "" {
		t.Fatalf("logged the host, the target or the port: %s", event)
	}
}

// Every interface is asked about each time a rule wants it: Back starts nothing and is logged as
// declined, the next attempt asks again, and the rule that runs reads in the warning colour with a
// tooltip that says who can reach it. A new dialog never keeps the choice.
func TestRemotePortRulesAskEveryTimeBeforeListeningOnEveryInterface(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k)
	ports := &p.remote.ports
	question := i18n.Shared(lang, "desktop.remote.ports.ruleConfirmAllTitle")

	draft := h.openRemotePortRule(t, p)
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.ports.ruleAllInterfaces"))
	h.settle()
	if !draft.allInterfaces || !h.showsWrapped(i18n.Shared(lang, "desktop.remote.ports.ruleAllInterfacesNote")) {
		t.Fatal("the checkbox did not choose every interface with its warning")
	}
	h.submitRemotePortRule(t, p, "", "5432")
	if draft.confirm != remotePortRuleConfirmAll || !h.shows(question) {
		t.Fatal("every interface was not asked about")
	}
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.ruleBack"))))
	h.settle()
	if draft.confirm != remotePortRuleNoConfirm || len(k.ports.rules.hostStarts) != 0 || !rejected(logger, "remote_port_rule", "all_interfaces_declined") {
		t.Fatal("Back started the rule or was not logged as declined")
	}
	h.click(center(h.popupHit(i18n.Shared(lang, "desktop.remote.ports.ruleSubmit"))))
	h.awaitRemotePortRule(p, draft)
	if draft.confirm != remotePortRuleConfirmAll {
		t.Fatal("the second attempt was not asked about again")
	}
	h.confirmRemotePortRule(t, p)
	starts := k.ports.rules.hostStarts
	if len(starts) != 1 || starts[0] != (core.RemoteHostForwardRule{Host: "localhost", Port: 5432, AllInterfaces: true}) {
		t.Fatalf("started %+v, want one rule on every interface", starts)
	}
	rules := ports.rules()
	if len(rules) != 1 || !rules[0].AllInterfaces {
		t.Fatal("the rule on every interface is not listed")
	}
	listen := remotePortRuleListenAddress(rules[0])
	tip := i18n.Shared(lang, "desktop.remote.ports.ruleAllInterfacesTip")
	hits := h.driver.Snapshot().Hits
	if !h.shows(listen) || !slices.ContainsFunc(hits, func(hit gfx.Hit) bool { return hit.Label == listen && hit.Value == tip }) {
		t.Fatal("the rule on every interface does not say who can reach it")
	}

	if draft := h.openRemotePortRule(t, p); draft.allInterfaces {
		t.Fatal("a new dialog kept every interface")
	}
}

// Reverse rules are offered only when the remote preferences allow them, and each one is asked about
// before it starts. A reverse rule Core refuses because the preferences changed meanwhile brings the
// dialog back to host rules.
func TestRemotePortRulesForwardBackToThisComputerOnlyWhenAllowed(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k)
	ports := &p.remote.ports
	off := i18n.Shared(lang, "desktop.remote.ports.ruleReverseOff")

	draft := h.openRemotePortRule(t, p)
	if draft.reverseAllowed || !h.showsWrapped(off) {
		t.Fatal("reverse rules were offered without the preferences allowing them")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.ports.ruleCancel"))
	h.settle()
	if ports.rule != nil || ports.ruleOpen {
		t.Fatal("Cancel did not close the dialog")
	}

	k.set(func(k *remoteHostKernel) { k.ports.rules.allowReverse = true })
	draft = h.openRemotePortRule(t, p)
	if !draft.reverseAllowed || h.showsWrapped(off) {
		t.Fatal("reverse rules were not offered once the preferences allowed them")
	}
	draft.kind = remotePortRuleReverse
	h.submitRemotePortRule(t, p, "", "3000")
	if draft.confirm != remotePortRuleConfirmReverse || !h.shows(i18n.Shared(lang, "desktop.remote.ports.ruleConfirmReverseTitle")) || len(k.ports.rules.reverseStarts) != 0 {
		t.Fatal("the reverse rule started without being asked about")
	}
	h.confirmRemotePortRule(t, p)
	if got := k.ports.rules.reverseStarts; len(got) != 1 || got[0] != (core.RemoteReverseForwardRule{LocalPort: 3000}) {
		t.Fatalf("started %+v, want one reverse rule to local port 3000", got)
	}
	rules := ports.rules()
	this := i18n.SharedFormat(lang, "desktop.remote.ports.ruleThisComputer", map[string]string{"address": "127.0.0.1:3000"})
	if len(rules) != 1 || rules[0].Kind != core.RemoteForwardReverse || !h.shows(this) || !h.shows(remotePortRuleListenAddress(rules[0])) {
		t.Fatal("the reverse rule is not listed with the port of this computer")
	}

	draft = h.openRemotePortRule(t, p)
	k.set(func(k *remoteHostKernel) { k.ports.rules.allowReverse = false })
	draft.kind = remotePortRuleReverse
	h.submitRemotePortRule(t, p, "", "3001")
	h.confirmRemotePortRule(t, p)
	if draft.kind != remotePortRuleHost || draft.reverseAllowed || draft.message != off || len(ports.rules()) != 1 {
		t.Fatal("a reverse rule Core refused did not bring the dialog back to host rules")
	}
	if !rejected(logger, "remote_port_rule", "reverse_disabled") || !slices.Contains(remoteActions(logger), "remote.ports.ruleReverse") {
		t.Fatal("the reverse rules were not logged")
	}
}

// A host port Core refuses is reported by its reason and never replaced by another one: taken,
// refused by the host, a remote server that cannot listen, and the session's limit, which counts
// the forwards of this computer too.
func TestRemotePortRulesReportWhyAHostPortWasRefused(t *testing.T) {
	h, k, _, logger := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k, core.RemoteListeningPort{Address: "127.0.0.1", Port: 8080})
	ports := &p.remote.ports
	h.click(center(h.portRowControl("127.0.0.1:8080", i18n.Shared(lang, "desktop.remote.ports.forward"))))
	h.await("the forward", func() bool { return len(ports.forwards) == 1 && len(ports.busy) == 0 })
	h.settle()
	k.set(func(k *remoteHostKernel) {
		k.ports.limit = 2
		k.ports.rules.inUse = map[uint16]bool{8000: true}
		k.ports.rules.denied = map[uint16]bool{80: true}
	})

	draft := h.openRemotePortRule(t, p)
	cases := []struct {
		listen string
		want   string
		before func(k *remoteHostKernel)
	}{
		{"8000", i18n.SharedFormat(lang, "desktop.remote.ports.rulePortInUse", map[string]string{"port": "8000"}), nil},
		{"80", i18n.SharedFormat(lang, "desktop.remote.ports.rulePortDenied", map[string]string{"port": "80"}), nil},
		{"9000", i18n.Shared(lang, "desktop.remote.ports.ruleUnsupported"), func(k *remoteHostKernel) { k.ports.rules.unsupported = true }},
	}
	for _, c := range cases {
		if c.before != nil {
			k.set(c.before)
		}
		h.submitRemotePortRule(t, p, c.listen, "5432")
		if draft.message != c.want || !h.showsWrapped(c.want) || ports.rule != draft {
			t.Fatalf("host port %s: the dialog does not report why it was refused", c.listen)
		}
	}
	k.set(func(k *remoteHostKernel) { k.ports.rules.unsupported = false })
	h.submitRemotePortRule(t, p, "9000", "5432")
	if len(ports.rules()) != 1 {
		t.Fatal("the rule did not start once the host could listen")
	}
	draft = h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "9001", "5432")
	limit := i18n.SharedFormat(lang, "desktop.remote.ports.limit", map[string]string{"maximum": "2"})
	if draft.message != limit || len(ports.forwards) != 2 {
		t.Fatal("the session's limit was not reported for a rule")
	}
	for _, port := range []uint16{8000, 80} {
		for _, forward := range ports.forwards {
			if forward.HostListenPort == port {
				t.Fatalf("a rule moved from the refused host port %d", port)
			}
		}
	}
	if got := countFailures(logger, "remote_port_rule"); got != 4 {
		t.Fatalf("remote_port_rule failed %d times, want 4", got)
	}
}

// Rules belong to the session: Stop All Forwards stops them with the forwards of this computer, and
// a lost session takes them with it without the window starting them again on the new one; the
// window still lists them as remembered, each with Start.
func TestRemotePortRulesEndWithTheSessionAndAreNotRestored(t *testing.T) {
	h, k, timers, _ := remoteWorkspaceHarness(t)
	lang := h.app.language()
	p := h.openRemotePortsWindow(t, k)
	r := p.remote
	ports := &r.ports

	h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "", "5432")
	h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "", "6379")
	if len(ports.rules()) != 2 {
		t.Fatal("the rules did not start")
	}
	h.clickLabeled(i18n.Shared(lang, "desktop.remote.ports.stopAll"))
	h.await("Stop All Forwards", func() bool { return !ports.stoppingAll && len(ports.forwards) == 0 })
	h.settle()
	if len(k.ports.forwards[r.session]) != 0 || len(ports.ruleStopping) != 0 {
		t.Fatal("Stop All Forwards left a rule running")
	}

	h.openRemotePortRule(t, p)
	h.submitRemotePortRule(t, p, "", "5432")
	started := len(k.ports.rules.hostStarts)
	h.openRemotePortRule(t, p)
	k.set(func(k *remoteHostKernel) {
		k.once = &core.Error{Command: "remote.serverState", Code: core.CodeConnectionClosed, Message: "closed"}
	})
	h.fireAfter(t, timers, remoteHeartbeatInterval)
	h.fireReconnect(t, timers, r)
	h.await("the new session's reading", func() bool {
		return r.session == "session-2" && !r.beating && r.ports.listed && !p.tree.reading && !ports.recordsBusy
	})
	h.settle()
	if len(ports.rules()) != 0 || ports.rule != nil || ports.ruleOpen {
		t.Fatal("the lost session's rule or dialog outlived it")
	}
	if len(ports.idleRules()) != 2 || !h.shows(i18n.Shared(lang, "desktop.remote.ports.statusNotRunning")) ||
		!h.hasControl(i18n.Shared(lang, "desktop.remote.ports.ruleStart")) {
		t.Fatal("the rules of the lost session are not listed as remembered with Start")
	}
	if got := len(k.ports.rules.hostStarts); got != started {
		t.Fatalf("%d rules started after the reconnect, want none", got-started)
	}
}
