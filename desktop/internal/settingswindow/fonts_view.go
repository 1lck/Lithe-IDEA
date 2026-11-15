package settingswindow

import (
	"context"
	"math"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/fontprefs"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// fontSample is the line the Fonts page draws in each font. It is code, not interface text,
// so it is not translated, and it is ASCII only because a ligature run needs ASCII. It holds
// the pairs a programming font joins (->, !=, =>, //) and the characters such a font must
// tell apart (0 and O, I and l and 1).
const fontSample = `func greet(name: String) -> String { "Hello, \(name)!" } // 0O Il1 != =>`

// The measures of the Fonts page.
const (
	// fontRowHeight is the height of one compact row, as on the Editor and General pages.
	fontRowHeight = 28
	// fontLabelPercent is the share of a row the name of a setting takes, as on the General
	// page.
	fontLabelPercent = 34
	// fontComboWidth is the width of the field that chooses a family.
	fontComboWidth = 280
	// fontStackedInner is the width of a card's rows under which a row puts its control
	// under its name instead of beside it, and fontOverviewInner the width from which an
	// overview row keeps its name, preview and summary on one line.
	fontStackedInner  = 520
	fontOverviewInner = 700
	// fontOverviewLabelWidth and fontSummaryWidth are the cells of an overview row that is on
	// one line, the first holding the place's checkbox and name; fixed widths keep the three
	// rows in columns.
	fontOverviewLabelWidth = 120
	fontSummaryWidth       = 220
	// fontValueWidth is the width of the number between the two buttons that step it, and
	// fontStepSize the side of those buttons.
	fontValueWidth = 56
	fontStepSize   = 24
	// fontPreviewPadX and fontPreviewPadY keep the sample off the edge of its frame.
	fontPreviewPadX = 8
	fontPreviewPadY = 4
)

// fontListState is the Fonts page's list of installed fixed-pitch families. Only the window
// thread reads or writes the fields. The load is a page Effect, as the Terminal page's list
// of shells is: it starts the first time the page is drawn, the window takes its result with
// take at the start of a paint, and closing the window cancels it. Reading the installed
// fonts can take a moment, so it must not run on the window thread.
type fontListState struct {
	load   func() []string
	effect *ui.EffectState[[]string, int]
	// key is zero until the Fonts page asks for the load.
	key int

	loaded bool
	// families are the loaded names without empty ones and repeats, in the order the loader
	// gave them.
	families []string
}

// newFontListState prepares the one load a window makes. With no loader there is nothing to
// load: the page offers only the system default and the stored families.
func newFontListState(load func() []string) fontListState {
	s := fontListState{load: load}
	if load != nil {
		s.effect = ui.NewEffect[[]string, int](func(context.Context) ([]string, error) {
			return load(), nil
		})
	}
	return s
}

// begin asks for the one load a window makes the first time the page is drawn. It does
// nothing again afterwards or with no loader. The load reads the machine and writes nothing.
func (s *fontListState) begin() {
	if s.load == nil || s.key != 0 {
		return
	}
	s.key = 1
}

// take applies the finished load on the window thread at the start of a paint.
func (s *fontListState) take() {
	if s.effect == nil {
		return
	}
	if names, _, ok := s.effect.Take(); ok {
		s.families, s.loaded = cleanFamilies(names), true
	}
}

// declare keeps the load alive until the window ends. It is declared from every paint, so
// leaving the page does not cancel a load that is out.
func (s *fontListState) declare(c ui.C) {
	if s.effect != nil && s.key != 0 {
		ui.Effect(c, s.effect, s.key)
	}
}

// pending says the list is being read: there is a loader and its result is not here yet.
func (s *fontListState) pending() bool {
	return s.load != nil && !s.loaded
}

// missing says family is stored but is not among the installed ones. It cannot be known
// before the list is here, and with no loader it is never known, so both say no.
func (s *fontListState) missing(family string) bool {
	return family != "" && s.loaded && !slices.Contains(s.families, family)
}

// choices are what the family field offers for a font whose stored family is stored: the
// system default, which is the empty family, then the installed families. A stored family
// that is not among them is offered as well, right after the default, so what the user
// chose is never swapped for another font because the list is still being read or lacks it.
func (s *fontListState) choices(stored string) []string {
	out := make([]string, 0, len(s.families)+2)
	out = append(out, "")
	if stored != "" && !slices.Contains(s.families, stored) {
		out = append(out, stored)
	}
	return append(out, s.families...)
}

// cleanFamilies drops the names a combobox cannot offer: an empty name, which is the system
// default's, and a name it already has, because the choices of a combobox must be distinct.
func cleanFamilies(names []string) []string {
	out := make([]string, 0, len(names))
	for _, name := range names {
		if strings.TrimSpace(name) == "" || slices.Contains(out, name) {
			continue
		}
		out = append(out, name)
	}
	return out
}

// fontWords are the formatted words of the Fonts page in the language of the window. Each
// lookup names its key as a literal, which is how the localization check finds them, so the
// words that several rows share are built here and the others where they are drawn.
type fontWords struct {
	language i18n.Language
	// separator joins the names of several places into one line.
	separator string
}

// fontWords reads the language of the window once for the whole paint of the page.
func (w *window) fontWords() fontWords {
	language := w.marketLanguage()
	return fontWords{language: language, separator: i18n.Shared(language, "desktop.settings.fontsScopeSeparator")}
}

// scope is the name of a place that draws fixed-pitch text. A scope the list does not know
// cannot be in a normalized list; its identifier stands in so that nothing is left blank.
func (t fontWords) scope(scope fontprefs.Scope) string {
	switch scope {
	case fontprefs.Editor:
		return i18n.Shared(t.language, "desktop.settings.fontsScopeEditor")
	case fontprefs.Terminal:
		return i18n.Shared(t.language, "desktop.settings.fontsScopeTerminal")
	case fontprefs.Output:
		return i18n.Shared(t.language, "desktop.settings.fontsScopeOutput")
	}
	return string(scope)
}

// scopes are the names of several places on one line.
func (t fontWords) scopes(list []fontprefs.Scope) string {
	names := make([]string, len(list))
	for i, scope := range list {
		names[i] = t.scope(scope)
	}
	return strings.Join(names, t.separator)
}

// family is the name of a family as the page shows it: the system default for the empty one.
func (t fontWords) family(name string) string {
	if name == "" {
		return i18n.Shared(t.language, "desktop.settings.fontsSystemDefault")
	}
	return name
}

// notInstalled names a stored family the machine does not have.
func (t fontWords) notInstalled(family string) string {
	return i18n.SharedFormat(t.language, "desktop.settings.fontsNotInstalled", map[string]string{"family": family})
}

// summary says in words what a place is drawn with now.
func (t fontWords) summary(resolved fontprefs.Resolved) string {
	return i18n.SharedFormat(t.language, "desktop.settings.fontsSummary", map[string]string{
		"family":  t.family(resolved.Family),
		"size":    formatSize(resolved.Size),
		"spacing": formatSpacing(resolved.LineSpacing),
	})
}

// sizeValue is a font size with its unit.
func (t fontWords) sizeValue(size float32) string {
	return i18n.SharedFormat(t.language, "desktop.settings.fontsSizeValue", map[string]string{"size": formatSize(size)})
}

// autoSpacing is the words of the option that leaves the line spacing to each place, with
// the spacing it gives. A font of one place says the one number; a font shared by several
// says each place's number, because the places' automatic spacings differ.
func (t fontWords) autoSpacing(scopes []fontprefs.Scope) string {
	value := formatSpacing(fontprefs.AutoLineSpacing(scopes[0]))
	if len(scopes) > 1 {
		parts := make([]string, len(scopes))
		for i, scope := range scopes {
			parts[i] = i18n.SharedFormat(t.language, "desktop.settings.fontsLineSpacingScope", map[string]string{"scope": t.scope(scope), "value": formatSpacing(fontprefs.AutoLineSpacing(scope))})
		}
		value = strings.Join(parts, t.separator)
	}
	return i18n.SharedFormat(t.language, "desktop.settings.fontsLineSpacingAuto", map[string]string{"value": value})
}

// formatSize writes a size as a whole number of points, which is what ClampSize keeps.
func formatSize(size float32) string {
	return strconv.FormatFloat(float64(size), 'f', 0, 32)
}

// formatSpacing writes a line spacing with one decimal, which is what ClampLineSpacing keeps.
func formatSpacing(spacing float32) string {
	return strconv.FormatFloat(float64(spacing), 'f', 1, 32)
}

// faceOf is the face that draws family; the empty family is the system's fixed-pitch font.
func faceOf(family string) gfx.MonoFace {
	if family == "" {
		return gfx.MonoSystem
	}
	return gfx.MonoFamily(family)
}

// groupIndex is the index, in the normalized list fonts, of the font scope belongs to. A
// normalized list gives every scope a font, so the fallback is never taken.
func groupIndex(fonts []fontprefs.Font, scope fontprefs.Scope) int {
	for i, font := range fonts {
		if slices.Contains(font.Scopes, scope) {
			return i
		}
	}
	return 0
}

// fontEditState is the places checked on the Fonts page and the look the user sets up for
// them, which reaches the stored list only when Save is pressed. Only the window thread reads
// or writes it, and it lasts while the window is open.
type fontEditState struct {
	// chosen is the places checked in the overview, in the order of fontprefs.Scopes. ready
	// says it has been set: the first time the page is drawn it checks the places that share
	// the editor's font, so that saving at once keeps them together.
	chosen []fontprefs.Scope
	ready  bool
	// draft is the look being set up; its scopes are not used. While edited is false the page
	// loads it on every paint from the stored font of the first checked place, so it shows
	// what is in force. Once the user changes it, it stays as they left it while places are
	// checked or unchecked, until Save or Revert.
	draft  fontprefs.Font
	edited bool
}

// prepare brings the state up to date with fonts, the normalized stored list, for a paint.
func (e *fontEditState) prepare(fonts []fontprefs.Font) {
	if !e.ready {
		e.chosen, e.ready = slices.Clone(fonts[0].Scopes), true
	}
	if !e.edited {
		e.draft = fonts[groupIndex(fonts, e.first())]
		e.draft.Scopes = nil
	}
}

// first is the first checked place, or the editor when none is checked. The card loads its
// look from that place's font and shows the automatic line spacing of that place.
func (e *fontEditState) first() fontprefs.Scope {
	if len(e.chosen) > 0 {
		return e.chosen[0]
	}
	return fontprefs.Editor
}

// choose checks or unchecks scope, keeping the order of fontprefs.Scopes.
func (e *fontEditState) choose(scope fontprefs.Scope, on bool) {
	var next []fontprefs.Scope
	for _, s := range fontprefs.Scopes {
		if (s == scope && on) || (s != scope && slices.Contains(e.chosen, s)) {
			next = append(next, s)
		}
	}
	e.chosen = next
}

// edit applies change to the draft, clamped as the stored list is, and keeps it as the user
// left it.
func (e *fontEditState) edit(change func(*fontprefs.Font)) {
	change(&e.draft)
	e.draft.Size = fontprefs.ClampSize(e.draft.Size)
	e.draft.LineSpacing = fontprefs.ClampLineSpacing(e.draft.LineSpacing)
	e.edited = true
}

// fontsInner is the width the rows of a card have to share.
func (w *window) fontsInner() float32 {
	return w.extent - 2*contentPad - 2*cardPad
}

// fontsPage is the Fonts page: an overview of the font each place draws with now, in which the
// user checks the places to change, one or more, and under it a card that sets up their
// family, size, line spacing and ligatures. Opening the page writes nothing and neither does
// editing the card: only Save hands a list to setFonts, which gives the checked places the
// card's look and leaves the others as they are.
func (w *window) fontsPage(c ui.C) {
	w.fonts.begin()
	words := w.fontWords()
	fonts := fontprefs.Normalize(w.sess.values.Fonts)
	w.fontEdit.prepare(fonts)
	w.pageScroll(c, pageFonts, func() {
		w.fontsOverviewCard(c, words, fonts)
		w.fontEditCard(c, words, fonts)
	})
}

// fontsOverviewCard shows one row for each place, in the font it is drawn with now, so the
// effect of a save is visible at once and in every place. The checkbox of a row chooses the
// places the card below changes.
func (w *window) fontsOverviewCard(c ui.C, words fontWords, fonts []fontprefs.Font) {
	title := i18n.Shared(words.language, "desktop.settings.fontsOverview")
	help := i18n.Shared(words.language, "desktop.settings.fontsOverviewHelp")
	oneLine := w.fontsInner() >= fontOverviewInner
	w.card(c, title, help, func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			for _, scope := range fontprefs.Scopes {
				w.fontsOverviewRow(c.Key(string(scope)), words, fonts, scope, oneLine)
			}
		})
	})
}

