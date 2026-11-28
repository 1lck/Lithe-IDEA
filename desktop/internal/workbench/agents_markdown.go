package workbench

import (
	"context"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	vivatext "github.com/vivaui/viva/text"
	"github.com/vivaui/viva/ui"
)

// An agent's reply is Markdown. The Agent tool window draws it natively with Viva's
// MarkdownView, as the hover popup and the update notes draw theirs, and never in a web view:
// headings, lists, bold and italic, rules, tables, quotes, inline code on a tinted pill, fenced
// blocks in the editor's font with the editor's grammars and links that open on a click.
//
// The view is laid out once per width and text, in the layout pass (a reply's height depends on
// the width the list gives it), and painted every frame. While a reply streams in, each new
// piece re-parses and lays out the text again; the code blocks are colored once the reply is
// complete, away from the window thread, from the same grammars the hover uses.
//
// The text can be selected with the pointer (a drag, a double click for a word, a triple click
// for a line) and copied with ⌘C; ⌘A selects the whole reply. A press clears the selection
// of the other replies of the conversation. A click on a web link opens the browser; a link to a
// file inside the project opens the file in the editor, at the line the link names. Nothing of
// the reply is logged.

// agentMarkdown is one reply of a conversation, drawn by a MarkdownView. It belongs to the
// window thread.
type agentMarkdown struct {
	owner *agentConversation
	// source is the reply's Markdown; revision counts its changes, from 1.
	source   string
	revision uint64
	doc      markdown.Document
	view     components.MarkdownView
	style    components.MarkdownStyle
	input    ui.Handlers
	draw     func(*ui.DrawContext)
	sizer    agentMarkdownSizer
	// canvas is the canvas of the paint that declared the view, which the layout pass measures
	// with.
	canvas *gfx.Canvas
	// laid says what the view was laid out for; width is the width the layout pass gave the view
	// last and height the text's height there.
	laid          agentMarkdownKey
	width, height float32
	// label is the rendered text: the control's accessible name and what a word or a line is
	// found in.
	label string
	id    gfx.ID
	// selection is the selected part of label.
	selection ui.TextRange
	// pressed is set while the primary button is down on the view; moved once it dragged.
	pressed, moved bool
	press          gfx.Point
	clicks         int
	// link is the link the press landed on, -1 for none.
	link int
	// tokens are the highlighted lines of the code blocks; highlighted is the revision they, or
	// the highlight on its way, are for.
	tokens      map[hoverCodeKey][]syntax.Token
	highlighted uint64
}

// agentMarkdownKey is what a layout of a reply depends on.
type agentMarkdownKey struct {
	width, size, lineHeight float32
	face                    gfx.MonoFace
	palette, revision       uint64
	tokens                  bool
}

// agentMarkdownSizer gives a reply the width of its row and takes the height of its text there.
type agentMarkdownSizer struct {
	a  *App
	md *agentMarkdown
}

func (s *agentMarkdownSizer) MeasureWidth(*ui.LayoutContext) float32 { return 0 }

func (s *agentMarkdownSizer) PlaceWidth(ctx *ui.LayoutContext, bounds ui.Rect) {
	if md := s.md; bounds.Width != md.width {
		md.width = bounds.Width
		s.a.layoutAgentMarkdown(md)
	}
	if ctx.Count() > 0 {
		ctx.SetX(0, bounds.X)
		ctx.SetWidth(0, bounds.Width)
	}
}

func (s *agentMarkdownSizer) MeasureHeight(*ui.LayoutContext) float32 { return s.md.height }

func (s *agentMarkdownSizer) PlaceHeight(ctx *ui.LayoutContext, bounds ui.Rect) {
	if ctx.Count() > 0 {
		ctx.SetY(0, bounds.Y)
		ctx.SetHeight(0, bounds.Height)
	}
}

// agentMarkdownOf is the view of a reply, made the first time the reply is drawn and kept, by
// the entry's serial, while the transcript keeps the entry.
func (a *App) agentMarkdownOf(conversation *agentConversation, serial uint64, source string) *agentMarkdown {
	if conversation.markdown == nil {
		conversation.markdown = map[uint64]*agentMarkdown{}
	}
	md := conversation.markdown[serial]
	if md == nil {
		md = a.newAgentMarkdown(conversation)
		conversation.markdown[serial] = md
	}
	md.setSource(source)
	return md
}

