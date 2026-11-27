package settingswindow

import (
	"errors"
	"slices"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// reconnectAutomatic is the reconnect choice that removes the saved limit; the others are seconds.
const reconnectAutomatic = -1

// reconnectChoices are the reconnect limits offered besides a saved one, in seconds; Core accepts
// 0 to 3600.
var reconnectChoices = []int{reconnectAutomatic, 0, 15, 30, 60, 120, 300, 600, 1800, 3600}

// remoteWorkspacePage shows the remote workspace preferences as Core read them from the preference
// directory and what each automatic value resolves to. Opening it only reads; a change is a draft
// the footer's Apply writes.
func (w *window) remoteWorkspacePage(c ui.C) {
	r := w.toolchains.prefs
	language := w.marketLanguage()
	r.ensureLoaded()
	w.pageScroll(c, pageRemoteWorkspace, func() {
		if !r.loaded {
			if r.readFailed == nil {
				ui.Row(c.Part("loading")).FillWidth().Height(28).Items(ui.Center).Children(func() {
					ui.Text(c, i18n.Shared(language, "desktop.toolchains.loading")).FontSize(12).Color(w.pal.muted)
				})
			}
			w.remotePreferencesNotices(c, language, r)
			return
		}
		w.card(c.Part("connection"), i18n.Shared(language, "desktop.remoteSettings.connection"), "", func() {
			w.remoteProgramRow(c.Part("program"), language, r)
			w.remoteSSHConfigRow(c, language, r)
		})
		w.card(c.Part("reconnection"), i18n.Shared(language, "desktop.remoteSettings.reconnection"), "", func() {
			w.remoteReconnectRow(c.Part("reconnect"), language, r)
		})
		w.card(c.Part("forwarding"), i18n.Shared(language, "desktop.remoteSettings.forwarding"), "", func() {
			w.remoteReverseRow(c.Part("reverse"), language, r)
		})
		w.card(c.Part("closing"), i18n.Shared(language, "desktop.remoteSettings.closing"), "", func() {
			w.remoteCloseRow(c.Part("close-programs"), language, r)
			w.remoteIdleTimeoutRow(c, language, r)
		})
		w.card(c.Part("storage"), i18n.Shared(language, "desktop.remoteSettings.storage"), "", func() {
			title := i18n.Shared(language, "desktop.remoteSettings.storage")
			note := ""
			if !r.source.Saved.Exists() {
				note = i18n.Shared(language, "desktop.remoteSettings.storageNone")
			}
			w.settingsRow(c.Part("storage-row"), title, i18n.Shared(language, "desktop.remoteSettings.storageHelp"), func() {
				w.remotePathText(c.Part("storage-path"), r.source.Saved.Path(), note)
			})
		})
		w.remotePreferencesNotices(c, language, r)
	})
}

// remoteProgramRow chooses the OpenSSH client: Automatic, naming the ssh found on PATH, or a file
// the user picked. A saved program that went missing or lost its executable bit is reported under
// the row.
func (w *window) remoteProgramRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	title := i18n.Shared(language, "desktop.remoteSettings.sshProgram")
	shown := r.shownProgram()
	saved := r.source.Saved.State.Preferences.SSHProgram
	choices := []string{""}
	for _, path := range []*string{saved, shown} {
		if path != nil && *path != "" && !slices.Contains(choices, *path) {
			choices = append(choices, *path)
		}
	}
	value := ""
	if shown != nil {
		value = *shown
	}
	label := func(path string) string {
		if path != "" {
			return path
		}
		automatic := r.source.Automatic.SSH
		if automatic.Status != core.RemoteProgramFound || automatic.Path == nil {
			return i18n.Shared(language, "desktop.remoteSettings.programAutomaticMissing")
		}
		return i18n.SharedFormat(language, "desktop.remoteSettings.programAutomatic", map[string]string{"path": *automatic.Path})
	}
	busy := r.busy()
	w.settingsRow(c, title, i18n.Shared(language, "desktop.remoteSettings.sshProgramHelp"), func() {
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Center).Children(func() {
			if ui.Select(c.Part("program"), &value, choices, label).Grow(1).Shrink(1).MinWidth(0).Label(title).Disabled(busy).Changed() {
				if value == "" {
					r.setProgram(nil)
				} else {
					path := value
					r.setProgram(&path)
				}
			}
			if w.button(c.Part("choose"), buttonSmall, i18n.Shared(language, "desktop.remoteSettings.chooseProgram"), busy) {
				// The native picker runs a modal message loop on Windows, so it must run after paint.
				c.After(func() { w.pickRemoteProgram(language, r) })
			}
		})
	})
	ssh := r.source.Saved.State.SSH
	if r.programSet || ssh.Source != core.RemotePreferenceFromSetting || ssh.Path == nil {
		return
	}
	switch ssh.Status {
	case core.RemoteProgramMissing:
		ui.Wrap(c, i18n.SharedFormat(language, "desktop.remoteSettings.programMissing", map[string]string{"path": *ssh.Path})).FontSize(12).Color(w.pal.danger)
	case core.RemoteProgramNotExecutable:
		ui.Wrap(c, i18n.SharedFormat(language, "desktop.remoteSettings.programNotExecutable", map[string]string{"path": *ssh.Path})).FontSize(12).Color(w.pal.danger)
	}
}

