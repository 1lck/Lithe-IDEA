package workbench

import (
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
	ui.CustomLayout(c, &md.layout).FillWidth().Children(func() {
		ui.Row(c).FillWidth().Draw(func(d *ui.DrawContext) {
			md.view.Paint(d.Canvas, components.MarkdownPaint{
				Look: components.MarkdownLookFor(*d.Theme), X: d.Rect.X, Y: d.Rect.Y, Clip: d.Rect,
			})
		})
	})
}
