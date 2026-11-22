package workbench

import (
	"context"
	"net"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file is the forwarding rules of the Ports window (#2231 D10 T3, T4): forwards that listen
// on the host instead of on this computer.
//
//   - A host rule makes the host listen on a port and connect every connection to another server
//     itself, as ssh -L on a jump host does; the bytes never cross the session. It listens on the
//     host's loopback address unless the user chooses every interface, which the window confirms
//     each time and never remembers. A target outside the host's loopback interface needs the
//     same confirmation as a local forward (S28).
//   - A reverse rule makes the host listen on its loopback address and brings every connection
//     back to a port on this computer's loopback address. It is offered only when the remote
//     preferences allow reverse forwards (Settings › Tools › Remote Workspace), which they do not
//     by default, and every rule is confirmed before it starts; Core checks the preferences again.
//
// Rules belong to the session like every forward: Core stops them when it ends, and the window
// never starts them again on its own. It remembers every rule that started (remote_port_records.go)
// and lists the ones not running with Start, which opens this dialog filled in with the rule, so
// every question is asked again. A rule never moves to another host port: a taken one is refused. The log names the outcome only, never an address, a URL or a process.

// remotePortRuleKind is the direction of a rule the dialog adds.
type remotePortRuleKind int

const (
	// remotePortRuleHost forwards a host port to another server.
	remotePortRuleHost remotePortRuleKind = iota
	// remotePortRuleReverse forwards a host port back to this computer.
	remotePortRuleReverse
)

// remotePortRuleConfirm is the question the dialog asks before a rule starts.
type remotePortRuleConfirm int

const (
	remotePortRuleNoConfirm remotePortRuleConfirm = iota
	// remotePortRuleConfirmAll asks before a host rule listens on every interface of the host.
	remotePortRuleConfirmAll
	// remotePortRuleConfirmTarget asks before a host rule reaches a target outside the host's
	// loopback interface (S28).
	remotePortRuleConfirmTarget
	// remotePortRuleConfirmReverse asks before a reverse rule opens a host port to this computer.
	remotePortRuleConfirmReverse
)

// remotePortRuleDraft is the Add Forwarding Rule dialog of the Ports window.
type remotePortRuleDraft struct {
	kind remotePortRuleKind
	// listen is the host port typed, empty for one the host chooses; target is the address a host
	// rule reaches, typed as in the window's field, or the local port a reverse rule reaches.
	listen ui.Field
	target ui.Field
	// allInterfaces asks a host rule to listen on every interface of the host.
	allInterfaces bool
	// reverseAllowed is set once the remote preferences read when the dialog opened allow reverse
	// rules; until then, and when they do not, only host rules are offered.
	reverseAllowed bool
	// message is why the last attempt was refused or failed, "" for none.
	message string
	// starting is set while Core reads the address or starts the rule.
	starting bool
	// confirm is the question waiting for the user; host and reverse are the rule it is about.
	confirm remotePortRuleConfirm
	host    core.RemoteHostForwardRule
	reverse core.RemoteReverseForwardRule
}

// rules are the session's host and reverse forwards, by id.
func (ports *remotePorts) rules() []core.RemoteForward {
	var rules []core.RemoteForward
	for _, forward := range ports.forwards {
		if !forward.IsLocal() {
			rules = append(rules, forward)
		}
	}
	return rules
}

// setRuleStopping records that the rule id is being stopped, or that it no longer is.
func (ports *remotePorts) setRuleStopping(id uint64, stopping bool) {
	if !stopping {
		delete(ports.ruleStopping, id)
		return
	}
	if ports.ruleStopping == nil {
		ports.ruleStopping = map[uint64]bool{}
	}
	ports.ruleStopping[id] = true
}

// setRuleFailed records why the last stop of the rule id failed, or that it did not for "".
func (ports *remotePorts) setRuleFailed(id uint64, reason string) {
	if reason == "" {
		delete(ports.ruleFailed, id)
		return
	}
	if ports.ruleFailed == nil {
		ports.ruleFailed = map[uint64]string{}
	}
	ports.ruleFailed[id] = reason
}

// openRemotePortRule opens the Add Forwarding Rule dialog, filled in with the remembered rule from
// when it is not nil, and reads whether the remote preferences allow reverse rules. A remembered
// reverse rule falls back to an empty host rule when they do not.
func (a *App) openRemotePortRule(p *project, from *core.RemotePortRule, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" {
		// log-exempt: 非用户操作：没有会话，按钮此时不可用。
		return
	}
	draft := &remotePortRuleDraft{}
	if from != nil {
		a.performed("remote.ports.ruleStart", surface)
		draft = remotePortRuleDraftOf(*from)
	} else {
		a.performed("remote.ports.addRule", surface)
	}
	r.ports.rule, r.ports.ruleOpen = draft, true
	kernel, root := a.kernel, a.globalToolchainRoot()
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		allowed, err := remoteReverseAllowed(ctx, kernel, root)
		return func(a *App) {
			if r.ports.rule != draft {
				// log-exempt: 用户取消：对话框已关闭，读到的设置不再适用。
				return
			}
			if err != nil {
				// A damaged preference document allows nothing; the settings page reports it.
				a.backgroundFailed("remote_port_rule_preferences", remoteLogError(err))
			}
			draft.reverseAllowed = allowed && err == nil
			if !draft.reverseAllowed && draft.kind == remotePortRuleReverse {
				draft.kind = remotePortRuleHost
				draft.target.SetText("")
			}
		}
	})
}