// fontsOverviewRow is the row of one place. Its first declaration is the container named by
// the key the caller set, so the row keeps its identity however the others change. When the
// card is wide the checkbox with the place's name, the sample and the summary share one line;
// when it is not, the sample moves under the other two so that it keeps the room to be read.
// Run output does not draw ligatures yet, so its sample does not either, whatever its font
// sets.
func (w *window) fontsOverviewRow(c ui.C, words fontWords, fonts []fontprefs.Font, scope fontprefs.Scope, oneLine bool) {
	p := &w.pal
	e := &w.fontEdit
	resolved := fontprefs.For(fonts, scope)
	name := func() {
		checked := slices.Contains(e.chosen, scope)
		if ui.Checkbox(c.Part("checked"), &checked, words.scope(scope)).Changed() {
			e.choose(scope, checked)
		}
	}
	sample := func() ui.Box {
		return w.fontSampleBox(c, resolved.Family, resolved.Size, resolved.LineSpacing, resolved.Ligatures && scope != fontprefs.Output)
	}
	summary := func() {
		ui.Text(c, words.summary(resolved)).FontSize(12).Color(p.muted).Ellipsis()
	}
	if oneLine {
		ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(12).Items(ui.Center).Children(func() {
			ui.Row(c).Width(fontOverviewLabelWidth).Shrink(0).Items(ui.Center).Children(name)
			sample().Grow(1)
			ui.Row(c).Width(fontSummaryWidth).Shrink(1).MinWidth(0).Items(ui.Center).Children(summary)
		})
		return
	}
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(8).Items(ui.Center).Children(func() {
			ui.Row(c).Width(fontOverviewLabelWidth).Shrink(0).Items(ui.Center).Children(name)
			ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(summary)
		})
		sample().FillWidth()
	})
}

