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
	// overview row keeps its preview, summary and button on one line.
	fontStackedInner  = 520
	fontOverviewInner = 700
	// fontOverviewLabelWidth, fontSummaryWidth and fontSeparateWidth are the cells of an
	// overview row that is on one line; fixed widths keep the three rows in columns.
	fontOverviewLabelWidth = 88
	fontSummaryWidth       = 220
	fontSeparateWidth      = 112
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

// fontsInner is the width the rows of a card have to share.
func (w *window) fontsInner() float32 {
	return w.extent - 2*contentPad - 2*cardPad
}

// fontsPage is the Fonts page: an overview of the font each place draws with, then a card
// for every font of the list, in which the user chooses its places, family, size, line
// spacing and ligatures. Opening the page writes nothing. A control hands a change to
// setFonts only when the user operates it, as an edit of the snapshot of the list this paint
// was declared from, so the controls of one paint never disagree about the list.
func (w *window) fontsPage(c ui.C) {
	w.fonts.begin()
	words := w.fontWords()
	fonts := fontprefs.Normalize(w.sess.values.Fonts)
	w.pageScroll(c, pageFonts, func() {
		w.fontsOverviewCard(c, words, fonts)
		for i := range fonts {
			w.fontGroupCard(c, words, fonts, i)
		}
	})
}

// fontsOverviewCard shows one row for each place, in the font it is drawn with now, so the
// effect of the cards below is visible at once and in every place. A place that shares its
// font with others offers to be set separately, which is the same as unchecking it in its
// font's card.
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
// card is wide the name, the sample, the summary and the button share one line; when it is
// not, the sample moves under the other three so that it keeps the room to be read. Run
// output does not draw ligatures yet, so its sample does not either, whatever its font sets.
func (w *window) fontsOverviewRow(c ui.C, words fontWords, fonts []fontprefs.Font, scope fontprefs.Scope, oneLine bool) {
	p := &w.pal
	resolved := fontprefs.For(fonts, scope)
	index := groupIndex(fonts, scope)
	name := func() {
		ui.Text(c, words.scope(scope)).FontSize(12).Color(p.text).Ellipsis()
	}
	sample := func() ui.Box {
		return w.fontSampleBox(c, resolved.Family, resolved.Size, resolved.LineSpacing, resolved.Ligatures && scope != fontprefs.Output)
	}
	summary := func() {
		ui.Text(c, words.summary(resolved)).FontSize(12).Color(p.muted).Ellipsis()
	}
	action := func() {
		if len(fonts[index].Scopes) < 2 {
			return
		}
		if ui.Button(c, i18n.Shared(words.language, "desktop.settings.fontsSeparate")).Outline().Small().Clicked() {
			w.setFonts(fontprefs.SetScope(fonts, index, scope, false), false)
		}
	}
	if oneLine {
		ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(12).Items(ui.Center).Children(func() {
			ui.Row(c).Width(fontOverviewLabelWidth).Shrink(0).Items(ui.Center).Children(name)
			sample().Grow(1)
			ui.Row(c).Width(fontSummaryWidth).Shrink(1).MinWidth(0).Items(ui.Center).Children(summary)
			ui.Row(c).Width(fontSeparateWidth).Shrink(0).Justify(ui.End).Items(ui.Center).Children(action)
		})
		return
	}
	ui.Column(c).FillWidth().Gap(4).Children(func() {
		ui.Row(c).FillWidth().MinHeight(fontRowHeight).Gap(8).Items(ui.Center).Children(func() {
			ui.Row(c).Width(fontOverviewLabelWidth).Shrink(0).Items(ui.Center).Children(name)
			ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Items(ui.Center).Children(summary)
			action()
		})
		sample().FillWidth()
	})
}

// fontGroupCard is the card of the font at index i of the list. It is named by its index, so
// the controls of a card keep their identity while the others are added or dropped. Its
// title says which places it is for.
func (w *window) fontGroupCard(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	w.card(c.KeyInt(i), words.scopes(fonts[i].Scopes), "", func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			w.fontScopesRow(c, words, fonts, i)
			w.fontFamilyRow(c, words, fonts, i)
			w.fontPreviewRow(c, words, fonts, i)
			w.fontSizeRow(c, words, fonts, i)
			w.fontSpacingRow(c, words, fonts, i)
			w.fontLigaturesRow(c, words, fonts, i)
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

// fontScopesRow chooses the places a font applies to. Checking a place moves it here from
// the font that had it, and unchecking one gives it a font of its own, which fontprefs does.
// A font keeps at least one place, so its last one is checked and cannot be unchecked.
func (w *window) fontScopesRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	font := fonts[i]
	label := i18n.Shared(words.language, "desktop.settings.fontsScope")
	help := i18n.Shared(words.language, "desktop.settings.fontsScopeHelp")
	w.fontRow(c, label, help, func() {
		for _, scope := range fontprefs.Scopes {
			has := slices.Contains(font.Scopes, scope)
			checked := has
			box := ui.Checkbox(c.Part(string(scope)), &checked, words.scope(scope)).Disabled(has && len(font.Scopes) == 1)
			if box.Changed() {
				w.setFonts(fontprefs.SetScope(fonts, i, scope, checked), false)
			}
		}
	})
}

// fontFamilyRow chooses the family. The field offers the system default and the installed
// families and filters them as the user types. The stored family is always among the choices:
// while the list is being read it is named as it is stored, with a note that the fonts are
// being read, and once the list is here a family it lacks is named as not installed. It stays
// chosen either way, so the stored value changes only when the user chooses another.
func (w *window) fontFamilyRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	state := &w.fonts
	stored := fonts[i].Family
	choice := stored
	choices := state.choices(stored)
	missing := state.missing(stored)
	label := i18n.Shared(words.language, "settings.editor.fontFamily")
	nameOf := func(family string) string {
		if family == stored && missing {
			return words.notInstalled(stored)
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
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.Family = choice }), false)
		}
	})
}