// remoteReverseAllowed is whether the remote preferences under root allow reverse forwards. It
// runs off the window thread; root is a.globalToolchainRoot() read on it.
func remoteReverseAllowed(ctx context.Context, kernel Kernel, root string) (bool, error) {
	document, err := remotePreferencesDocument(ctx, kernel, root)
	if err != nil {
		return false, err
	}
	state, err := kernel.RemotePreferences(ctx, document, "")
	if err != nil {
		return false, err
	}
	return state.Reverse.Allowed, nil
}

// remotePortRuleListen reads the host port typed into the dialog: 0 for an empty field, which
// lets the host choose one; ok is false for text that is not a port.
func remotePortRuleListen(text string) (port uint16, ok bool) {
	text = strings.TrimSpace(text)
	if text == "" {
		return 0, true
	}
	n, err := strconv.ParseUint(text, 10, 16)
	return uint16(n), err == nil && n != 0
}

// submitRemotePortRule checks the dialog's fields and asks what the rule needs confirmed: a reverse
// rule always, a host rule once Core read its target and only when it listens on every interface.
func (a *App) submitRemotePortRule(p *project, surface actionSurface) {
	r := p.remote
	draft := r.ports.rule
	if r.closed || r.session == "" || draft == nil || draft.starting || draft.confirm != remotePortRuleNoConfirm {
		// log-exempt: 非用户操作：没有会话、对话框已关闭或上一次添加还在进行，按钮此时不可用。
		return
	}
	language := a.language()
	listen, ok := remotePortRuleListen(draft.listen.Text())
	if !ok {
		a.operationRejected("remote_port_rule", "invalid_listen_port")
		draft.message = i18n.Shared(language, "desktop.remote.ports.ruleInvalidListen")
		return
	}
	draft.message = ""
	if draft.kind == remotePortRuleReverse {
		if !draft.reverseAllowed {
			// log-exempt: 非用户操作：设置不允许反向转发时这个方向不会出现在对话框里。
			return
		}
		n, err := strconv.ParseUint(strings.TrimSpace(draft.target.Text()), 10, 16)
		if err != nil || n == 0 {
			a.operationRejected("remote_port_rule", "invalid_local_port")
			draft.message = i18n.Shared(language, "desktop.remote.ports.localInvalid")
			return
		}
		a.performed("remote.ports.ruleReverse", surface)
		draft.reverse = core.RemoteReverseForwardRule{LocalPort: uint16(n), ListenPort: listen}
		draft.confirm = remotePortRuleConfirmReverse
		return
	}
	text := strings.TrimSpace(draft.target.Text())
	if text == "" {
		// log-exempt: 非用户操作：目标为空，按钮此时不可用。
		return
	}
	a.performed("remote.ports.ruleHost", surface)
	draft.starting = true
	kernel := a.kernel
	all := draft.allInterfaces
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		address, err := kernel.RemoteParseForwardAddress(ctx, text)
		return func(a *App) {
			if r.ports.rule != draft {
				// log-exempt: 用户取消：对话框已关闭，这次解析的结果不再适用。
				return
			}
			draft.starting = false
			if _, reason, refused := core.RemoteConnectionFieldError(err); refused {
				a.operationRejected("remote_port_rule", remotePortsAddRejection(reason))
				draft.message = i18n.Shared(a.language(), "desktop.remote.ports.invalidTarget")
				if reason == "credentials" {
					draft.message = i18n.Shared(a.language(), "desktop.remote.ports.addCredentials")
				}
				return
			}
			if err != nil {
				a.operationFailed("remote_port_rule", remoteLogError(err))
				draft.message = i18n.SharedFormat(a.language(), "desktop.remote.ports.statusFailed",
					map[string]string{"reason": remotePortsReason(err)})
				return
			}
			draft.host = core.RemoteHostForwardRule{Host: address.TargetHost, Port: address.TargetPort, ListenPort: listen, AllInterfaces: all}
			if all {
				draft.confirm = remotePortRuleConfirmAll
				return
			}
			a.startRemotePortRule(p)
		}
	})
}