// fontEditCard sets up a look for the places checked in the overview. Its title names them,
// its rows edit the unsaved look, and at the end of its last row Revert drops the changes and
// Save gives the checked places the look, which fontprefs.Assign does. Save is offered only
// when a place is checked and saving would change the stored list.
func (w *window) fontEditCard(c ui.C, words fontWords, fonts []fontprefs.Font) {
	e := &w.fontEdit
	title := i18n.Shared(words.language, "desktop.settings.fontsNoneChecked")
	if len(e.chosen) > 0 {
		title = words.scopes(e.chosen)
	}
	help := i18n.Shared(words.language, "desktop.settings.fontsEditHelp")
	w.card(c.Part("edit"), title, help, func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			w.fontFamilyRow(c, words)
			w.fontPreviewRow(c, words)
			w.fontSizeRow(c, words)
			w.fontSpacingRow(c, words)
			w.fontLigaturesRow(c, words)
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Spacer(c)
				if ui.Button(c.Part("revert"), i18n.Shared(words.language, "desktop.settings.network.revert")).Outline().Disabled(!e.edited).Clicked() {
					e.edited = false
					e.prepare(fonts)
				}
				next := fontprefs.Assign(fonts, e.chosen, e.draft)
				if ui.Button(c.Part("save"), i18n.Shared(words.language, "ui.save")).Disabled(len(e.chosen) == 0 || fontprefs.Equal(fonts, next)).Clicked() {
					w.setFonts(next, false)
					e.edited = false
				}
			})
		})
	})
}

