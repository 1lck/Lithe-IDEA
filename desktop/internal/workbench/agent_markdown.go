package workbench

import (
	"strings"

	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/markdown"
	"github.com/vivaui/viva/ui"
)

// Agent replies are Markdown. Core's markdown.render returns a sanitized HTML fragment,
// and Viva has no HTML renderer, so the transcript draws the reply with Viva's own
// Markdown view (headings, lists, quotes, fenced code, tables, links limited to
// http/https/mailto, no HTML, no images). That is a different parser from the one the
// macOS and Windows clients share through Core; see the Agent note and the feature
// matrix evidence for the gap this leaves.

// agentMarkdown is one reply's parsed document and laid-out view. It is kept on the
// message so a streaming reply re-parses only when its text grew.
type agentMarkdown struct {
	doc    markdown.Document
	view   components.MarkdownView
	parsed int
	layout agentMarkdownLayout
	// input holds the link hit regions of the painted reply (see agentReplyMarkdown).
	input ui.Handlers
}

// agentMarkdownLayout gives the reply the height its laid-out text needs at the width the
// row has. Layout measures text and runs once per layout pass; painting reuses it.
type agentMarkdownLayout struct {
	md     *agentMarkdown
	canvas *gfx.Canvas
	size   float32
}

func (l *agentMarkdownLayout) MeasureWidth(*ui.LayoutContext) float32 { return 0 }

func (l *agentMarkdownLayout) PlaceWidth(ctx *ui.LayoutContext, bounds ui.Rect) {
	if ctx.Count() > 0 {
		ctx.SetX(0, 0)
		ctx.SetWidth(0, bounds.Width)
	}
}

func (l *agentMarkdownLayout) MeasureHeight(ctx *ui.LayoutContext) float32 {
	return l.md.view.Layout(l.canvas, components.MarkdownStyle{Size: l.size, LineHeight: l.size + 7}, &l.md.doc, ctx.ContentWidth())
}

func (l *agentMarkdownLayout) PlaceHeight(ctx *ui.LayoutContext, bounds ui.Rect) {
	if ctx.Count() > 0 {
		ctx.SetY(0, 0)
		ctx.SetHeight(0, l.md.view.Height())
	}
}

// agentReplyMarkdown declares one assistant reply as formatted Markdown.
func (a *App) agentReplyMarkdown(c ui.C, message *agentMessage) {
	md := message.md
	if md == nil {
		md = &agentMarkdown{}
		message.md = md
	}
	if md.parsed != len(message.Text) || md.parsed == 0 {
		md.doc.Parse(message.Text)
		md.parsed = len(message.Text)
	}
	md.layout.md, md.layout.canvas, md.layout.size = md, c.Canvas(), a.theme.Metrics.FontSizeM
	// Viva gap: MarkdownView paints text without accessibility nodes, so a screen reader
	// cannot read a reply yet.
	if md.input.Pointer == nil {
		md.input.Pointer = func(event gfx.PointerEvent) gfx.EventResult {
			if event.Kind != gfx.PointerDown || event.Button != gfx.PointerButtonPrimary {
				return gfx.EventResult{}
			}
			index, ok := event.Target.In(md.input.Parts())
			if !ok {
				return gfx.EventResult{}
			}
			if destination := md.view.Link(index); destination != "" {
				_ = openURL(destination)
				return gfx.EventResult{Handled: true, Repaint: true}
			}
			return gfx.EventResult{}
		}
	}
	ui.CustomLayout(c, &md.layout).FillWidth().Children(func() {
		ui.Control(c.Part("reply"), a.text.Agent.Reply.Link, &md.input).FillWidth().Draw(func(d *ui.DrawContext) {
			md.view.Paint(d.Canvas, components.MarkdownPaint{
				Look: components.MarkdownLookFor(*d.Theme), X: d.Rect.X, Y: d.Rect.Y, Clip: d.Rect,
				Links: md.input.Parts(),
			})
		})
	})
	a.agentCodeActions(c, md)
}

// agentCodeActions puts a copy and an insert action under each code block of the reply. Copy
// takes the block's text to the clipboard; insert adds it to the composer without sending.
func (a *App) agentCodeActions(c ui.C, md *agentMarkdown) {
	codes := md.view.Codes()
	if len(codes) == 0 {
		return
	}
	t := a.text.Agent.Reply
	ui.Column(c.Key("code-actions")).FillWidth().Shrink(0).Gap(4).Children(func() {
		for i, code := range codes {
			text := code.Text
			ui.Row(c.KeyInt(i)).FillWidth().Shrink(0).Gap(6).Children(func() {
				if ui.Button(c.KeyInt(2*i), t.CopyCode).Ghost().Clicked() {
					c.After(func() { _ = app.SetClipboardText(text) })
				}
				if ui.Button(c.KeyInt(2*i+1), t.InsertCode).Ghost().Clicked() {
					c.After(func() { a.insertAgentCode(text) })
				}
			})
		}
	})
}

// insertAgentCode adds a code block to the end of the composer's text as a fenced block. It
// does not send.
func (a *App) insertAgentCode(code string) {
	p := a.project
	if p == nil {
		return
	}
	draft := p.agent.editor.CommittedString()
	if draft != "" && !strings.HasSuffix(draft, "\n") {
		draft += "\n"
	}
	a.setAgentDraft(p, draft+"```\n"+code+"\n```\n")
}