// fontPreviewRow draws the sample in the font as the card sets it, with the line spacing of
// the font's first place, so the card's own choices can be judged before they are used.
func (w *window) fontPreviewRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	font := fonts[i]
	spacing := fontprefs.For(fonts, font.Scopes[0]).LineSpacing
	w.fontRow(c, i18n.Shared(words.language, "desktop.settings.fontsPreview"), "", func() {
		w.fontSampleBox(c, font.Family, font.Size, spacing, font.Ligatures).Grow(1)
	})
}

// fontSizeRow steps the size by one point between the two ends of its range.
func (w *window) fontSizeRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	font := fonts[i]
	w.fontRow(c, i18n.Shared(words.language, "settings.editor.fontSize"), "", func() {
		if fontStep(c, icons.Minus, i18n.Shared(words.language, "desktop.settings.fontsSizeDecrease"), font.Size <= fontprefs.MinSize) {
			size := fontprefs.ClampSize(font.Size - 1)
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.Size = size }), false)
		}
		w.fontStepValue(c, words.sizeValue(font.Size))
		if fontStep(c, icons.Plus, i18n.Shared(words.language, "desktop.settings.fontsSizeIncrease"), font.Size >= fontprefs.MaxSize) {
			size := fontprefs.ClampSize(font.Size + 1)
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.Size = size }), false)
		}
	})
}

// fontSpacingRow chooses between the automatic line spacing of each place and one the user
// sets. Unchecking automatic starts the manual spacing at what automatic gave the font's first
// place, so the lines do not jump; checking it again clears the manual spacing. The buttons
// that step the manual spacing are shown only while it is manual.
func (w *window) fontSpacingRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	font := fonts[i]
	auto := font.LineSpacing == 0
	w.fontRow(c, i18n.Shared(words.language, "desktop.settings.fontsLineSpacing"), "", func() {
		checked := auto
		if ui.Checkbox(c.Part("line-spacing-auto"), &checked, words.autoSpacing(font.Scopes)).Changed() {
			spacing := float32(0)
			if !checked {
				spacing = fontprefs.AutoLineSpacing(font.Scopes[0])
			}
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.LineSpacing = spacing }), false)
		}
		if auto {
			return
		}
		if fontStep(c, icons.Minus, i18n.Shared(words.language, "desktop.settings.fontsLineSpacingDecrease"), font.LineSpacing <= fontprefs.MinLineSpacing) {
			spacing := fontprefs.ClampLineSpacing(font.LineSpacing - fontprefs.LineSpacingStep)
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.LineSpacing = spacing }), false)
		}
		w.fontStepValue(c, formatSpacing(font.LineSpacing))
		if fontStep(c, icons.Plus, i18n.Shared(words.language, "desktop.settings.fontsLineSpacingIncrease"), font.LineSpacing >= fontprefs.MaxLineSpacing) {
			spacing := fontprefs.ClampLineSpacing(font.LineSpacing + fontprefs.LineSpacingStep)
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.LineSpacing = spacing }), false)
		}
	})
}

// fontLigaturesRow switches the ligatures of the font. The help says the font itself must
// support them and that run output does not draw them yet.
func (w *window) fontLigaturesRow(c ui.C, words fontWords, fonts []fontprefs.Font, i int) {
	font := fonts[i]
	label := i18n.Shared(words.language, "settings.editor.fontLigatures")
	help := i18n.Shared(words.language, "desktop.settings.fontsLigaturesHelp")
	w.fontRow(c, label, help, func() {
		on := font.Ligatures
		if ui.Switch(c.Part("ligatures"), &on, "").Label(label).Changed() {
			w.setFonts(fontprefs.Update(fonts, i, func(f *fontprefs.Font) { f.Ligatures = on }), false)
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