// fontRow is one compact line of a font card: the name of the setting in a column at the
// leading side, with the help glyph when it has help, and its control beside it, as the
// General page lays out its rows. When the card is too narrow for two columns the control
// goes under the name instead, so that neither is cut off. The control is declared into a
// row that takes the rest of the line.
func (w *window) fontRow(c ui.C, label, help string, control func()) {
	p := &w.pal
	name := func() {
		ui.Text(c, label).FontSize(12).Color(p.text).Ellipsis()
		if help != "" {
			w.infoButton(c, help)
		}
	}
	if w.fontsInner() < fontStackedInner {
		ui.Column(c).FillWidth().Gap(4).Children(func() {
			ui.Row(c).FillWidth().Gap(6).Items(ui.Center).Children(name)
			ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(12).Items(ui.Center).Children(control)
		})
		return
	}
	ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(12).Items(ui.Center).Children(func() {
		ui.Row(c).WidthPercent(fontLabelPercent).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(name)
		ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Gap(12).Items(ui.Center).Children(control)
	})
}

// fontFamilyRow chooses the family of the card's look. The field offers the system default and
// the installed families and filters them as the user types. The family the card shows is
// always among the choices: while the list is being read it is named as it is stored, with a
// note that the fonts are being read, and once the list is here a family it lacks is named as
// not installed. It stays chosen either way, so it changes only when the user chooses another.
func (w *window) fontFamilyRow(c ui.C, words fontWords) {
	state := &w.fonts
	e := &w.fontEdit
	current := e.draft.Family
	choice := current
	choices := state.choices(current)
	missing := state.missing(current)
	label := i18n.Shared(words.language, "settings.editor.fontFamily")
	nameOf := func(family string) string {
		if family == current && missing {
			return words.notInstalled(current)
		}
		return words.family(family)
	}
	w.fontRow(c, label, "", func() {
		field := ui.Combobox(c.Part("family"), &choice, choices, nameOf, label).
			Placeholder(i18n.Shared(words.language, "desktop.settings.fontsSearch")).Width(fontComboWidth).Shrink(1).MinWidth(0)
		if state.pending() {
			ui.Row(c).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
				ui.Text(c, i18n.Shared(words.language, "desktop.settings.fontsLoading")).FontSize(12).Color(w.pal.subtle).Ellipsis()
			})
		}
		if field.Changed() {
			e.edit(func(f *fontprefs.Font) { f.Family = choice })
		}
	})
}