// confirmRemotePortRule starts the rule the user confirmed. A host rule's target is confirmed with
// its own question once Core reports that it is outside the host's loopback interface.
func (a *App) confirmRemotePortRule(p *project, surface actionSurface) {
	draft := p.remote.ports.rule
	if draft == nil || draft.confirm == remotePortRuleNoConfirm {
		// log-exempt: 非用户操作：没有等待确认的问题，按钮此时不显示。
		return
	}
	a.performed("remote.ports.ruleConfirm", surface)
	if draft.confirm == remotePortRuleConfirmTarget {
		draft.host.AllowNonLoopback = true
	}
	draft.confirm = remotePortRuleNoConfirm
	a.startRemotePortRule(p)
}

// declineRemotePortRule goes back from a question to the dialog's fields; nothing starts.
func (a *App) declineRemotePortRule(p *project) {
	draft := p.remote.ports.rule
	if draft == nil || draft.confirm == remotePortRuleNoConfirm {
		// log-exempt: 非用户操作：没有等待确认的问题，按钮此时不显示。
		return
	}
	a.operationRejected("remote_port_rule", remotePortRuleDeclined(draft.confirm))
	draft.confirm = remotePortRuleNoConfirm
	draft.host.AllowNonLoopback = false
}

// remotePortRuleDeclined is the log reason of a question the user declined.
func remotePortRuleDeclined(confirm remotePortRuleConfirm) string {
	switch confirm {
	case remotePortRuleConfirmAll:
		return "all_interfaces_declined"
	case remotePortRuleConfirmTarget:
		return "target_declined"
	}
	return "reverse_declined"
}

// startRemotePortRule starts the dialog's rule over p's session. A reverse rule takes the current
// preference document along, for Core to check that reverse forwards are still allowed.
func (a *App) startRemotePortRule(p *project) {
	r := p.remote
	draft := r.ports.rule
	if r.closed || r.session == "" || draft == nil {
		// log-exempt: 用户取消：会话已结束或对话框已关闭。
		return
	}
	draft.starting, draft.message = true, ""
	session, kernel, root := r.session, a.kernel, a.globalToolchainRoot()
	kind, host, reverse := draft.kind, draft.host, draft.reverse
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		var forward core.RemoteForward
		var err error
		if kind == remotePortRuleReverse {
			var document *string
			if document, err = remotePreferencesDocument(ctx, kernel, root); err == nil {
				forward, _, err = kernel.RemoteStartReverseForward(ctx, session, reverse, document)
			}
		} else {
			forward, _, err = kernel.RemoteStartHostForward(ctx, session, host)
		}
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			if err == nil {
				// The rule runs even when the dialog was closed meanwhile, and is remembered.
				r.ports.putForward(forward)
				a.rememberRemotePortRule(p, remotePortRuleRecord(kind, host, reverse))
			}
			if r.ports.rule != draft {
				if err != nil {
					a.operationFailed("remote_port_rule", remoteLogError(err))
				}
				return
			}
			draft.starting = false
			a.remotePortRuleStarted(p, session, draft, err)
		}
	})
}

