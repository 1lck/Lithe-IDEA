package settingswindow

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// The Changelog tab of an installed plugin's detail lists the releases its source repository
// published, newest first, each with its notes in Markdown. The releases are read from the
// repository when the tab is first shown for it and kept until the window closes, so going
// back to the tab, or to another plugin of the same repository, reads nothing again.

// changelogTimeout bounds one read of a repository's releases.
const changelogTimeout = 15 * time.Second

// changelogState is the releases the window has read, by repository. Only the window thread
// uses it; the read itself runs on the effect's worker.
type changelogState struct {
	effect *ui.EffectState[changelogResult, string]
	// want is the repository whose releases are being read, empty while none is.
	want string
	// read are the answers so far, by repository: the releases, or why there are none.
	read map[string]*changelogRead
	// report logs a read that failed.
	report func(error)
}

// changelogResult is one finished read. It names its repository, so an answer is kept for
// the repository it is about whichever plugin is chosen when it arrives.
type changelogResult struct {
	repository string
	releases   []PluginRelease
	supported  bool
	err        error
}

// changelogRead is a repository's answer and the notes made from it, one per release, made
// the first time the release is shown.
type changelogRead struct {
	releases  []PluginRelease
	supported bool
	err       error
	notes     []*releaseNotes
}

// newChangelogState prepares the reads of a window. With no reader the tab is not shown.
func newChangelogState(list func(context.Context, string) ([]PluginRelease, bool, error), report func(error)) changelogState {
	s := changelogState{read: map[string]*changelogRead{}, report: report}
	if list == nil {
		return s
	}
	s.effect = ui.NewEffectKeyed[changelogResult, string](func(parent context.Context, repository string) (changelogResult, error) {
		ctx, cancel := context.WithTimeout(parent, changelogTimeout)
		defer cancel()
		releases, supported, err := list(ctx, repository)
		return changelogResult{repository: repository, releases: releases, supported: supported, err: err}, nil
	})
	return s
}

// available says the window can read releases, so the detail shows the tab.
func (s *changelogState) available() bool { return s.effect != nil }

// ask reads repository's releases unless they were read already or are being read.
func (s *changelogState) ask(repository string) {
	if s.effect == nil || s.read[repository] != nil {
		return
	}
	s.want = repository
}

// retry forgets a failed answer and reads the repository again.
func (s *changelogState) retry(repository string) {
	delete(s.read, repository)
	s.ask(repository)
}

// declare keeps the read out alive. It is declared from every paint, so leaving the tab or
// the page does not cancel a read that is out; choosing another repository replaces it.
func (s *changelogState) declare(c ui.C) {
	if s.effect != nil && s.want != "" {
		ui.Effect(c, s.effect, s.want)
	}
}

// take keeps a finished read on the window thread at the start of a paint and logs a failure.
func (s *changelogState) take() {
	if s.effect == nil {
		return
	}
	result, _, ok := s.effect.Take()
	if !ok {
		return
	}
	if result.repository == s.want {
		s.want = ""
	}
	// log-exempt: 用户取消：关闭设置窗口撤销尚未返回的读取，结果不再显示。
	if errors.Is(result.err, context.Canceled) {
		return
	}
	s.read[result.repository] = &changelogRead{
		releases: result.releases, supported: result.supported, err: result.err,
		notes: make([]*releaseNotes, len(result.releases)),
	}
	if result.err != nil && s.report != nil {
		s.report(result.err)
	}
}

