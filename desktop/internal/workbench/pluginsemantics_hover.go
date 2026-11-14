package workbench

import (
	"context"
	"math"
	"strings"
	"time"
	"unicode"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// The hover popup, as IntelliJ IDEA's quick documentation shows it.
//
// The contents are the language server's Markdown (or plain text, shown as code), drawn by
// Viva's MarkdownView: the signature and examples in fenced blocks, colored by the editor's own
// grammars, rules between sections, prose in the body font and links that open in the browser.
// The popup sits right under the hovered row so the pointer reaches it at once, and a pointer
// hover stays open while the pointer is on the hovered symbol or inside the popup: leaving both
// starts a short delay before it closes, which the pointer coming back cancels.

const (
	// semanticHoverMaxWidth and semanticHoverMinWidth bound the width of the hover text; the
	// popup takes the narrowest width that is as short as the widest.
	semanticHoverMaxWidth = float32(620)
	semanticHoverMinWidth = float32(280)
	// semanticHoverMaxHeight bounds the popup; longer contents scroll inside it.
	semanticHoverMaxHeight = float32(420)
	semanticHoverPadX      = float32(12)
	semanticHoverPadY      = float32(10)
	// semanticHoverMargin keeps the popup off the window's edges.
	semanticHoverMargin = float32(4)
	// semanticHoverShift moves the popup left of the pointer so the pointer lands inside it
	// when it goes straight down.
	semanticHoverShift = float32(12)
	// semanticHoverHideDelay is how long a pointer hover stays open after the pointer left the
	// hovered symbol and the popup, so a pointer on its way to the popup does not close it.
	// Negative closes at once, for tests.
	semanticHoverHideDelay = 400 * time.Millisecond
	// semanticHoverTabWidth is the tab stop the hover text is spread to.
	semanticHoverTabWidth = 4
	// semanticHoverMaxCodeLine is the longest code line the popup colors, as MarkdownView
	// asks no colors for a longer one.
	semanticHoverMaxCodeLine = 4000
)

// hoverPage is the laid-out contents of the open hover popup. It is made on the window thread
// when the answer arrives; only the code tokens come from the background, once.
type hoverPage struct {
	// source is the Markdown the view draws: the contents with tabs spread and plain text
	// fenced as code.
	source string
	// fallback is the language of a fenced block without an info string: the document's.
	fallback string
	doc      markdown.Document
	view     components.MarkdownView
	style    components.MarkdownStyle
	input    ui.Handlers
	draw     func(*ui.DrawContext)
	// tokens are the highlighted lines of the page's code blocks, by language and line text;
	// nil until the background has highlighted them.
	tokens map[hoverCodeKey][]syntax.Token
	// laid says what the view was laid out for; width and height are the text's size there.
	laid          hoverLayoutKey
	width, height float32
	// scroll is how far down the text is; area is where the popup's control was painted last.
	scroll float32
	area   gfx.Rect
	// label is the rendered text, the control's accessible name.
	label string
}

// hoverCodeKey names one highlighted code line.
type hoverCodeKey struct {
	language, line string
}

// hoverLayoutKey is what a layout of a hover page depends on.
type hoverLayoutKey struct {
	maxWidth float32
	size     float32
	face     gfx.MonoFace
	palette  uint64
	tokens   bool
}

// hoverPalette turns syntax colors into the classes MarkdownView colors code by. A class is
// given to each distinct color the first time a token shows it; the palette is rebuilt, and
// every page laid out again, when the window switches between light and dark.
type hoverPalette struct {
	ready   bool
	dark    bool
	theme   *syntax.Theme
	plain   syntax.Color
	classes map[syntax.Color]components.MarkdownCodeClass
	colors  [components.MarkdownCodeClasses]gfx.Color
	version uint64
}

// showSemanticHover opens the hover popup with a server's or provider's answer at a position.
// The hovered symbol is the answer's range when it is on the position's line, or else the word
// around the position.
func (a *App) showSemanticHover(p *project, d *document, contents string, isMarkdown bool, line, column int, span *core.PluginDocumentRange, anchor gfx.Rect, fromPointer bool) {
	contents = truncateHover(contents)
	start, end := hoverSpan(d, line, column, span)
	page := a.newHoverPage(contents, isMarkdown, d.languageID)
	a.stopSemanticHoverHide()
	a.semantics.hover = hoverState{
		open: true, contents: contents, anchor: anchor,
		documentID: d.id, line: line, start: start, end: end,
		fromPointer: fromPointer, page: page,
	}
	a.highlightHover(p, page)
}

// newHoverPage parses contents into a page with its handlers.
func (a *App) newHoverPage(contents string, isMarkdown bool, language string) *hoverPage {
	page := &hoverPage{source: hoverMarkdown(contents, isMarkdown)}
	if isMarkdown {
		page.fallback = language
	}
	page.doc.Parse(page.source)
	page.style.Highlight = func(info, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun {
		return a.hoverCodeRuns(page, info, line, dst)
	}
	page.input = ui.Handlers{
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			dy := event.DeltaY
			if !event.Precise {
				dy *= 3
			}
			before := page.scroll
			page.scroll = page.clamp(page.scroll + dy)
			return gfx.EventResult{Handled: true, Repaint: page.scroll != before}
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary {
				return gfx.EventResult{}
			}
			index, ok := event.Target.In(page.input.Parts())
			if !ok {
				return gfx.EventResult{Handled: true}
			}
			a.followHoverLink(page.view.Link(index))
			return gfx.EventResult{Handled: true, Repaint: true}
		},
	}
	page.draw = func(dc *ui.DrawContext) { a.paintHover(dc, page) }
	return page
}

// hoverMarkdown is the Markdown the popup draws for contents: plain text becomes one fenced
// block, so its line breaks and alignment stay, and tabs are spread to spaces so the code the
// view draws is the code the background highlighted.
func hoverMarkdown(contents string, isMarkdown bool) string {
	contents = strings.ReplaceAll(contents, "\r\n", "\n")
	contents = strings.ReplaceAll(contents, "\r", "\n")
	contents = spreadHoverTabs(contents)
	if isMarkdown {
		return contents
	}
	fence := strings.Repeat("`", max(3, longestRun(contents, '`')+1))
	return fence + "\n" + strings.TrimRight(contents, "\n") + "\n" + fence
}

// spreadHoverTabs replaces every tab with the spaces up to the next tab stop of its line.
func spreadHoverTabs(text string) string {
	if !strings.Contains(text, "\t") {
		return text
	}
	var b strings.Builder
	b.Grow(len(text) + 16)
	column := 0
	for _, r := range text {
		switch r {
		case '\t':
			n := semanticHoverTabWidth - column%semanticHoverTabWidth
			b.WriteString(strings.Repeat(" ", n))
			column += n
		case '\n':
			b.WriteRune(r)
			column = 0
		default:
			b.WriteRune(r)
			column++
		}
	}
	return b.String()
}

// longestRun is the length of the longest run of c in text.
func longestRun(text string, c byte) int {
	longest, run := 0, 0
	for i := 0; i < len(text); i++ {
		if text[i] == c {
			run++
			longest = max(longest, run)
		} else {
			run = 0
		}
	}
	return longest
}

// hoverCodeLanguage is the language a fenced block is highlighted as: the first word of its
// info string, or the fallback when it has none.
func hoverCodeLanguage(info, fallback string) string {
	if fields := strings.Fields(info); len(fields) > 0 {
		return strings.ToLower(fields[0])
	}
	return fallback
}

// highlightHover colors the page's code blocks away from the window thread with the editor's
// grammars. The tokens reach the page only while it is still the open hover.
func (a *App) highlightHover(p *project, page *hoverPage) {
	if p == nil {
		return
	}
	hasCode := false
	for _, block := range page.doc.Blocks {
		if block.Kind == markdown.Code && hoverCodeLanguage(block.Info, page.fallback) != "" {
			hasCode = true
			break
		}
	}
	if !hasCode {
		return
	}
	registry, source, fallback := a.syntaxRegistry(), page.source, page.fallback
	a.background(p, 0, func(context.Context) func(*App) {
		tokens := hoverCodeTokens(registry, source, fallback)
		return func(a *App) {
			if a.semantics.hover.page == page {
				page.tokens = tokens
			}
		}
	})
}

// hoverCodeTokens highlights every line of the fenced blocks of source whose language the
// registry knows. A whole block is read through one highlighter, so a comment or string that
// spans lines is colored as the editor colors it.
func hoverCodeTokens(registry *syntax.Registry, source, fallback string) map[hoverCodeKey][]syntax.Token {
	tokens := map[hoverCodeKey][]syntax.Token{}
	var doc markdown.Document
	doc.Parse(source)
	for _, block := range doc.Blocks {
		if block.Kind != markdown.Code {
			continue
		}
		language := hoverCodeLanguage(block.Info, fallback)
		if language == "" {
			continue
		}
		grammar := registry.Syntax(language)
		if grammar == nil {
			continue
		}
		text := rope.FromString(block.Text)
		highlighter := syntax.NewHighlighter(grammar, text, syntax.HighlighterOptions{})
		for i := 0; i < text.LineCount(); i++ {
			line := text.Line(i)
			key := hoverCodeKey{language: language, line: line}
			if len(line) > semanticHoverMaxCodeLine {
				continue
			}
			if _, ok := tokens[key]; ok {
				continue
			}
			tokens[key] = highlighter.Line(nil, i)
		}
		highlighter.Close()
	}
	return tokens
}

// hoverCodeRuns is the page's MarkdownStyle.Highlight: the colored stretches of one code line,
// from the tokens the background found. A token in the plain text color is left plain.
func (a *App) hoverCodeRuns(page *hoverPage, info, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun {
	tokens := page.tokens[hoverCodeKey{language: hoverCodeLanguage(info, page.fallback), line: line}]
	if len(tokens) == 0 {
		return dst
	}
	palette := a.hoverPalette()
	for i, token := range tokens {
		start, end := int(token.Start), len(line)
		if i+1 < len(tokens) {
			end = int(tokens[i+1].Start)
		}
		if start < 0 || start >= end || end > len(line) {
			continue
		}
		color := palette.theme.Style(token.Name).Foreground
		if color == palette.plain {
			continue
		}
		class := palette.class(color)
		if class == 0 {
			continue
		}
		if n := len(dst); n > 0 && dst[n-1].Class == class && dst[n-1].End == start {
			dst[n-1].End = end
			continue
		}
		dst = append(dst, components.MarkdownCodeRun{Start: start, End: end, Class: class})
	}
	return dst
}

// hoverPalette is the window's palette for hover code, rebuilt for the current appearance.
// Tokens use the editor's Lithe scheme; a token in the scheme's text color is plain code,
// drawn in the popup's text color.
func (a *App) hoverPalette() *hoverPalette {
	palette := &a.semantics.hoverColors
	if palette.ready && palette.dark == a.colors.Dark {
		return palette
	}
	theme := syntax.BuildTheme(syntax.ThemeOptions{Dark: a.colors.Dark, Scheme: syntax.SchemeLithe}, syntax.DefaultPalette())
	*palette = hoverPalette{
		ready: true, dark: a.colors.Dark, theme: theme, plain: theme.Default().Foreground,
		classes: map[syntax.Color]components.MarkdownCodeClass{}, version: palette.version + 1,
	}
	return palette
}

// class is the code class of color, given the next free class the first time; 0 (plain) once
// every class is taken.
func (p *hoverPalette) class(color syntax.Color) components.MarkdownCodeClass {
	if class, ok := p.classes[color]; ok {
		return class
	}
	if len(p.classes)+1 >= int(components.MarkdownCodeClasses) {
		return 0
	}
	class := components.MarkdownCodeClass(len(p.classes) + 1)
	p.classes[color] = class
	p.colors[class] = gfx.Color{
		Red: float32(color>>16&0xff) / 255, Green: float32(color>>8&0xff) / 255,
		Blue: float32(color&0xff) / 255, Alpha: 1,
	}
	return class
}

// layoutHover lays the page out at the narrowest width, between the popup's minimum and
// maxWidth, that is no taller than the widest: short contents get a narrow popup and long
// prose a wide one, as IDEA sizes its documentation popup.
func (a *App) layoutHover(canvas *gfx.Canvas, page *hoverPage, maxWidth float32) {
	palette := a.hoverPalette()
	size := a.theme.Metrics.FontSizeM
	page.style.Size = size
	page.style.LineHeight = float32(math.Round(float64(size) * 1.5))
	page.style.MonoFace = a.fonts.editor.face
	key := hoverLayoutKey{maxWidth: maxWidth, size: size, face: page.style.MonoFace, palette: palette.version, tokens: page.tokens != nil}
	if page.laid == key {
		return
	}
	page.laid = key
	layout := func(width float32) float32 { return page.view.Layout(canvas, page.style, &page.doc, width) }
	minWidth := min(semanticHoverMinWidth, maxWidth)
	full := layout(maxWidth)
	width := maxWidth
	if minWidth < maxWidth {
		if layout(minWidth) <= full {
			width = minWidth
		} else {
			// lo is too narrow and hi is as short as the widest.
			lo, hi := minWidth, maxWidth
			for hi-lo > 4 {
				mid := (lo + hi) / 2
				if layout(mid) <= full {
					hi = mid
				} else {
					lo = mid
				}
			}
			width = hi
		}
	}
	page.height = layout(width)
	page.width = width
	page.label = page.view.SelectedText(components.MarkdownSelection{Focus: page.view.TextLen()})
}

// clamp keeps a scroll of the page inside it.
func (page *hoverPage) clamp(y float32) float32 {
	return min(max(y, 0), max(page.height+2*semanticHoverPadY-page.area.Height, 0))
}

// hoverPopup declares the open hover popup under the hovered row, or over it when the window
// has more room there. The popup takes no focus, so the editor keeps the keyboard.
func (a *App) hoverPopup(c ui.C) {
	state := &a.semantics.hover
	page := state.page
	canvas := c.Canvas()
	if page == nil || canvas == nil {
		return
	}
	bounds := c.Bounds()
	maxWidth := min(semanticHoverMaxWidth, bounds.Width-2*semanticHoverMargin-2*semanticHoverPadX)
	if maxWidth < 40 {
		return
	}
	a.layoutHover(canvas, page, maxWidth)
	width := page.width + 2*semanticHoverPadX
	height := min(page.height+2*semanticHoverPadY, semanticHoverMaxHeight)
	anchor := state.anchor
	below := bounds.Y + bounds.Height - semanticHoverMargin - (anchor.Y + anchor.Height)
	above := anchor.Y - bounds.Y - semanticHoverMargin
	y := anchor.Y + anchor.Height
	if height > below && above > below {
		height = min(height, above)
		y = anchor.Y - height
	} else if below > 0 {
		height = min(height, below)
	}
	x := anchor.X - semanticHoverShift
	x = min(max(x, bounds.X+semanticHoverMargin), max(bounds.X+bounds.Width-semanticHoverMargin-width, bounds.X+semanticHoverMargin))
	y = min(max(y, bounds.Y+semanticHoverMargin), max(bounds.Y+bounds.Height-semanticHoverMargin-height, bounds.Y+semanticHoverMargin))
	state.rect = gfx.Rect{X: x, Y: y, Width: width, Height: height}
	label := i18n.Shared(a.language(), "desktop.semantics.hover")
	ui.Stack(c).Fill().Children(func() {
		ui.Column(c).Absolute().Left(x).Top(y).Width(width).Height(height).
			Background(a.theme.Popover).Border(1, a.theme.Border).
			Radius(a.theme.Metrics.RadiusPopup()).Shadow(gfx.ShadowMD).
			HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
			Children(func() {
				// A part names the next element only, so it is given again for the control; the
				// hit is given again so a press on the popup leaves the keyboard to the editor.
				const name = "semantic-hover"
				id := ui.ID(c.Part(name))
				ui.Control(c.Part(name), page.label, &page.input).Fill().Draw(page.draw).
					HitWith(id, page.label, gfx.HitOptions{Role: gfx.RoleGroup, SkipFocus: true})
			})
	})
}

// paintHover draws the page inside the popup, with a thin bar when it scrolls.
func (a *App) paintHover(dc *ui.DrawContext, page *hoverPage) {
	page.area = dc.Rect
	page.scroll = page.clamp(page.scroll)
	look := components.MarkdownLookFor(a.theme)
	look.Code = a.hoverPalette().colors
	clip := gfx.Rect{X: dc.Rect.X, Y: dc.Rect.Y + 2, Width: dc.Rect.Width, Height: max(dc.Rect.Height-4, 0)}
	page.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: look,
		X:    dc.Rect.X + semanticHoverPadX, Y: dc.Rect.Y + semanticHoverPadY - page.scroll,
		Clip:  clip,
		Links: page.input.Parts(),
	})
	total := page.height + 2*semanticHoverPadY
	if total <= dc.Rect.Height || dc.Rect.Height <= 8 {
		return
	}
	track := dc.Rect.Height - 8
	thumb := max(track*dc.Rect.Height/total, 16)
	top := dc.Rect.Y + 4 + (track-thumb)*page.scroll/(total-dc.Rect.Height)
	bar := a.colors.Subtle
	bar.Alpha *= 0.45
	dc.Canvas.Rounded(gfx.Rect{X: dc.Rect.X + dc.Rect.Width - 6, Y: top, Width: 3, Height: thumb}, 1.5, bar)
}