// fontPreviewRow draws the sample in the card's look, with the line spacing of the first
// checked place when the spacing is automatic, so the look can be judged before it is saved.
func (w *window) fontPreviewRow(c ui.C, words fontWords) {
	e := &w.fontEdit
	font := e.draft
	spacing := font.LineSpacing
	if spacing == 0 {
		spacing = fontprefs.AutoLineSpacing(e.first())
	}
	w.fontRow(c, i18n.Shared(words.language, "desktop.settings.fontsPreview"), "", func() {
		w.fontSampleBox(c, font.Family, font.Size, spacing, font.Ligatures).Grow(1)
	})
}

// fontSizeRow steps the size by one point between the two ends of its range.
func (w *window) fontSizeRow(c ui.C, words fontWords) {
	e := &w.fontEdit
	size := e.draft.Size
	w.fontRow(c, i18n.Shared(words.language, "settings.editor.fontSize"), "", func() {
		if fontStep(c, icons.Minus, i18n.Shared(words.language, "desktop.settings.fontsSizeDecrease"), size <= fontprefs.MinSize) {
			e.edit(func(f *fontprefs.Font) { f.Size = size - 1 })
		}
		w.fontStepValue(c, words.sizeValue(size))
		if fontStep(c, icons.Plus, i18n.Shared(words.language, "desktop.settings.fontsSizeIncrease"), size >= fontprefs.MaxSize) {
			e.edit(func(f *fontprefs.Font) { f.Size = size + 1 })
		}
	})
}

// fontSpacingRow chooses between the automatic line spacing of each place and one the user
// sets. Unchecking automatic starts the manual spacing at what automatic gives the first
// checked place, so the lines do not jump; checking it again clears the manual spacing. The
// buttons that step the manual spacing are shown only while it is manual.
func (w *window) fontSpacingRow(c ui.C, words fontWords) {
	e := &w.fontEdit
	spacing := e.draft.LineSpacing
	auto := spacing == 0
	places := e.chosen
	if len(places) == 0 {
		places = []fontprefs.Scope{e.first()}
	}
	w.fontRow(c, i18n.Shared(words.language, "desktop.settings.fontsLineSpacing"), "", func() {
		checked := auto
		if ui.Checkbox(c.Part("line-spacing-auto"), &checked, words.autoSpacing(places)).Changed() {
			next := float32(0)
			if !checked {
				next = fontprefs.AutoLineSpacing(e.first())
			}
			e.edit(func(f *fontprefs.Font) { f.LineSpacing = next })
		}
		if auto {
			return
		}
		if fontStep(c, icons.Minus, i18n.Shared(words.language, "desktop.settings.fontsLineSpacingDecrease"), spacing <= fontprefs.MinLineSpacing) {
			e.edit(func(f *fontprefs.Font) { f.LineSpacing = spacing - fontprefs.LineSpacingStep })
		}
		w.fontStepValue(c, formatSpacing(spacing))
		if fontStep(c, icons.Plus, i18n.Shared(words.language, "desktop.settings.fontsLineSpacingIncrease"), spacing >= fontprefs.MaxLineSpacing) {
			e.edit(func(f *fontprefs.Font) { f.LineSpacing = spacing + fontprefs.LineSpacingStep })
		}
	})
}