// newAgentMarkdown makes the view of a reply of conversation, with its handlers.
func (a *App) newAgentMarkdown(conversation *agentConversation) *agentMarkdown {
	md := &agentMarkdown{owner: conversation, link: -1}
	md.sizer = agentMarkdownSizer{a: a, md: md}
	md.style.Highlight = func(info, line string, dst []components.MarkdownCodeRun) []components.MarkdownCodeRun {
		return a.markdownCodeRuns(md.tokens, "", info, line, dst)
	}
	md.input = ui.Handlers{Role: gfx.RoleGroup, Pointer: func(event gfx.PointerEvent) gfx.EventResult {
		return a.agentMarkdownPointer(md, event)
	}}
	md.draw = func(dc *ui.DrawContext) { a.paintAgentMarkdown(dc, md) }
	return md
}

// setSource takes the reply's current text, parsing it when it changed.
func (md *agentMarkdown) setSource(source string) {
	if source == md.source && md.revision > 0 {
		return
	}
	md.source = source
	md.revision++
	md.doc.Parse(source)
}

// agentMarkdownBlock declares the reply, as wide as the row and as tall as its text. A
// complete reply has its code blocks colored at the end of the paint.
func (a *App) agentMarkdownBlock(c ui.C, md *agentMarkdown, complete bool) {
	md.canvas = c.Canvas()
	if md.width > 0 {
		// The text, the theme or the colors may have changed at the width the row already has.
		a.layoutAgentMarkdown(md)
	}
	var control ui.Box
	ui.CustomLayout(c, &md.sizer).FillWidth().Children(func() {
		md.id = ui.ID(c.Part("markdown"))
		control = ui.Control(c.Part("markdown"), md.label, &md.input).
			HitWith(md.id, md.label, gfx.HitOptions{Role: gfx.RoleGroup, Cursor: gfx.PointerCursorText}).
			Draw(md.draw)
	})
	if control.Shortcut(ui.Primary, "c") {
		if text := md.view.SelectedText(md.selection); text != "" {
			c.After(func() { a.copyAgentText(text) })
		}
	}
	if control.Shortcut(ui.Primary, "a") {
		md.selection = ui.TextRange{Focus: md.view.TextLen()}
	}
	if complete && md.highlighted != md.revision {
		a.agentsView.highlights = append(a.agentsView.highlights, md)
	}
}

// layoutAgentMarkdown lays the reply out at the width its row gave it, in the body font a point
// larger than the window's with code in the editor's, when anything it depends on changed.
func (a *App) layoutAgentMarkdown(md *agentMarkdown) {
	if md.canvas == nil || md.width <= 0 {
		return
	}
	palette := a.hoverPalette()
	size := a.theme.Metrics.FontSizeM + 1
	key := agentMarkdownKey{
		width: md.width, size: size, lineHeight: float32(math.Round(float64(size) * 1.6)),
		face: a.fonts.editor.face, palette: palette.version, revision: md.revision, tokens: md.tokens != nil,
	}
	if md.laid == key {
		return
	}
	md.laid = key
	md.style.Size = key.size
	md.style.LineHeight = key.lineHeight
	md.style.MonoFace = key.face
	md.height = md.view.Layout(md.canvas, md.style, &md.doc, md.width)
	md.label = md.view.SelectedText(ui.TextRange{Focus: md.view.TextLen()})
	if end := len(md.label); md.selection.Anchor > end || md.selection.Focus > end {
		md.selection = ui.TextRange{}
	}
}

// agentMarkdownLook colors a reply: code blocks on a quiet card with a border, inline code on a
// faint purple pill, links in the accent color and code in the editor's colors.
func (a *App) agentMarkdownLook() components.MarkdownLook {
	look := components.MarkdownLookFor(a.theme)
	dark := a.colors.Dark
	look.Text, look.Muted, look.Link = a.colors.Text, a.colors.Subtle, a.colors.Accent
	look.CodeFill = pick(dark, 0x2B2D30, 0xF7F8FA)
	look.Line = pick(dark, 0x43454A, 0xDFE1E5)
	purple := pick(dark, 0xB589EC, 0x834DF0)
	purple.Alpha = 0.14
	if dark {
		purple.Alpha = 0.22
	}
	look.InlineCodeFill = purple
	look.Selection = a.colors.Selection
	look.Radius = 10
	look.Code = a.hoverPalette().colors
	return look
}