// followHoverLink opens a web or mail link of the hover in the system browser, as Core resolves
// it (markdown.resolveReference); other links, such as a server's own document addresses, are
// not followed. The hover belongs to no file, so it has no path to resolve a relative one.
func (a *App) followHoverLink(destination string) {
	kernel, ok := a.kernel.(markdownKernel)
	if !ok {
		return
	}
	p := a.project
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		target, err := kernel.ResolveMarkdownReference(ctx, "", "", destination, core.MarkdownLink)
		if err == nil && target.Kind != "external" {
			return nil
		}
		return func(a *App) {
			if err == nil {
				err = openURL(target.URL)
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
				return
			}
			a.closeSemanticHover()
		}
	})
}

// hoverSpan is the hovered symbol on line, as UTF-16 columns from start to end: the answer's
// range when it lies on line around column, or else the word around column.
func hoverSpan(d *document, line, column int, span *core.PluginDocumentRange) (int, int) {
	if span != nil && span.Start.Line == line && span.End.Line == line &&
		span.Start.UTF16Column <= column && column <= span.End.UTF16Column {
		return span.Start.UTF16Column, span.End.UTF16Column
	}
	text := d.view.TextSnapshot()
	if line < 0 || line >= text.LineCount() {
		return column, column
	}
	return hoverWordSpan(text.Line(line), column)
}