// fontLigaturesRow switches the ligatures of the card's look. The help says the font itself
// must support them and that run output does not draw them yet.
func (w *window) fontLigaturesRow(c ui.C, words fontWords) {
	e := &w.fontEdit
	label := i18n.Shared(words.language, "settings.editor.fontLigatures")
	help := i18n.Shared(words.language, "desktop.settings.fontsLigaturesHelp")
	w.fontRow(c, label, help, func() {
		on := e.draft.Ligatures
		if ui.Switch(c.Part("ligatures"), &on, "").Label(label).Changed() {
			e.edit(func(f *fontprefs.Font) { f.Ligatures = on })
		}
	})
}

// fontStep is one of the two buttons that move a number by a step, a minus or a plus. It
// reports whether this paint delivers a click on it. At the end of the range it is disabled,
// so it cannot ask for a value the range does not have.
func fontStep(c ui.C, icon gfx.Icon, label string, disabled bool) bool {
	return ui.Button(c, label).Icon(icon).IconOnly().Outline().Size(fontStepSize, fontStepSize).Disabled(disabled).Clicked()
}

// fontStepValue is the number between the two buttons that step it. It has a fixed width, so
// the buttons do not move while the number changes its digits.
func (w *window) fontStepValue(c ui.C, value string) {
	ui.Row(c).Width(fontValueWidth).Shrink(0).Center().Children(func() {
		ui.Text(c, value).FontSize(12).Color(w.pal.text)
	})
}

// fontSampleBox is a frame that draws fontSample in a font. Its height is that of a line of
// the font at the given spacing, so a spacing the user sets is seen as well as the family
// and the size, with room above and below. The text is clipped to the frame, so a long line
// in a narrow card shows its beginning. The caller gives the frame its width.
func (w *window) fontSampleBox(c ui.C, family string, size, spacing float32, ligatures bool) ui.Box {
	p := &w.pal
	face := faceOf(family)
	cellH := float32(0)
	if canvas := c.Canvas(); canvas != nil {
		_, cellH = canvas.MonoCellSize(size, face)
	}
	line := float32(math.Round(float64(cellH * spacing)))
	color := p.text
	return ui.Row(c).Height(max(fontRowHeight, line+2*fontPreviewPadY)).Shrink(1).MinWidth(0).Radius(4).
		Background(p.window).Stroke(1, p.line).Clip().
		Draw(func(d *ui.DrawContext) { paintFontSample(d, color, face, size, ligatures) })
}

// paintFontSample draws fontSample in the middle of the frame being drawn, as the editor
// draws a line: on the grid of the face's cell, as one run so that a ligature can join the
// characters of a pair, and not joined when the font's ligatures are off. A face with no
// measurable cell draws nothing.
func paintFontSample(d *ui.DrawContext, color gfx.Color, face gfx.MonoFace, size float32, ligatures bool) {
	if d.Canvas == nil {
		return
	}
	cellW, cellH := d.Canvas.MonoCellSize(size, face)
	if cellW <= 0 || cellH <= 0 {
		return
	}
	color = d.Fade(color)
	cells := int32(len(fontSample))
	bounds := gfx.Rect{
		X:      d.Rect.X + fontPreviewPadX,
		Y:      d.Rect.Y + (d.Rect.Height-cellH)/2,
		Width:  float32(cells)*cellW + 1,
		Height: cellH,
	}
	style := gfx.TextStyle{Size: size, Color: color, Mono: true, MonoFace: face}
	runs := [1]gfx.TextRun{{Bytes: cells, Cells: cells, Color: color, Ligatures: ligatures}}
	d.Canvas.LabelRuns(fontSample, bounds, style, cellW, runs[:])
}
