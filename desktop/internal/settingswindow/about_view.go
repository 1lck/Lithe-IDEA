package settingswindow

import (
	"fmt"
	"runtime"
	"runtime/debug"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/appicon"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sysinfo"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The About page's links. They are the ones the project's README gives, so the page and the
// README send people to the same groups and the same repository.
const (
	aboutQQGroup   = "163027877"
	aboutQQURL     = "https://qm.qq.com/cgi-bin/qm/qr?k=&group_code=" + aboutQQGroup
	aboutWeChatURL = "https://gcnctzuuwe9u.feishu.cn/wiki/HJFbwZ0hZirAPnkWF3xcPWkCnid?from=from_copylink"
	aboutRepoURL   = "https://github.com/1lck/Lithe-IDEA"
	aboutIssuesURL = aboutRepoURL + "/issues"
)

// aboutIconSize is the logo at the head of the page; aboutChip the coloured square of a
// link and aboutGlyph the glyph in it.
const (
	aboutIconSize = 56
	aboutChip     = 26
	aboutGlyph    = 14
)

// The colours of the link chips: each service's own, so the mark is recognised before
// its name is read. The glyph on them is white in both looks.
var (
	aboutQQColor     = gfx.RGB24(0x12b7f5)
	aboutWeChatColor = gfx.RGB24(0x07c160)
	aboutIssuesColor = gfx.RGB24(0xc0554e)
	aboutRepoColor   = gfx.RGB24(0x24292f)
)

// copyText puts text on the clipboard; a test replaces it.
var copyText = app.SetClipboardText

// aboutState is what the About page remembers while it is open: that its facts were just
// copied, or why copying them failed. Leaving the page forgets both.
type aboutState struct {
	copied  bool
	failure string
}

// aboutFacts are what the About page says about the running client. None of them changes
// while it runs, so a window reads them once, not on every paint.
type aboutFacts struct {
	// platform is the operating system and processor, as "macOS · arm64".
	platform string
	// build is the commit the client was built from and its date, empty when the build did
	// not record them.
	build string
	// runtime is the Go runtime the client was built with.
	runtime string
	// copy is all of it as one block for an issue, with the full system version.
	copy string
}

// aboutInputs are what aboutFacts are made from, read from the process by
// currentAboutInputs and given by hand in tests.
type aboutInputs struct {
	version           string
	stable            bool
	osName, osVersion string
	arch, goVersion   string
	settings          []debug.BuildSetting
}

// currentAboutInputs reads aboutInputs from this process.
func currentAboutInputs(version string, stable bool) aboutInputs {
	in := aboutInputs{
		version: version, stable: stable,
		osName: sysinfo.Name(), osVersion: sysinfo.Version(),
		arch: runtime.GOARCH, goVersion: runtime.Version(),
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		in.settings = info.Settings
	}
	return in
}

// readAboutFacts makes the page's facts. The block it copies is for an issue, which the
// maintainers read whatever the language of the person who files it, so its labels are
// the fixed English ones the bug template asks for rather than interface text.
func readAboutFacts(in aboutInputs) aboutFacts {
	facts := aboutFacts{platform: aboutPlatform(in.osName, in.arch), runtime: in.goVersion}
	var revision, when string
	for _, setting := range in.settings {
		switch setting.Key {
		case "vcs.revision":
			revision = setting.Value
		case "vcs.time":
			when = setting.Value
		}
	}
	if len(revision) > 7 {
		revision = revision[:7]
	}
	if revision != "" {
		facts.build = revision
		if stamp, err := time.Parse(time.RFC3339, when); err == nil {
			facts.build += " · " + stamp.UTC().Format("2006-01-02")
		}
	}
	var copy strings.Builder
	if in.stable {
		fmt.Fprintf(&copy, "Lithe %s\n", in.version)
	} else {
		fmt.Fprintf(&copy, "Lithe %s (preview)\n", in.version)
	}
	fmt.Fprintf(&copy, "platform: %s\n", aboutPlatform(strings.TrimSpace(in.osName+" "+in.osVersion), in.arch))
	if facts.build != "" {
		fmt.Fprintf(&copy, "build: %s\n", facts.build)
	}
	fmt.Fprintf(&copy, "runtime: %s\n", in.goVersion)
	facts.copy = copy.String()
	return facts
}

// aboutPlatform names the system and processor as a person reads them.
func aboutPlatform(system, arch string) string {
	if system == "" {
		return aboutArch(arch)
	}
	return system + " · " + aboutArch(arch)
}

// aboutArch is the processor's usual name, keeping Go's own for anything else.
func aboutArch(arch string) string {
	switch arch {
	case "amd64":
		return "x86-64"
	case "386":
		return "x86"
	}
	return arch
}

// facts are the About page's facts, read on its first paint in this window.
func (w *window) facts() *aboutFacts {
	if w.aboutFacts == nil {
		facts := readAboutFacts(currentAboutInputs(w.ctrl.opts.Version, w.ctrl.opts.Stable))
		w.aboutFacts = &facts
	}
	return w.aboutFacts
}

// aboutPage is the About page, the last of the sidebar: what this copy of Lithe is, its
// updates, and where its community and code are.
func (w *window) aboutPage(c ui.C) {
	language := w.marketLanguage()
	facts := w.facts()
	w.pageScroll(c, pageAbout, func() {
		w.aboutHeader(c, language, facts)
		w.card(c, i18n.Shared(language, "desktop.settings.about.info"), "", func() {
			build := facts.build
			if build == "" {
				build = i18n.Shared(language, "desktop.settings.about.buildUnknown")
			}
			ui.Column(c).FillWidth().Gap(4).PadY(3).Children(func() {
				w.aboutPair(c,
					func(c ui.C) {
						w.aboutFact(c, icons.Info, i18n.Shared(language, "desktop.settings.about.version"),
							w.text.App.Version(w.ctrl.opts.Version, w.ctrl.opts.Stable))
					},
					func(c ui.C) {
						w.aboutFact(c, icons.Monitor, i18n.Shared(language, "desktop.settings.about.platform"), facts.platform)
					})
				w.aboutPair(c,
					func(c ui.C) {
						w.aboutFact(c, icons.Wrench, i18n.Shared(language, "desktop.settings.about.build"), build)
					},
					func(c ui.C) {
						w.aboutFact(c, icons.SquareTerminal, i18n.Shared(language, "desktop.settings.about.runtime"), facts.runtime)
					})
			})
		})
		if w.ctrl.opts.UpdateStatus != nil {
			w.updateCard(c)
		}
		w.card(c, i18n.Shared(language, "desktop.settings.about.community"), "", func() {
			ui.Column(c).FillWidth().PadY(3).Children(func() {
				w.aboutPair(c,
					func(c ui.C) {
						w.aboutLink(c, icons.MessageCircle, aboutQQColor, i18n.Shared(language, "desktop.settings.about.qq"),
							i18n.SharedFormat(language, "desktop.settings.about.qqHelp", map[string]string{"number": aboutQQGroup}), aboutQQURL)
					},
					func(c ui.C) {
						w.aboutLink(c, icons.MessagesSquare, aboutWeChatColor, i18n.Shared(language, "desktop.settings.about.wechat"),
							i18n.Shared(language, "desktop.settings.about.wechatHelp"), aboutWeChatURL)
					})
			})
		})
		w.card(c, i18n.Shared(language, "desktop.settings.about.project"), "", func() {
			ui.Column(c).FillWidth().PadY(3).Children(func() {
				w.aboutPair(c,
					func(c ui.C) {
						w.aboutLink(c, icons.Github, aboutRepoColor, i18n.Shared(language, "desktop.settings.about.repo"),
							i18n.Shared(language, "desktop.settings.about.repoHelp"), aboutRepoURL)
					},
					func(c ui.C) {
						w.aboutLink(c, icons.Bug, aboutIssuesColor, i18n.Shared(language, "desktop.settings.about.issues"),
							i18n.Shared(language, "desktop.settings.about.issuesHelp"), aboutIssuesURL)
					})
			})
		})
	})
}

// aboutHeader is the head of the page: the logo, the name and what Lithe is for, with the
// button that copies the facts for an issue.
func (w *window) aboutHeader(c ui.C, language i18n.Language, facts *aboutFacts) {
	p := &w.pal
	ui.Column(c).FillWidth().Shrink(0).MinWidth(0).Pad(16).Gap(8).Radius(cardRadius).Background(p.card).Stroke(0.5, p.line).Children(func() {
		ui.Row(c).FillWidth().Gap(14).Items(ui.Center).Children(func() {
			ui.Image(c, appicon.Welcome()).Size(aboutIconSize, aboutIconSize).Shrink(0)
			ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(3).Children(func() {
				ui.Text(c, w.text.App.Name).FontSize(18).Weight(gfx.WeightSemibold).Color(p.text).Ellipsis()
				ui.Wrap(c, i18n.Shared(language, "desktop.settings.about.tagline")).FontSize(12).Color(p.muted)
			})
			label, glyph := i18n.Shared(language, "desktop.settings.about.copy"), icons.Copy
			if w.about.copied {
				label, glyph = i18n.Shared(language, "desktop.settings.about.copied"), icons.Check
			}
			if ui.Button(c.Part("copy"), label).Icon(glyph).Outline().Shrink(0).
				Tooltip(i18n.Shared(language, "desktop.settings.about.copyHelp")).Clicked() {
				w.copyAbout(facts)
			}
		})
		if w.about.failure != "" {
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.settings.about.copyFailed", map[string]string{"reason": w.about.failure})).
				FontSize(11).Color(p.danger)
		}
	})
}

// copyAbout puts the facts on the clipboard. A failure is logged as settings_about_copy and
// said under the button until the next try.
func (w *window) copyAbout(facts *aboutFacts) {
	if err := copyText(facts.copy); err != nil {
		w.about = aboutState{failure: err.Error()}
		reportSettingsError(w.ctrl.opts, "settings_about_copy", err)
		return
	}
	w.about = aboutState{copied: true}
}

// aboutPair lays two tiles side by side, or one under the other when the card is too
// narrow for two.
func (w *window) aboutPair(c ui.C, first, second func(ui.C)) {
	if w.extent-2*contentPad-2*cardPad < 460 {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			for _, tile := range [2]func(ui.C){first, second} {
				ui.Column(c).FillWidth().MinWidth(0).Children(func() { tile(c) })
			}
		})
		return
	}
	// Each tile starts from no width and grows, so the two halves are equal whatever
	// their words are.
	ui.Row(c).FillWidth().Gap(10).Children(func() {
		for _, tile := range [2]func(ui.C){first, second} {
			ui.Column(c).Grow(1).Basis(0).Shrink(1).MinWidth(0).Children(func() { tile(c) })
		}
	})
}