// remotePortRuleStarted records how starting the dialog's rule over session ended: the dialog
// closes once it runs, and shows why it did not otherwise.
func (a *App) remotePortRuleStarted(p *project, session string, draft *remotePortRuleDraft, err error) {
	ports := &p.remote.ports
	language := a.language()
	port := strconv.Itoa(int(draft.host.ListenPort))
	if draft.kind == remotePortRuleReverse {
		port = strconv.Itoa(int(draft.reverse.ListenPort))
	}
	switch code := remotePortsCode(err); {
	case err == nil:
		ports.rule, ports.ruleOpen = nil, false
	case code == core.CodeForwardTargetNotConfirmed:
		a.operationRejected("remote_port_rule", "target_not_confirmed")
		draft.confirm = remotePortRuleConfirmTarget
	case code == core.CodeConnectionClosed:
		a.loseRemote(p, session, err)
	case code == core.CodeReverseForwardDisabled:
		a.operationRejected("remote_port_rule", "reverse_disabled")
		draft.reverseAllowed, draft.kind = false, remotePortRuleHost
		draft.message = i18n.Shared(language, "desktop.remote.ports.ruleReverseOff")
	case code == core.CodeForwardHostPortInUse:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		draft.message = i18n.SharedFormat(language, "desktop.remote.ports.rulePortInUse", map[string]string{"port": port})
	case code == core.CodeForwardHostPortDenied:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		draft.message = i18n.SharedFormat(language, "desktop.remote.ports.rulePortDenied", map[string]string{"port": port})
	case code == core.CodeForwardHostUnsupported:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		draft.message = i18n.Shared(language, "desktop.remote.ports.ruleUnsupported")
	case code == core.CodeForwardLimitReached:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		draft.message = i18n.SharedFormat(language, "desktop.remote.ports.limit",
			map[string]string{"maximum": strconv.Itoa(remotePortsLimit(err, len(ports.forwards)))})
	case code == core.CodeInvalidRequest:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		switch field, _, _ := core.RemoteConnectionFieldError(err); field {
		case "listenPort":
			draft.message = i18n.Shared(language, "desktop.remote.ports.ruleInvalidListen")
		case "localPort":
			draft.message = i18n.Shared(language, "desktop.remote.ports.localInvalid")
		default:
			draft.message = i18n.Shared(language, "desktop.remote.ports.invalidTarget")
		}
	default:
		a.operationFailed("remote_port_rule", remoteLogError(err))
		draft.message = i18n.SharedFormat(language, "desktop.remote.ports.statusFailed",
			map[string]string{"reason": remotePortsReason(err)})
	}
}

// stopRemotePortRule stops the rule id.
func (a *App) stopRemotePortRule(p *project, id uint64, surface actionSurface) {
	r := p.remote
	if r == nil || r.closed || r.session == "" || r.ports.ruleStopping[id] || r.ports.stoppingAll {
		// log-exempt: 非用户操作：没有会话或这条规则已在停止，按钮此时不可用。
		return
	}
	a.performed("remote.ports.stopRule", surface)
	ports := &r.ports
	ports.setRuleStopping(id, true)
	ports.setRuleFailed(id, "")
	session, kernel := r.session, a.kernel
	a.background(p, remotePortsTimeout, func(ctx context.Context) func(*App) {
		_, err := kernel.RemoteStopForward(ctx, session, id)
		return func(a *App) {
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭或会话已结束，会话结束时 Core 已停止它的转发。
				return
			}
			ports.setRuleStopping(id, false)
			switch {
			case err == nil:
				ports.dropForward(id)
			case remoteConnectionClosed(err):
				a.loseRemote(p, session, err)
			default:
				a.operationFailed("remote_port_stop", remoteLogError(err))
				ports.setRuleFailed(id, remotePortsReason(err))
			}
		}
	})
}

// remotePortRuleListenAddress is where rule listens on the host, as host:port.
func remotePortRuleListenAddress(rule core.RemoteForward) string {
	return net.JoinHostPort(rule.HostListenHost, strconv.Itoa(int(rule.HostListenPort)))
}

// remotePortRuleTarget is what rule reaches: the target as the host resolves it, or the port on
// this computer for a reverse rule.
func remotePortRuleTarget(language i18n.Language, rule core.RemoteForward) string {
	if rule.Kind == core.RemoteForwardReverse {
		return i18n.SharedFormat(language, "desktop.remote.ports.ruleThisComputer",
			map[string]string{"address": net.JoinHostPort(rule.LocalHost, strconv.Itoa(int(rule.LocalPort)))})
	}
	return net.JoinHostPort(rule.TargetHost, strconv.Itoa(int(rule.TargetPort)))
}
