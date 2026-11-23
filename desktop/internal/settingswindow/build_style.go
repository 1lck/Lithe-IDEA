package settingswindow

import (
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The Build, Execution, Deployment pages follow the design prototype
// docs/design/build-execution-settings.html value for value: its colors, sizes and
// spacings are the constants and the palette below. The window around them keeps the
// metrics of every other settings page.

// buildPalette is the prototype's colors in one look.
type buildPalette struct {
	// surface is the page, side the sidebar and the group headers of a list, sel a chosen
	// row and hover a row under the pointer.
	surface, side, sel, hover gfx.Color
	// text is ordinary text, sub secondary text and faint hints and counts.
	text, sub, faint gfx.Color
	// line separates regions and outlines cards and controls.
	line gfx.Color
	// accent marks what is on, chosen or changed; ok, warn and err are the three states
	// of a tool.
	accent, ok, warn, err gfx.Color
	// pill is the ground of a chip, a tag and the segmented control, chip the ground of
	// one that is on.
	pill, chip gfx.Color
	// switchOff is the track of a switch that is off.
	switchOff gfx.Color
	// tagGreen, tagWarn and tagErr are the grounds of the colored tags.
	tagGreen, tagWarn, tagErr gfx.Color
	// press is a row of the issue list under the pointer.
	press gfx.Color
	// boxes are the notice boxes, by kind.
	boxes [boxKinds]boxColors
	white gfx.Color
}

// boxColors are a notice box's outline, ground and words.
type boxColors struct {
	border, background, text gfx.Color
}

// The kinds of notice box.
const (
	boxWarn = iota
	boxErr
	boxNext
	boxInfo
	boxKinds
)

// The kinds of tag.
const (
	tagPlain = iota
	tagBlue
	tagGreen
	tagWarn
	tagErr
	tagSource
)

func buildPaletteFor(dark bool) buildPalette {
	if dark {
		b := buildPalette{
			surface: gfx.RGB24(0x2b2d30), side: gfx.RGB24(0x26282b), sel: gfx.RGB24(0x2e436e), hover: gfx.RGB24(0x33363a),
			text: gfx.RGB24(0xdfe1e5), sub: gfx.RGB24(0x9da0a8), faint: gfx.RGB24(0x6f737a), line: gfx.RGB24(0x3a3d41),
			accent: gfx.RGB24(0x548af7), ok: gfx.RGB24(0x5fb865), warn: gfx.RGB24(0xe0a83e), err: gfx.RGB24(0xf0716a),
			pill: gfx.RGB24(0x393b40), chip: gfx.RGB24(0x25324d), switchOff: gfx.RGB24(0x55585e),
			tagGreen: gfx.RGB24(0x22382a), tagWarn: gfx.RGB24(0x3d3220), tagErr: gfx.RGB24(0x45282a),
			press: gfx.RGBA(255, 255, 255, 0.04), white: gfx.RGB24(0xffffff),
		}
		b.boxes = [boxKinds]boxColors{
			boxWarn: {border: gfx.RGB24(0x5c4a24), background: gfx.RGB24(0x3a301d), text: gfx.RGB24(0xe8c47a)},
			boxErr:  {border: gfx.RGB24(0x5f3532), background: gfx.RGB24(0x3d2524), text: gfx.RGB24(0xf2a39c)},
			boxNext: {border: gfx.RGB24(0x36507e), background: gfx.RGB24(0x22314d), text: gfx.RGB24(0xa9c3f5)},
			boxInfo: {border: b.line, background: b.pill, text: b.sub},
		}
		return b
	}
	b := buildPalette{
		surface: gfx.RGB24(0xffffff), side: gfx.RGB24(0xf2f3f5), sel: gfx.RGB24(0xdfe7f8), hover: gfx.RGB24(0xeceef1),
		text: gfx.RGB24(0x1f2329), sub: gfx.RGB24(0x6c707e), faint: gfx.RGB24(0x9aa0ab), line: gfx.RGB24(0xe4e6ea),
		accent: gfx.RGB24(0x3574f0), ok: gfx.RGB24(0x208a3c), warn: gfx.RGB24(0xc27d00), err: gfx.RGB24(0xd1453b),
		pill: gfx.RGB24(0xeef1f6), chip: gfx.RGB24(0xe8f0fe), switchOff: gfx.RGB24(0xc4c7cd),
		tagGreen: gfx.RGB24(0xe6f4ea), tagWarn: gfx.RGB24(0xfff1d6), tagErr: gfx.RGB24(0xfbe5e3),
		press: gfx.RGBA(0, 0, 0, 0.04), white: gfx.RGB24(0xffffff),
	}
	b.boxes = [boxKinds]boxColors{
		boxWarn: {border: gfx.RGB24(0xf1d29a), background: gfx.RGB24(0xfdf6e7), text: gfx.RGB24(0x7a5400)},
		boxErr:  {border: gfx.RGB24(0xf0c4c0), background: gfx.RGB24(0xfdf0ef), text: gfx.RGB24(0x8a2a22)},
		boxNext: {border: gfx.RGB24(0xbcd0f7), background: gfx.RGB24(0xeef4ff), text: gfx.RGB24(0x23468f)},
		boxInfo: {border: b.line, background: b.pill, text: b.sub},
	}
	return b
}

// The prototype's sizes.
const (
	// buildFont is the page's text, buildSmall the secondary lines and buildTiny tags and
	// counts.
	buildFont  = 13
	buildSmall = 12
	buildTiny  = 10.5
	buildMono  = 11.5
	// buildHeading is a page's title.
	buildHeading = 17
	// buildPagePadX and buildPagePadY are the margins of a page and of a detail pane.
	buildPagePadX   = 20
	buildPagePadTop = 16
	buildPagePadEnd = 30
)

// statusColor is the color of a tool's or a dot's state: error, warning, ok or idle.
func (b *buildPalette) statusColor(status string) gfx.Color {
	switch status {
	case "error":
		return b.err
	case "warning":
		return b.warn
	case "idle":
		return b.faint
	}
	return b.ok
}

// dot is a filled circle of size in color: a state (sdot), a change (moddot) or the mark
// of a changed row.
func dot(c ui.C, size float32, color gfx.Color) {
	ui.Row(c).Size(size, size).Shrink(0).Radius(size / 2).Background(color)
}

// badge is the count of problems at the end of a row: white on the error or the warning
// color.
func (w *window) badge(c ui.C, count int, warning bool) ui.Box {
	ground := w.bp.err
	if warning {
		ground = w.bp.warn
	}
	return ui.Row(c).Height(16).MinWidth(16).PadX(5).Shrink(0).Radius(8).Background(ground).Center().Children(func() {
		ui.Text(c, formatCount(count)).FontSize(10).Weight(gfx.WeightSemibold).Color(w.bp.white)
	})
}

// tag is a small rounded label of one kind.
func (w *window) tag(c ui.C, kind int, text string) ui.Box {
	b := &w.bp
	ground, words := b.pill, b.sub
	switch kind {
	case tagBlue:
		ground, words = b.chip, b.accent
	case tagGreen:
		ground, words = b.tagGreen, b.ok
	case tagWarn:
		ground, words = b.tagWarn, b.warn
	case tagErr:
		ground, words = b.tagErr, b.err
	}
	box := ui.Row(c).Shrink(0).PadX(7).PadY(1).Radius(999).Items(ui.Center)
	if kind == tagSource {
		box = box.Border(1, b.line)
	} else {
		box = box.Background(ground)
	}
	return box.Children(func() {
		ui.Text(c, text).FontSize(buildTiny).Color(words)
	})
}

// box is a notice: a rounded box in the colors of its kind. Its sentence is a boxText,
// which takes the room the buttons after it leave and wraps inside it.
func (w *window) box(c ui.C, kind int, body func(words gfx.Color)) ui.Box {
	colors := w.bp.boxes[kind]
	return ui.Row(c).FillWidth().MinWidth(0).Shrink(0).PadX(10).PadY(8).Gap(8).Items(ui.Center).Radius(8).
		Border(1, colors.border).Background(colors.background).Children(func() { body(colors.text) })
}

// boxText is the sentence of a notice box.
func boxText(c ui.C, text string, words gfx.Color) ui.Box {
	return ui.Wrap(c, text).FontSize(buildSmall).LineHeight(18.5).Color(words).Grow(1).Shrink(1).MinWidth(0)
}

// boxIcon is the glyph a notice box starts with.
func boxIcon(c ui.C, icon gfx.Icon, color gfx.Color) {
	ui.Icon(c, icon).Size(14, 14).Color(color).Shrink(0)
}

// section is a card of the detail pane: its title row, with help and trailing controls,
// over its body. The body sets its own margins, as each card of the prototype does.
func (w *window) section(c ui.C, title, help string, trailing func(), body func()) ui.Box {
	b := &w.bp
	return ui.Column(c).FillWidth().MinWidth(0).Shrink(0).Radius(10).Border(1, b.line).Background(b.surface).Children(func() {
		ui.Row(c).FillWidth().PadSides(10, 12, 6, 12).Gap(6).Items(ui.Center).Children(func() {
			ui.Text(c, title).FontSize(buildFont).Weight(gfx.WeightSemibold).Color(b.text).Shrink(1).Ellipsis()
			if help != "" {
				w.infoButton(c.Part("help"), help)
			}
			ui.Spacer(c)
			if trailing != nil {
				trailing()
			}
		})
		ui.Column(c).FillWidth().MinWidth(0).Children(body)
	})
}

// buttonKind is how a button of the Build pages looks.
type buttonKind int

const (
	// buttonPlain is outlined on the page's ground; buttonSmall the same, smaller.
	buttonPlain buttonKind = iota
	buttonSmall
	// buttonLink is accent words without a frame; buttonLinkSmall the same, smaller.
	buttonLink
	buttonLinkSmall
	// buttonPrimary is white words on the accent.
	buttonPrimary
)

// button declares a button of the Build pages and reports whether it was pressed. A
// disabled one is dimmed and never reports a press.
func (w *window) button(c ui.C, kind buttonKind, label string, disabled bool) bool {
	return w.buttonTip(c, kind, label, "", disabled)
}

// buttonTip is a button with a tip that says what it does, empty for none.
func (w *window) buttonTip(c ui.C, kind buttonKind, label, tip string, disabled bool) bool {
	b := &w.bp
	box := ui.ButtonBase(c, label).Shrink(0).Radius(6).Items(ui.Center).Justify(ui.Center)
	if tip != "" {
		box = box.Tooltip(tip)
	}
	words, size := b.text, float32(buildFont)
	switch kind {
	case buttonPlain:
		box = box.PadX(12).PadY(4).Border(1, b.line).Background(b.surface).Hover(ui.Look{}.Background(b.hover))
	case buttonSmall:
		box = box.PadX(9).PadY(2).Border(1, b.line).Background(b.surface).Hover(ui.Look{}.Background(b.hover))
		size = buildSmall
	case buttonLink:
		box = box.PadX(4).PadY(2).Hover(ui.Look{}.Background(b.hover))
		words = b.accent
	case buttonLinkSmall:
		box = box.PadX(4).PadY(2).Hover(ui.Look{}.Background(b.hover))
		words, size = b.accent, buildSmall
	case buttonPrimary:
		box = box.PadX(12).PadY(4).Border(1, b.accent).Background(b.accent).Hover(ui.Look{}.Opacity(0.92))
		words = b.white
	}
	if disabled {
		box = box.Disabled(true).Opacity(0.45)
	}
	clicked := box.Clicked()
	box.Children(func() {
		ui.Text(c, label).FontSize(size).Color(words)
	})
	return clicked && !disabled
}

// iconButton is a 26-point square button holding a glyph, with its words as a tip.
func (w *window) iconButton(c ui.C, icon gfx.Icon, label string, disabled bool) bool {
	b := &w.bp
	box := ui.ButtonBase(c, label).Size(26, 26).Shrink(0).Radius(6).Center().Hover(ui.Look{}.Background(b.hover)).Tooltip(label)
	if disabled {
		box = box.Disabled(true).Opacity(0.45)
	}
	clicked := box.Clicked()
	box.Children(func() {
		ui.Icon(c, icon).Size(14, 14).Color(b.sub)
	})
	return clicked && !disabled
}

// filterField is a field of the prototype's look: a frame with the search glyph in front
// of the words. It returns the field's box, whose Submitted reports Enter.
func (w *window) filterField(c ui.C, value *string, label, placeholder string, glyph bool) ui.Box {
	b := &w.bp
	var field ui.Box
	ui.Row(c).FillWidth().MinWidth(0).Height(26).PadX(8).Gap(6).Items(ui.Center).Radius(6).Border(1, b.line).Background(b.surface).Children(func() {
		if glyph {
			ui.Icon(c, icons.Search).Size(12, 12).Color(b.faint).Shrink(0)
		}
		field = ui.TextFieldBase(c, value, label, placeholder).Grow(1).Shrink(1).MinWidth(0).FillHeight().FontSize(buildFont).Color(b.text)
	})
	return field
}

// chip is a filter chip with its count: on, it takes the accent. A dot of the problems'
// color follows the count where one is given. It reports a press.
func (w *window) chip(c ui.C, label string, count int, on bool, mark *gfx.Color) bool {
	b := &w.bp
	ground, words, counted, border := b.pill, b.sub, b.text, gfx.Color{}
	if on {
		ground, words, counted, border = b.chip, b.accent, b.accent, b.accent
	}
	box := ui.ButtonBase(c, label).Shrink(0).PadX(9).PadY(2).Gap(5).Radius(999).Items(ui.Center).Background(ground).Border(1, border)
	clicked := box.Clicked()
	box.Children(func() {
		ui.Text(c, label).FontSize(buildSmall).Color(words)
		ui.Text(c, formatCount(count)).FontSize(buildSmall).Weight(gfx.WeightSemibold).Color(counted)
		if mark != nil {
			ui.Text(c, "●").FontSize(buildSmall).Color(*mark)
		}
	})
	return clicked
}

// segment is one choice of a segmented control.
type segment struct {
	value, label string
	// changed shows the accent dot after the label.
	changed  bool
	disabled bool
	// tip is the segment's tooltip, the reason a disabled one is off.
	tip string
}

// segmented is the prototype's segmented control: the chosen segment raised on the pill.
// A press of another segment writes its value into value and reports true.
func (w *window) segmented(c ui.C, value *string, segments []segment) bool {
	b := &w.bp
	changed := false
	ui.Row(c).Shrink(0).Pad(2).Radius(7).Background(b.pill).Items(ui.Center).Children(func() {
		for _, s := range segments {
			k := c.Key(s.value)
			on := *value == s.value
			box := ui.ButtonBase(k, s.label).Shrink(0).PadX(12).PadY(3).Radius(5).Items(ui.Center)
			words := b.sub
			if on {
				box = box.Background(b.surface).Shadow(gfx.ShadowXS)
				words = b.text
			}
			if s.disabled {
				box = box.Disabled(true).Opacity(0.45)
			}
			if box.Clicked() && !on && !s.disabled {
				*value, changed = s.value, true
			}
			box.Children(func() {
				ui.Text(c, s.label).FontSize(buildFont).Color(words)
				if s.changed {
					ui.Row(k).Size(5, 1).Shrink(0)
					dot(k, 6, b.accent)
				}
			})
		}
	})
	return changed
}

// tabsBar is the row of tabs over a detail: the open one underlined in the accent. A
// disabled tab is dimmed with its reason as a tip. It reports whether a press opened
// another tab.
func (w *window) tabsBar(c ui.C, tabs []segment, open *string) bool {
	b := &w.bp
	changed := false
	ui.Column(c).FillWidth().Shrink(0).Children(func() {
		ui.Row(c).FillWidth().Gap(2).Children(func() {
			for _, t := range tabs {
				k := c.Key(t.value)
				on := t.value == *open
				box := ui.ButtonBase(k, t.label).Shrink(0)
				if t.disabled {
					box = box.Disabled(true).Opacity(0.45)
				}
				if t.tip != "" {
					box = box.Tooltip(t.tip)
				}
				if box.Clicked() && !on && !t.disabled {
					*open, changed = t.value, true
				}
				box.Children(func() {
					ui.Column(k).Children(func() {
						words, weight := b.sub, float32(0)
						if on {
							words, weight = b.text, gfx.WeightSemibold
						}
						ui.Row(k).PadX(12).PadY(6).Children(func() {
							ui.Text(c, t.label).FontSize(buildFont).Weight(weight).Color(words)
						})
						underline := gfx.Color{}
						if on {
							underline = b.accent
						}
						ui.Row(k).FillWidth().Height(2).Background(underline)
					})
				})
			}
		})
		ui.Row(c).FillWidth().Height(1).Background(b.line)
	})
	return changed
}

// pluginTile is the rounded square that stands for a plugin: a short abbreviation of its
// name in white on a color derived from the name, so one plugin keeps one tile
// everywhere. size is 20, 28 or 40.
func (w *window) pluginTile(c ui.C, name string, size float32) {
	w.tile(c, nameColor(name), name, size)
}

// tile is a rounded square in color holding the abbreviation of name: a tool's tile is
// its plugin's color with the tool's own name.
func (w *window) tile(c ui.C, color gfx.Color, name string, size float32) {
	radius, font := float32(7), float32(11)
	switch {
	case size <= 20:
		radius, font = 5, 9
	case size >= 40:
		radius, font = 10, 14
	}
	ui.Row(c).Size(size, size).Shrink(0).Radius(radius).Background(color).Center().Children(func() {
		ui.Text(c, nameAbbreviation(name)).FontSize(font).Weight(gfx.WeightBold).Color(w.bp.white)
	})
}

// glyphTile is the rounded square of a fixed entry of the Build pages: an icon in white
// on its color.
func (w *window) glyphTile(c ui.C, color gfx.Color, icon gfx.Icon, size float32) {
	radius, glyph := float32(7), float32(14)
	if size <= 20 {
		radius, glyph = 5, 11
	}
	ui.Row(c).Size(size, size).Shrink(0).Radius(radius).Background(color).Center().Children(func() {
		ui.Icon(c, icon).Size(glyph, glyph).Color(w.bp.white)
	})
}

// The tiles of the fixed entries.
var (
	toolchainsTile = gfx.RGB24(0x30a46c)
	debuggersTile  = gfx.RGB24(0xe5484d)
	gitTile        = gfx.RGB24(0xf05032)
	kindTile       = gfx.RGB24(0x3e7bfa)
)

// nameColor is the hue of a name, hsl(h, 52%, 46%) with h a hash of its characters, as
// the prototype computes it.
func nameColor(name string) gfx.Color {
	h := 0
	for _, r := range name {
		h = (h*31 + int(r)) % 360
	}
	return hsl(float64(h), 0.52, 0.46)
}

// hsl converts a hue in degrees and a saturation and lightness from 0 to 1 to a color.
func hsl(h, s, l float64) gfx.Color {
	chroma := (1 - abs(2*l-1)) * s
	hp := h / 60
	x := chroma * (1 - abs(mod2(hp)-1))
	var r, g, b float64
	switch {
	case hp < 1:
		r, g = chroma, x
	case hp < 2:
		r, g = x, chroma
	case hp < 3:
		g, b = chroma, x
	case hp < 4:
		g, b = x, chroma
	case hp < 5:
		r, b = x, chroma
	default:
		r, b = chroma, x
	}
	m := l - chroma/2
	channel := func(v float64) uint8 { return uint8(min(max((v+m)*255+0.5, 0), 255)) }
	return gfx.RGB(channel(r), channel(g), channel(b))
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}

// mod2 is v modulo 2 for a non-negative v.
func mod2(v float64) float64 {
	for v >= 2 {
		v -= 2
	}
	return v
}

// nameAbbreviation is the words on a plugin's tile: its first word without "Support",
// whole when it has at most three characters, else its capital initial and second
// letter.
func nameAbbreviation(name string) string {
	cleaned := strings.Map(func(r rune) rune {
		if r < unicode.MaxASCII && (unicode.IsLetter(r) || unicode.IsDigit(r) || r == '.' || r == '+' || r == ' ') {
			return r
		}
		return ' '
	}, strings.ReplaceAll(name, "Support", ""))
	words := strings.Fields(cleaned)
	if len(words) == 0 {
		runes := []rune(name)
		return string(runes[:min(2, len(runes))])
	}
	first := []rune(words[0])
	if len(first) <= 3 {
		return string(first)
	}
	return strings.ToUpper(string(first[0])) + string(first[1])
}

// formatCount writes a count with a comma between each three digits, as the prototype
// does in both languages.
func formatCount(n int) string {
	digits := strconv.Itoa(n)
	sign := ""
	if n < 0 {
		sign, digits = "-", digits[1:]
	}
	var out strings.Builder
	for i, r := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			out.WriteByte(',')
		}
		out.WriteRune(r)
	}
	return sign + out.String()
}