// paintAgentMarkdown draws the reply where the layout put its control, with its selection and
// the hit regions of its links.
func (a *App) paintAgentMarkdown(dc *ui.DrawContext, md *agentMarkdown) {
	md.view.Paint(dc.Canvas, components.MarkdownPaint{
		Look: a.agentMarkdownLook(), X: dc.Rect.X, Y: dc.Rect.Y,
		Links: md.input.Parts(), Selection: md.selection,
	})
}

// agentMarkdownPointer selects the reply's text with the primary button and opens the link a
// click lands on.
func (a *App) agentMarkdownPointer(md *agentMarkdown, event gfx.PointerEvent) gfx.EventResult {
	at := gfx.Point{X: event.X, Y: event.Y}
	switch event.Kind {
	case gfx.PointerDown:
		if event.Button != gfx.PointerButtonPrimary {
			return gfx.EventResult{}
		}
		md.claimSelection()
		md.pressed, md.moved, md.press, md.clicks, md.link = true, false, at, max(event.ClickCount, 1), -1
		if index, ok := event.Target.In(md.input.Parts()); ok {
			md.link = index
		}
		took := gfx.EventResult{Handled: true, Repaint: true, Focus: md.id}
		offset, ok := md.view.OffsetAt(at)
		if !ok {
			md.selection = ui.TextRange{}
			return took
		}
		switch {
		case md.clicks >= 3:
			md.selection = lineRangeAt(md.label, offset)
		case md.clicks == 2:
			md.selection = wordRangeAt(md.label, offset)
		case event.Modifiers&gfx.ModifierShift != 0:
			md.selection.Focus = offset
			md.moved = true
		default:
			md.selection = ui.TextRange{Anchor: offset, Focus: offset}
		}
		return took
	case gfx.PointerMove:
		if !md.pressed {
			return gfx.EventResult{}
		}
		if !md.moved && math.Abs(float64(at.X-md.press.X)) < 3 && math.Abs(float64(at.Y-md.press.Y)) < 3 {
			return gfx.EventResult{Handled: true}
		}
		md.moved = true
		if offset, ok := md.view.OffsetAt(at); ok {
			md.selection.Focus = offset
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	case gfx.PointerUp:
		if !md.pressed {
			return gfx.EventResult{}
		}
		md.pressed = false
		if !md.moved && md.clicks == 1 && md.link >= 0 {
			if index, ok := event.Target.In(md.input.Parts()); ok && index == md.link {
				a.openAgentLink(md.view.Link(index))
			}
		}
		return gfx.EventResult{Handled: true, Repaint: true}
	}
	return gfx.EventResult{}
}

// claimSelection makes this reply the conversation's selected one, clearing the selection of
// the reply that had it.
func (md *agentMarkdown) claimSelection() {
	owner := md.owner
	if owner == nil {
		return
	}
	if previous := owner.selected; previous != nil && previous != md {
		previous.selection = ui.TextRange{}
	}
	owner.selected = md
}

// wordRangeAt is the word, or the run of spaces or punctuation, around a byte offset of text.
func wordRangeAt(text string, offset int) ui.TextRange {
	offset = min(max(offset, 0), len(text))
	for offset > 0 && offset < len(text) && !utf8.RuneStart(text[offset]) {
		offset--
	}
	word := vivatext.WordRange(text, utf8.RuneCountInString(text[:offset]))
	return ui.TextRange{Anchor: runeByteOffset(text, word.Start), Focus: runeByteOffset(text, word.End)}
}

// lineRangeAt is the line of text around a byte offset, without its line break.
func lineRangeAt(text string, offset int) ui.TextRange {
	offset = min(max(offset, 0), len(text))
	start := strings.LastIndexByte(text[:offset], '\n') + 1
	end := len(text)
	if at := strings.IndexByte(text[offset:], '\n'); at >= 0 {
		end = offset + at
	}
	return ui.TextRange{Anchor: start, Focus: end}
}

// runeByteOffset is the byte offset of the rune with index runes in text, its length past the end.
func runeByteOffset(text string, runes int) int {
	if runes <= 0 {
		return 0
	}
	n := 0
	for offset := range text {
		if n == runes {
			return offset
		}
		n++
	}
	return len(text)
}

// copyAgentText puts text of a conversation on the clipboard.
func (a *App) copyAgentText(text string) {
	a.copyAgentHistoryText(text)
}

// endAgentChatFrame starts the work the conversation's paint asked for: coloring the code
// blocks of the replies that are complete. The paint only notes them, as an After runs only
// after a paint that delivers an event, and a reply that completes or scrolls into view comes
// with none.
func (a *App) endAgentChatFrame() {
	v := &a.agentsView
	queued := v.highlights
	v.highlights = v.highlights[:0]
	for _, md := range queued {
		a.highlightAgentMarkdown(md)
	}
}

// highlightAgentMarkdown colors the reply's code blocks away from the window thread with the
// editor's grammars; the tokens reach the reply while its text is still the one they are for.
func (a *App) highlightAgentMarkdown(md *agentMarkdown) {
	if md.highlighted == md.revision {
		return
	}
	md.highlighted = md.revision
	blocks := markdownCodeBlocks(&md.doc, "")
	if len(blocks) == 0 {
		return
	}
	registry, revision := a.syntaxRegistry(), md.revision
	a.background(a.project, 0, func(context.Context) func(*App) {
		tokens := hoverCodeTokens(registry, blocks)
		return func(*App) {
			if md.revision == revision {
				md.tokens = tokens
			}
		}
	})
}

// openAgentLink follows a link of a reply: a web address opens in the browser, a file inside the
// open project opens in the editor at the line the link names. Anything else is ignored: the
// reply is the agent's, so it opens neither other schemes nor files outside the project.
func (a *App) openAgentLink(destination string) {
	if parsed, err := url.Parse(destination); err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" {
		a.performed("agents.link", surfaceButton)
		if err := openURL(parsed.String()); err != nil {
			a.operationFailed("open_url", err)
		}
		return
	}
	p := a.project
	if p == nil || p.remote != nil {
		return
	}
	if path, line, ok := agentLinkFile(p.root, destination); ok {
		a.openAgentFile(p, path, line)
	}
}

