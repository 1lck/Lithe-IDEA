package settingswindow

import (
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// NetworkSettings are the stored proxy settings of the application's own HTTP traffic.
// Mode is "" (the system's proxies), "direct" or "custom"; ProxyType "" (HTTP) or
// "socks5". The password is not here: it lives in the platform secret store, with
// PasswordIdentity naming the endpoint and account it was saved for.
type NetworkSettings struct {
	Mode             string                     `json:"mode,omitempty"`
	ProxyType        string                     `json:"proxyType,omitempty"`
	Host             string                     `json:"host,omitempty"`
	Port             int                        `json:"port,omitempty"`
	Username         string                     `json:"username,omitempty"`
	Exclusions       []string                   `json:"exclusions,omitempty"`
	PasswordIdentity *core.NetworkProxyIdentity `json:"passwordIdentity,omitempty"`
	// HasPassword says a password is stored, so the page can say so without reading it.
	HasPassword bool `json:"hasPassword,omitempty"`
}

var (
	networkModes = []string{"", "direct", "custom"}
	proxyTypes   = []string{"", "socks5"}
)

// networkDraft is the Network page's unsaved edit. The page fills it from the stored
// settings when it is first shown and after each apply; Apply hands it to the owner.
type networkDraft struct {
	loaded               bool
	mode, proxyType      string
	host, port, username ui.Field
	password, exclusions ui.Field
	clearPassword        bool
	failure              string
}

// load puts the stored settings in the draft. The password field starts empty: a stored
// password is never shown, and an empty field keeps it.
func (d *networkDraft) load(stored NetworkSettings) {
	d.loaded = true
	d.mode, d.proxyType = stored.Mode, stored.ProxyType
	d.host.SetText(stored.Host)
	port := ""
	if stored.Port > 0 {
		port = strconv.Itoa(stored.Port)
	}
	d.port.SetText(port)
	d.username.SetText(stored.Username)
	d.password.SetText("")
	d.exclusions.SetText(strings.Join(stored.Exclusions, ", "))
	d.clearPassword, d.failure = false, ""
}

// settings is what the draft would store, and the password to save: nil keeps the
// stored one, an empty string removes it.
func (d *networkDraft) settings(stored NetworkSettings) (NetworkSettings, *string, bool) {
	out := NetworkSettings{Mode: d.mode, ProxyType: d.proxyType, PasswordIdentity: stored.PasswordIdentity, HasPassword: stored.HasPassword}
	out.Host = strings.TrimSpace(d.host.Text())
	if text := strings.TrimSpace(d.port.Text()); text != "" {
		port, err := strconv.Atoi(text)
		if err != nil || port < 1 || port > 65535 {
			return out, nil, false
		}
		out.Port = port
	}
	out.Username = strings.TrimSpace(d.username.Text())
	for _, entry := range strings.FieldsFunc(d.exclusions.Text(), func(r rune) bool { return r == ',' || r == ';' || r == '\n' }) {
		if entry = strings.TrimSpace(entry); entry != "" && !slices.Contains(out.Exclusions, entry) {
			out.Exclusions = append(out.Exclusions, entry)
		}
	}
	var password *string
	switch {
	case d.clearPassword:
		empty := ""
		password = &empty
	case d.password.Text() != "":
		text := d.password.Text()
		password = &text
	}
	return out, password, true
}

// networkPage is the Network page: whether the application's own requests use the
// system's proxies, go direct or go through a server the user names, with its account
// and the hosts reached directly. It shows the stored values; nothing is written until
// Apply, and a stored password is never shown.
func (w *window) networkPage(c ui.C) {
	language := w.marketLanguage()
	d := &w.network
	stored := w.sess.values.Network
	if !d.loaded {
		d.load(stored)
	}
	label := func(key string) string { return i18n.Shared(language, key) }
	modeLabel := func(mode string) string {
		switch mode {
		case "direct":
			return label("desktop.settings.network.direct")
		case "custom":
			return label("desktop.settings.network.custom")
		}
		return label("desktop.settings.network.system")
	}
	typeLabel := func(kind string) string {
		if kind == "socks5" {
			return "SOCKS5"
		}
		return "HTTP"
	}
	row := func(name string, body func()) {
		ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
			ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
				ui.Text(c, name).FontSize(12).Color(w.pal.text).Ellipsis()
			})
			body()
		})
	}
	w.pageScroll(c, pageNetwork, func() {
		w.card(c, label("desktop.settings.network.proxy"), label("desktop.settings.network.proxyHelp"), func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				row(label("desktop.settings.network.mode"), func() {
					ui.Select(c.Part("mode"), &d.mode, networkModes, modeLabel).Width(selectWidth).Label(label("desktop.settings.network.mode"))
				})
				if d.mode != "custom" {
					return
				}
				row(label("desktop.settings.network.type"), func() {
					ui.Select(c.Part("type"), &d.proxyType, proxyTypes, typeLabel).Width(selectWidth).Label(label("desktop.settings.network.type"))
				})
				row(label("desktop.settings.network.host"), func() {
					ui.TextField(c.Part("host"), &d.host, label("desktop.settings.network.host"), "proxy.example.com").Grow(1).MinWidth(0)
				})
				row(label("desktop.settings.network.port"), func() {
					ui.TextField(c.Part("port"), &d.port, label("desktop.settings.network.port"), "8080").Width(100)
				})
				row(label("desktop.settings.network.username"), func() {
					ui.TextField(c.Part("username"), &d.username, label("desktop.settings.network.username"), "").Grow(1).MinWidth(0)
				})
				row(label("desktop.settings.network.password"), func() {
					placeholder := ""
					if stored.HasPassword && !d.clearPassword {
						placeholder = label("desktop.settings.network.passwordStored")
					}
					ui.TextField(c.Part("password"), &d.password, label("desktop.settings.network.password"), placeholder).Secure().Grow(1).MinWidth(0)
					if stored.HasPassword && !d.clearPassword {
						if ui.Button(c.Part("clear-password"), label("desktop.settings.network.clearPassword")).Ghost().Small().Clicked() {
							d.clearPassword = true
							d.password.SetText("")
						}
					}
				})
				ui.Column(c).FillWidth().Gap(4).Children(func() {
					ui.Text(c, label("desktop.settings.network.exclusions")).FontSize(12).Color(w.pal.text)
					ui.TextField(c.Part("exclusions"), &d.exclusions, label("desktop.settings.network.exclusions"), "localhost, *.internal, 10.0.0.0/8").FillWidth()
					ui.Wrap(c, label("desktop.settings.network.exclusionsHelp")).FontSize(12).Color(w.pal.muted)
				})
			})
		})
		if d.failure != "" {
			ui.Wrap(c, d.failure).FontSize(12).Color(w.pal.danger)
		}
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Spacer(c)
			if ui.Button(c.Part("revert"), label("desktop.settings.network.revert")).Outline().Clicked() {
				d.load(stored)
			}
			if ui.Button(c.Part("apply"), label("desktop.settings.network.apply")).Clicked() {
				w.applyNetwork(language)
			}
		})
	})
}

// applyNetwork hands the draft to the settings owner, which saves it, stores or removes
// the password and applies the new policy; the draft is then shown as stored.
func (w *window) applyNetwork(language i18n.Language) {
	d := &w.network
	next, password, ok := d.settings(w.sess.values.Network)
	if !ok {
		d.failure = i18n.Shared(language, "desktop.settings.network.invalidPort")
		return
	}
	if password != nil {
		next.HasPassword = *password != ""
	}
	w.sess.values.Network = next
	if w.ctrl.opts.SetNetwork != nil {
		w.ctrl.opts.SetNetwork(next, password)
	}
	d.load(next)
}