// installedChangelog is the Changelog tab: the releases of the plugin's source repository,
// or why there are none to show.
func (w *window) installedChangelog(c ui.C, language i18n.Language, fact PluginFacts) {
	s := &w.changelog
	entry, listed := w.marketEntry(fact.ID)
	if !listed && (w.market.status == marketIdle || w.market.status == marketLoading) {
		// The repository comes from the marketplace listing, which is still on the way.
		w.changelogWaiting(c, language)
		return
	}
	if !listed && w.market.status == marketFailed {
		w.changelogNote(c, i18n.Shared(language, "desktop.pluginChangelog.marketFailed"))
		return
	}
	if !listed || !webURL(entry.Repository) {
		w.changelogNote(c, i18n.Shared(language, "desktop.pluginChangelog.noRepository"))
		return
	}
	repository := strings.TrimSuffix(entry.Repository, "/")
	read := s.read[repository]
	if read == nil {
		s.ask(repository)
		w.changelogWaiting(c, language)
		return
	}
	switch {
	case read.err != nil:
		w.changelogNote(c, i18n.Shared(language, "desktop.pluginChangelog.failed"))
		ui.Wrap(c, read.err.Error()).FontSize(11).Color(w.pal.muted)
		ui.Row(c).Gap(12).Items(ui.Center).Children(func() {
			if ui.Button(c, i18n.Shared(language, "desktop.pluginChangelog.retry")).Clicked() {
				s.retry(repository)
			}
			w.changelogOpen(c, i18n.Shared(language, "desktop.pluginChangelog.openReleases"), repository+"/releases")
		})
	case !read.supported:
		w.changelogNote(c, i18n.Shared(language, "desktop.pluginChangelog.unsupported"))
		w.changelogOpen(c, repositoryName(repository), repository)
	case len(read.releases) == 0:
		w.changelogNote(c, i18n.Shared(language, "desktop.pluginChangelog.empty"))
		w.changelogOpen(c, i18n.Shared(language, "desktop.pluginChangelog.openReleases"), repository+"/releases")
	default:
		ui.Column(c).FillWidth().Gap(14).Children(func() {
			for i := range read.releases {
				w.changelogRelease(c.KeyInt(i), language, fact, read, i)
			}
		})
		w.changelogOpen(c, i18n.Shared(language, "desktop.pluginChangelog.openReleases"), repository+"/releases")
	}
}

// changelogWaiting is the tab while what it shows is on the way.
func (w *window) changelogWaiting(c ui.C, language i18n.Language) {
	ui.Row(c).Gap(8).Items(ui.Center).Children(func() {
		ui.Spinner(c)
		ui.Text(c, i18n.Shared(language, "desktop.pluginChangelog.loading")).FontSize(12).Color(w.pal.muted)
	})
}

// changelogNote is a line that says why the tab lists no releases.
func (w *window) changelogNote(c ui.C, text string) {
	ui.Wrap(c, text).FontSize(12).Color(w.pal.muted)
}

// changelogOpen is a link to a page of the repository on the web; with no browser to open it
// in, the address is shown instead.
func (w *window) changelogOpen(c ui.C, label, address string) {
	if w.ctrl.opts.OpenURL == nil {
		ui.Wrap(c, address).FontSize(12).Color(w.pal.muted)
		return
	}
	if w.installedLink(c, label).Tooltip(address).Clicked() {
		w.ctrl.opts.OpenURL(address)
	}
}

// changelogRelease is one release: its title, whether it is a pre-release or the installed
// version, when it was published, and its notes.
func (w *window) changelogRelease(c ui.C, language i18n.Language, fact PluginFacts, read *changelogRead, i int) {
	release := read.releases[i]
	title := release.Name
	if title == "" {
		title = release.Tag
	}
	ui.Column(c).FillWidth().Pad(14).Gap(10).Radius(8).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, title).FontSize(14).Weight(gfx.WeightSemibold).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
			if release.Name != "" && release.Name != release.Tag {
				ui.Text(c, release.Tag).Mono().FontSize(11).Color(w.pal.muted).Shrink(0)
			}
			if release.Prerelease {
				w.changelogBadge(c, i18n.Shared(language, "desktop.pluginChangelog.prerelease"), w.pal.warning)
			}
			if releaseIsVersion(release.Tag, fact.Version) {
				w.changelogBadge(c, i18n.Shared(language, "native.installed"), w.pal.success)
			}
			ui.Row(c).Grow(1)
			if !release.Published.IsZero() {
				ui.Text(c, release.Published.Local().Format(time.DateOnly)).FontSize(12).Color(w.pal.muted).Shrink(0)
			}
			if webURL(release.URL) && w.ctrl.opts.OpenURL != nil {
				if ui.Button(c, i18n.Shared(language, "desktop.pluginChangelog.openRelease")).Link().Height(installedFieldLine).Clicked() {
					w.ctrl.opts.OpenURL(release.URL)
				}
			}
		})
		if strings.TrimSpace(release.Notes) == "" {
			ui.Text(c, i18n.Shared(language, "desktop.pluginChangelog.noNotes")).FontSize(12).Color(w.pal.muted)
			return
		}
		notes := read.notes[i]
		if notes == nil {
			notes = newReleaseNotes(release.Notes, w.ctrl.opts.OpenURL)
			read.notes[i] = notes
		}
		notes.declare(c, title)
	})
}