// openAgentFile opens a file an agent named, inside the open local project, at the one-based
// line, when it is a regular file; it is checked away from the window thread.
func (a *App) openAgentFile(p *project, path string, line int) {
	if p == nil || p.remote != nil || !within(p.root, path) {
		return
	}
	a.background(p, kernelCallTimeout, func(context.Context) func(*App) {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			return nil
		}
		return func(a *App) {
			a.performed("agents.openFile", surfaceButton)
			a.openFileAt(p, path, line)
		}
	})
}

// agentLinkFile resolves a link of a reply to a file below root and the one-based line it names:
// a path, absolute or relative to root, or a file URL, with an optional ":12", ":12:5" or "#L12"
// after it.
func agentLinkFile(root, destination string) (string, int, bool) {
	if root == "" || destination == "" {
		return "", 0, false
	}
	target := destination
	if parsed, err := url.Parse(destination); err == nil && parsed.Scheme != "" {
		if parsed.Scheme != "file" || (parsed.Host != "" && parsed.Host != "localhost") {
			return "", 0, false
		}
		target = parsed.Path
		if parsed.Fragment != "" {
			target += "#" + parsed.Fragment
		}
	} else if unescaped, err := url.PathUnescape(destination); err == nil {
		target = unescaped
	}
	line := 0
	if at := strings.LastIndex(target, "#L"); at >= 0 {
		if n, ok := leadingNumber(target[at+2:]); ok {
			line = n
		}
		target = target[:at]
	}
	if line == 0 {
		target, line = cutLineSuffix(target)
	}
	if target == "" {
		return "", 0, false
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(root, filepath.FromSlash(target))
	}
	target = filepath.Clean(target)
	if !within(root, target) {
		return "", 0, false
	}
	return target, line, true
}

// cutLineSuffix takes a ":line" or ":line:column" off the end of a path.
func cutLineSuffix(path string) (string, int) {
	head, last, ok := cutLastColon(path)
	if !ok {
		return path, 0
	}
	n, err := strconv.Atoi(last)
	if err != nil || n <= 0 {
		return path, 0
	}
	if before, previous, ok := cutLastColon(head); ok {
		if line, err := strconv.Atoi(previous); err == nil && line > 0 {
			return before, line
		}
	}
	return head, n
}

// cutLastColon splits s at its last colon.
func cutLastColon(s string) (string, string, bool) {
	at := strings.LastIndexByte(s, ':')
	if at < 0 {
		return s, "", false
	}
	return s[:at], s[at+1:], true
}

// leadingNumber is the positive number s starts with.
func leadingNumber(s string) (int, bool) {
	end := 0
	for end < len(s) && s[end] >= '0' && s[end] <= '9' {
		end++
	}
	n, err := strconv.Atoi(s[:end])
	return n, err == nil && n > 0
}