// aboutFact is one fact of the build: an icon and its label over the value. The values are
// short; one cut off in a narrow window is whole in the block Copy makes.
func (w *window) aboutFact(c ui.C, icon gfx.Icon, label, value string) {
	p := &w.pal
	ui.Row(c).FillWidth().MinHeight(44).PadX(4).Gap(10).Items(ui.Center).Children(func() {
		ui.Row(c).Size(aboutChip, aboutChip).Shrink(0).Radius(6).Background(p.hover).Center().Children(func() {
			ui.Icon(c, icon).Size(aboutGlyph, aboutGlyph).Color(p.muted)
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(1).Children(func() {
			ui.Text(c, label).FontSize(11).Color(p.muted).Ellipsis()
			ui.Text(c, value).FontSize(13).Weight(gfx.WeightMedium).Color(p.text).Ellipsis()
		})
	})
}

// aboutLink is one link of the page: the service's mark, its name over what it is for, and
// the glyph of a page that opens in the browser. The whole tile is the link.
func (w *window) aboutLink(c ui.C, icon gfx.Icon, chip gfx.Color, label, help, url string) {
	p := &w.pal
	link := ui.Row(c).FillWidth().MinHeight(52).PadX(8).PadY(8).Gap(10).Items(ui.Center).Radius(8).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleLink, Cursor: gfx.PointerCursorHand, Description: help}).
		Hover(ui.Look{}.Background(p.hover)).Focus(ui.Look{}.Ring(2, p.accent))
	link.Children(func() {
		ui.Row(c).Size(aboutChip, aboutChip).Shrink(0).Radius(6).Background(chip).Center().Children(func() {
			ui.Icon(c, icon).Size(aboutGlyph, aboutGlyph).Color(p.white)
		})
		ui.Column(c).Grow(1).Shrink(1).MinWidth(0).Gap(2).Children(func() {
			ui.Text(c, label).FontSize(13).Weight(gfx.WeightMedium).Color(p.text).Ellipsis()
			ui.Paragraph(c, help, 2).FontSize(11).Color(p.muted)
		})
		ui.Icon(c, icons.ExternalLink).Size(12, 12).Color(p.subtle).Shrink(0)
	})
	if link.Clicked() && w.ctrl.opts.OpenURL != nil {
		w.ctrl.opts.OpenURL(url)
	}
}