// remoteSSHConfigRow names the user's OpenSSH configuration file; Lithe only reads it.
func (w *window) remoteSSHConfigRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	config := r.source.Saved.State.SSHConfig
	if config == nil {
		return
	}
	note := ""
	if !config.Exists {
		note = i18n.Shared(language, "desktop.remoteSettings.sshConfigMissing")
	}
	w.settingsRow(c.Part("ssh-config"), i18n.Shared(language, "desktop.remoteSettings.sshConfig"), i18n.Shared(language, "desktop.remoteSettings.sshConfigHelp"), func() {
		w.remotePathText(c.Part("path"), config.Path, note)
	})
}

// remoteReconnectRow chooses how long a lost connection is retried: Automatic, naming Core's
// default, never, or a time; a saved time that is not among the choices is listed too.
func (w *window) remoteReconnectRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	title := i18n.Shared(language, "desktop.remoteSettings.reconnectLimit")
	value := reconnectAutomatic
	if shown := r.shownLimit(); shown != nil {
		value = int(*shown)
	}
	choices := reconnectChoices
	for _, limit := range []*uint32{r.source.Saved.State.Preferences.ReconnectLimitSeconds, r.shownLimit()} {
		if limit != nil && !slices.Contains(choices, int(*limit)) {
			choices = append(append([]int{}, choices...), int(*limit))
		}
	}
	label := func(seconds int) string {
		switch seconds {
		case reconnectAutomatic:
			return i18n.SharedFormat(language, "desktop.remoteSettings.reconnectAutomatic", map[string]string{
				"duration": remoteDuration(language, int(r.source.Automatic.Reconnect.LimitSeconds)),
			})
		case 0:
			return i18n.Shared(language, "desktop.remoteSettings.reconnectNever")
		}
		return remoteDuration(language, seconds)
	}
	w.settingsRow(c, title, i18n.Shared(language, "desktop.remoteSettings.reconnectLimitHelp"), func() {
		if ui.Select(c.Part("limit"), &value, choices, label).FillWidth().Label(title).Disabled(r.busy()).Changed() {
			if value == reconnectAutomatic {
				r.setLimit(nil)
			} else {
				seconds := uint32(value)
				r.setLimit(&seconds)
			}
		}
	})
}

// Choices of the reverse forwarding row: Automatic, which refuses them, allowed and refused.
const (
	reverseAutomatic = iota
	reverseAllowed
	reverseRefused
)

// remoteReverseRow chooses whether the Ports window may add rules that bring a host port back to
// this computer. Automatic names what it resolves to, which is refused.
func (w *window) remoteReverseRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	title := i18n.Shared(language, "desktop.remoteSettings.reverseForwarding")
	value := reverseAutomatic
	if shown := r.shownReverse(); shown != nil {
		value = reverseRefused
		if *shown {
			value = reverseAllowed
		}
	}
	allowedText := func(allowed bool) string {
		if allowed {
			return i18n.Shared(language, "desktop.remoteSettings.reverseAllowed")
		}
		return i18n.Shared(language, "desktop.remoteSettings.reverseRefused")
	}
	label := func(choice int) string {
		switch choice {
		case reverseAllowed:
			return allowedText(true)
		case reverseRefused:
			return allowedText(false)
		}
		return i18n.SharedFormat(language, "desktop.remoteSettings.reverseAutomatic", map[string]string{
			"value": allowedText(r.source.Automatic.Reverse.Allowed),
		})
	}
	w.settingsRow(c, title, i18n.Shared(language, "desktop.remoteSettings.reverseForwardingHelp"), func() {
		choices := []int{reverseAutomatic, reverseAllowed, reverseRefused}
		if ui.Select(c.Part("reverse"), &value, choices, label).FillWidth().Label(title).Disabled(r.busy()).Changed() {
			switch value {
			case reverseAutomatic:
				r.setReverse(nil)
			default:
				allowed := value == reverseAllowed
				r.setReverse(&allowed)
			}
		}
	})
}