// The count texts below have their own entry for one, because English says
// "1 page", not "1 pages". The entries stay literal so the i18n checker can
// match each key with its parameters.

// kindPageCount is the footer under a kind's page list.
func kindPageCount(language i18n.Language, n int) string {
	if n == 1 {
		return i18n.Shared(language, "desktop.buildSettings.kindPageCountOne")
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.kindPageCount", map[string]string{"count": formatCount(n)})
}

// issuesTitle is the title of the box that lists the tools needing attention.
func issuesTitle(language i18n.Language, n int) string {
	if n == 1 {
		return i18n.Shared(language, "desktop.buildSettings.issuesTitleOne")
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.issuesTitle", map[string]string{"count": formatCount(n)})
}

// toolchainsTileDescription is the Toolchains tile's line on the Build, Execution,
// Deployment page: how many tools, from how many plugins, in which scope. Each count
// picks its own singular, so English never reads "1 tools" or "1 plugins".
func toolchainsTileDescription(language i18n.Language, tools, plugins int, scope string) string {
	switch {
	case tools == 1 && plugins == 1:
		return i18n.SharedFormat(language, "desktop.buildSettings.directoryToolchainsOne", map[string]string{"scope": scope})
	case tools == 1:
		return i18n.SharedFormat(language, "desktop.buildSettings.directoryToolchainsOneTool", map[string]string{
			"plugins": formatCount(plugins), "scope": scope,
		})
	case plugins == 1:
		return i18n.SharedFormat(language, "desktop.buildSettings.directoryToolchainsOnePlugin", map[string]string{
			"tools": formatCount(tools), "scope": scope,
		})
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.directoryToolchains", map[string]string{
		"tools": formatCount(tools), "plugins": formatCount(plugins), "scope": scope,
	})
}

// toolchainListCount is the line under the Toolchains list: how many tool rows are
// listed out of all the tools in the scope.
func toolchainListCount(language i18n.Language, matched, total int) string {
	if total == 1 {
		return i18n.SharedFormat(language, "desktop.buildSettings.listCountOne", map[string]string{"matched": formatCount(matched)})
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.listCount", map[string]string{
		"matched": formatCount(matched), "total": formatCount(total),
	})
}