// changelogBadge is a small colored word beside a release's title.
func (w *window) changelogBadge(c ui.C, label string, color gfx.Color) {
	ui.Row(c).Shrink(0).PadX(7).PadY(2).Radius(100).Background(color.WithAlpha(0.12)).Children(func() {
		ui.Text(c, label).FontSize(11).Weight(gfx.WeightMedium).Color(color)
	})
}

// releaseIsVersion says a release's tag names version, with or without the "v" a tag
// usually starts with.
func releaseIsVersion(tag, version string) bool {
	return version != "" && strings.TrimPrefix(tag, "v") == strings.TrimPrefix(version, "v")
}

// releaseNotes is one release's notes as the tab shows them: the Markdown laid out for the
// width the detail gives it. It is the Layout of the container it is declared in, so the
// notes are measured while the page is laid out and take their own height on the same paint;
// a control inside it paints them and takes the presses on their links.
type releaseNotes struct {
	doc   markdown.Document
	view  components.MarkdownView
	style components.MarkdownStyle
	// canvas is the canvas of the paint being declared, which measures the text; laid is the
	// width the view was laid out for.
	canvas *gfx.Canvas
	laid   float32
	input  ui.Handlers
	draw   func(*ui.DrawContext)
}

// newReleaseNotes parses source into notes whose web links open through open.
func newReleaseNotes(source string, open func(string)) *releaseNotes {
	n := &releaseNotes{style: components.MarkdownStyle{Size: 12, LineHeight: 19}}
	n.doc.Parse(source)
	n.input.Pointer = func(event gfx.PointerEvent) gfx.EventResult {
		if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary || open == nil {
			return gfx.EventResult{}
		}
		index, ok := event.Target.In(n.input.Parts())
		if !ok {
			return gfx.EventResult{}
		}
		// The notes are whatever the repository published: only web links are followed.
		parsed, err := url.Parse(n.view.Link(index))
		if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
			return gfx.EventResult{}
		}
		open(parsed.String())
		return gfx.EventResult{Handled: true}
	}
	n.draw = n.paint
	return n
}

// declare declares the notes: the container that measures them and the control that paints
// them, named label for assistive technology.
func (n *releaseNotes) declare(c ui.C, label string) {
	n.canvas = c.Canvas()
	ui.CustomLayout(c, n).FillWidth().Children(func() {
		k := c.Part("notes")
		ui.Control(k, label, &n.input).Draw(n.draw).
			HitWith(ui.ID(k), label, gfx.HitOptions{Role: gfx.RoleGroup})
	})
}

// MeasureWidth leaves the notes' width to the detail: they fill it.
func (n *releaseNotes) MeasureWidth(*ui.LayoutContext) float32 { return 0 }

// PlaceWidth gives the painting control the whole width.
func (n *releaseNotes) PlaceWidth(ctx *ui.LayoutContext, bounds ui.Rect) {
	for i := range ctx.Count() {
		ctx.SetWidth(i, bounds.Width)
	}
}

// MeasureHeight lays the notes out for the width they were given and is their height there.
func (n *releaseNotes) MeasureHeight(ctx *ui.LayoutContext) float32 {
	width := ctx.ContentWidth()
	if width > 0 && width != n.laid && n.canvas != nil {
		n.view.Layout(n.canvas, n.style, &n.doc, width)
		n.laid = width
	}
	return n.view.Height()
}

// PlaceHeight gives the painting control the notes' height.
func (n *releaseNotes) PlaceHeight(ctx *ui.LayoutContext, bounds ui.Rect) {
	for i := range ctx.Count() {
		ctx.SetHeight(i, bounds.Height)
	}
}

// paint draws the notes where the layout put the control.
func (n *releaseNotes) paint(dc *ui.DrawContext) {
	if n.laid <= 0 {
		return
	}
	n.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: components.MarkdownLookFor(*dc.Theme),
		X:    dc.Rect.X, Y: dc.Rect.Y,
		Clip:  dc.Rect,
		Links: n.input.Parts(),
	})
}