// remoteCloseRow chooses what closing a remote workspace does to the programs still running on
// the host: Automatic, which asks every time, End them or Keep on host. A saved "ask" is listed
// as its own choice so the row shows what the file holds; Remember my choice in the close
// question writes End or Keep here (workbench, remote_close.go).
func (w *window) remoteCloseRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	title := i18n.Shared(language, "desktop.remoteSettings.closePrograms")
	value := core.RemoteClosePrograms("")
	if shown := r.shownClosing(); shown != nil {
		value = *shown
	}
	choices := []core.RemoteClosePrograms{"", core.RemoteCloseEnd, core.RemoteCloseKeep}
	for _, programs := range []*core.RemoteClosePrograms{r.source.Saved.State.Preferences.ClosePrograms, r.shownClosing()} {
		if programs != nil && !slices.Contains(choices, *programs) {
			choices = append(choices, *programs)
		}
	}
	label := func(programs core.RemoteClosePrograms) string {
		switch programs {
		case "":
			return i18n.Shared(language, "desktop.remoteSettings.closeAsk")
		case core.RemoteCloseEnd:
			return i18n.Shared(language, "desktop.remoteSettings.closeEnd")
		case core.RemoteCloseKeep:
			return i18n.Shared(language, "desktop.remoteSettings.closeKeep")
		}
		return i18n.Shared(language, "desktop.remoteSettings.closeAskSaved")
	}
	w.settingsRow(c, title, i18n.Shared(language, "desktop.remoteSettings.closeProgramsHelp"), func() {
		if ui.Select(c.Part("programs"), &value, choices, label).FillWidth().Label(title).Disabled(r.busy()).Changed() {
			if value == "" {
				r.setClosing(nil)
			} else {
				programs := value
				r.setClosing(&programs)
			}
		}
	})
}

// remoteIdleTimeoutRow shows how long the host keeps a session whose connection was lost, as the
// remote server reports it; nothing on this machine changes it.
func (w *window) remoteIdleTimeoutRow(c ui.C, language i18n.Language, r *remotePreferencesState) {
	seconds := r.source.Saved.State.Closing.IdleTimeoutSeconds
	if seconds == 0 {
		return
	}
	w.settingsRow(c.Part("idle-timeout"), i18n.Shared(language, "desktop.remoteSettings.idleTimeout"), i18n.Shared(language, "desktop.remoteSettings.idleTimeoutHelp"), func() {
		ui.Text(c, remoteDuration(language, int(seconds))).FontSize(12).Color(w.pal.text)
	})
}

// remoteDuration is a time in whole minutes when it is one, else in seconds.
func remoteDuration(language i18n.Language, seconds int) string {
	if seconds >= 60 && seconds%60 == 0 {
		return i18n.SharedFormat(language, "desktop.remoteSettings.minutes", map[string]string{"count": strconv.Itoa(seconds / 60)})
	}
	return i18n.SharedFormat(language, "desktop.remoteSettings.seconds", map[string]string{"count": strconv.Itoa(seconds)})
}

// remotePathText is a local path the row's width may cut, with the whole path as its tooltip, and
// a note such as "does not exist" after it that the width never cuts.
func (w *window) remotePathText(c ui.C, path, note string) {
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(8).Items(ui.Center).
		HitWith(ui.ID(c), path, gfx.HitOptions{Role: gfx.RoleGroup}).Tooltip(path).Children(func() {
		ui.Text(c, path).FontSize(12).Mono().Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
		if note != "" {
			ui.Text(c, note).FontSize(12).Color(w.pal.muted).Shrink(0)
		}
	})
}

// remotePreferencesNotices are the read's and the write's failures, and the write that is out.
func (w *window) remotePreferencesNotices(c ui.C, language i18n.Language, r *remotePreferencesState) {
	if r.readFailed == nil && r.failed == nil && !r.saving {
		return
	}
	ui.Column(c.Part("notices")).FillWidth().Shrink(0).Gap(8).Children(func() {
		if r.readFailed != nil {
			message := remotePreferencesFailureMessage(language, r.readFailed, r.damagedPath)
			w.box(c.Part("load-failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
				if w.button(c.Part("load-retry"), buttonSmall, i18n.Shared(language, "desktop.toolchains.reload"), r.busy()) {
					r.reload()
				}
			})
		}
		if r.failed != nil {
			message := remotePreferencesFailureMessage(language, r.failed, r.source.Saved.Path())
			w.box(c.Part("failed"), boxErr, func(words gfx.Color) {
				boxIcon(c, icons.CircleX, words)
				boxText(c, message, words)
			})
		}
		if r.saving {
			w.box(c.Part("busy"), boxInfo, func(words gfx.Color) {
				boxIcon(c, icons.Clock, words)
				boxText(c, i18n.Shared(language, "desktop.toolchains.saving"), words)
			})
		}
	})
}

var openRemoteProgramFiles = app.OpenFiles

// pickRemoteProgram asks for the SSH program and drafts it; Core checks it when Apply writes it.
func (w *window) pickRemoteProgram(language i18n.Language, r *remotePreferencesState) {
	defer w.inv.Invalidate()
	paths, err := openRemoteProgramFiles(app.OpenFileOptions{Title: i18n.Shared(language, "desktop.remoteSettings.chooseProgramTitle")})
	// log-exempt: 用户取消：关闭文件选择器不修改 SSH 程序草稿。
	if errors.Is(err, app.ErrCanceled) || (err == nil && len(paths) == 0) {
		return
	}
	if err != nil {
		r.failed = err
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	path := paths[0]
	r.setProgram(&path)
}