// hoverWordSpan is the identifier of text that column (UTF-16) is in or at the edge of, as
// UTF-16 columns; a column away from any identifier spans only itself.
func hoverWordSpan(text string, column int) (int, int) {
	offset, start := 0, -1
	for _, r := range text {
		if isHoverWordRune(r) {
			if start < 0 {
				start = offset
			}
		} else if start >= 0 {
			if start <= column && column <= offset {
				return start, offset
			}
			start = -1
		}
		offset++
		if r >= 0x10000 {
			offset++
		}
	}
	if start >= 0 && start <= column && column <= offset {
		return start, offset
	}
	return column, column
}

func isHoverWordRune(r rune) bool {
	return r == '_' || r == '$' || unicode.IsLetter(r) || unicode.IsDigit(r)
}

// hoverRowAnchor is the rectangle a pointer hover is placed under: the pointer's x across the
// whole row it is on, so the popup starts right below the row and not over the next line.
func hoverRowAnchor(d *document, x, y float32) gfx.Rect {
	height := d.view.LineHeight()
	if _, fraction, ok := d.view.LineRowAt(y); ok && height > 0 {
		return gfx.Rect{X: x, Y: y - fraction*height, Height: height}
	}
	return gfx.Rect{X: x, Y: y}
}

// hoverCovers reports whether the open hover is about the symbol at line and column of d.
func (a *App) hoverCovers(d *document, line, column int) bool {
	hover := &a.semantics.hover
	return hover.open && d != nil && hover.documentID == d.id && hover.line == line &&
		hover.start <= column && column <= hover.end
}