// debuggerCount is the footer under the Stepping debugger list.
func debuggerCount(language i18n.Language, n int) string {
	if n == 1 {
		return i18n.Shared(language, "desktop.buildSettings.debuggerCountOne")
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.debuggerCount", map[string]string{"count": formatCount(n)})
}

// steppingTileDescription is the Stepping tile on the directory page. customized
// counts the listed debuggers whose filters the user changed, so it never
// exceeds n.
func steppingTileDescription(language i18n.Language, n, customized int) string {
	switch {
	case n == 1 && customized > 0:
		return i18n.Shared(language, "desktop.buildSettings.directoryDebuggersOneCustomized")
	case n == 1:
		return i18n.Shared(language, "desktop.buildSettings.directoryDebuggersOne")
	case customized > 0:
		return i18n.SharedFormat(language, "desktop.buildSettings.directoryDebuggersCustomized", map[string]string{
			"count": formatCount(n), "customized": formatCount(customized),
		})
	default:
		return i18n.SharedFormat(language, "desktop.buildSettings.directoryDebuggers", map[string]string{"count": formatCount(n)})
	}
}

// trustBannerText is the Toolchains warning about tools from environments in an
// untrusted project. sources is already joined.
func trustBannerText(language i18n.Language, n int, sources string) string {
	if n == 1 {
		return i18n.SharedFormat(language, "desktop.buildSettings.trustBannerOne", map[string]string{"sources": sources})
	}
	return i18n.SharedFormat(language, "desktop.buildSettings.trustBanner", map[string]string{"count": formatCount(n), "sources": sources})
}

// midTrim shortens s to at most limit characters by cutting its middle, so both the
// start and the end of a path stay readable.
func midTrim(s string, limit int) string {
	if utf8.RuneCountInString(s) <= limit || limit < 3 {
		return s
	}
	runes := []rune(s)
	head := (limit - 1) / 2
	tail := limit - 1 - head
	return string(runes[:head]) + "…" + string(runes[len(runes)-tail:])
}