// holdSemanticHover keeps the open hover while the pointer is on its symbol or popup: a
// pending close stops, and a hover the pointer armed on its way, or already asked for, is
// dropped so it cannot replace this one.
func (a *App) holdSemanticHover() {
	a.stopSemanticHoverHide()
	if a.semantics.candidate.cancel != nil {
		a.semantics.candidate.cancel()
	}
	a.semantics.candidate = hoverCandidate{}
	a.cancelSemanticKind(pluginSemanticHover)
}

// releaseSemanticHover starts the delay after which a pointer hover the pointer left closes.
// A hover opened from the keyboard stays until it is dismissed.
func (a *App) releaseSemanticHover() {
	state := &a.semantics
	if !state.hover.open || !state.hover.fromPointer || state.hideCancel != nil {
		return
	}
	delay := state.hoverHideDelay
	if delay == 0 {
		delay = semanticHoverHideDelay
	}
	p := state.project
	if delay < 0 || p == nil || a.project != p {
		a.closeSemanticHover()
		return
	}
	state.hideToken++
	token := state.hideToken
	ctx, cancel := context.WithCancel(p.ctx)
	state.hideCancel = cancel
	a.background(p, 0, func(context.Context) func(*App) {
		defer cancel()
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			// log-exempt: 用户取消：指针回到悬停符号或弹窗、弹窗关闭或项目关闭会取消等待。
			return nil
		}
		return func(a *App) {
			if a.semantics.hideToken != token || a.semantics.hideCancel == nil {
				return
			}
			a.semantics.hideCancel = nil
			a.closeSemanticHover()
		}
	})
}

// stopSemanticHoverHide stops a pending close of the hover.
func (a *App) stopSemanticHoverHide() {
	if a.semantics.hideCancel != nil {
		a.semantics.hideCancel()
		a.semantics.hideCancel = nil
	}
	a.semantics.hideToken++
}

// hoverTrackPointer follows the pointer over the whole window for an open pointer hover: inside
// the popup it holds the hover, over the editor the editor decides, and anywhere else the hover
// starts to close. It runs before the pointer reaches the element under it.
func (a *App) hoverTrackPointer(event gfx.PointerEvent) {
	hover := &a.semantics.hover
	if event.Kind != gfx.PointerMove || !hover.open || !hover.fromPointer {
		return
	}
	if pointInRect(hover.rect, event.X, event.Y) {
		a.holdSemanticHover()
		return
	}
	if _, d := a.pluginSemanticHit(event.Target); d != nil {
		return
	}
	a.releaseSemanticHover()
}
