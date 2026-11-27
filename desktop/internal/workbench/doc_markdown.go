package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/markdown"
)

// populateMarkdownFromDocIR translates Core's structured native document IR
// into a Viva markdown.Document for hover popups and rendered doc comments.
func populateMarkdownFromDocIR(doc *markdown.Document, ir core.DocRenderResponse, localizeTag func(string) string) {
	if doc == nil {
		return
	}
	doc.Reset()
	for i := range ir.Blocks {
		block := &ir.Blocks[i]
		switch block.Kind {
		case core.DocBlockParagraph:
			doc.AppendParagraph(block.Quote, block.Level, docIRSpans(block.Spans))
		case core.DocBlockHeading:
			doc.AppendHeading(block.Quote, block.Level, docIRSpans(block.Spans))
		case core.DocBlockItem:
			doc.AppendItem(block.Quote, block.Level, block.Number, docIRSpans(block.Spans))
		case core.DocBlockCode:
			doc.AppendCode(block.Quote, block.Language, spreadHoverTabs(block.Text))
		case core.DocBlockRule:
			doc.AppendRule(block.Quote)
		case core.DocBlockTable:
			rows := make([][]markdown.TableCell, len(block.Rows))
			for r, row := range block.Rows {
				cells := make([]markdown.TableCell, len(row))
				for c, cell := range row {
					cells[c] = markdown.TableCell{
						Align: docIRAlign(cell.Align),
						Spans: docIRSpans(cell.Spans),
					}
				}
				rows[r] = cells
			}
			doc.AppendTable(block.Quote, block.Columns, rows)
		case core.DocBlockLabeled:
			doc.AppendLabeled(block.Quote, docIRLabelSpans(block, localizeTag), docIRSpans(block.Spans))
		}
	}
}

func docIRSpans(spans []core.DocSpan) []markdown.Span {
	if len(spans) == 0 {
		return nil
	}
	out := make([]markdown.Span, len(spans))
	for i, s := range spans {
		var style markdown.Style
		if s.Bold {
			style |= markdown.Bold
		}
		if s.Italic {
			style |= markdown.Italic
		}
		if s.Strike {
			style |= markdown.Strike
		}
		if s.Code {
			style |= markdown.Mono
		}
		out[i] = markdown.Span{
			Text:  s.Text,
			Style: style,
			Link:  encodeDocLink(s.Link),
		}
	}
	return out
}

func docIRLabelSpans(block *core.DocBlock, localizeTag func(string) string) []markdown.Span {
	if len(block.LabelSpans) > 0 {
		return docIRSpans(block.LabelSpans)
	}
	var label string
	if block.TagKind != "" && block.TagKind != "custom" {
		if localizeTag != nil {
			label = localizeTag(block.TagKind)
		}
		if label == "" {
			label = block.LabelText
		}
	} else {
		label = block.LabelText
	}
	if label == "" {
		return nil
	}
	return []markdown.Span{{Text: label}}
}

func docIRAlign(align string) markdown.Align {
	switch align {
	case "center":
		return markdown.AlignCenter
	case "right":
		return markdown.AlignRight
	default:
		return markdown.AlignLeft
	}
}

// encodeDocLink encodes a typed Core link target deterministically for Viva's
// markdown.Span.Link: web and mailto URLs stay bare so followHoverLink opens
// them directly, while non-web external targets, anchors, and symbol refs carry
// explicit prefixes.
func encodeDocLink(link *core.DocLink) string {
	if link == nil || link.Target == "" {
		return ""
	}
	switch link.Kind {
	case core.DocLinkExternal:
		lower := strings.ToLower(link.Target)
		if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") || strings.HasPrefix(lower, "mailto:") {
			return link.Target
		}
		return "external:" + link.Target
	case core.DocLinkAnchor:
		return "anchor:" + strings.TrimPrefix(link.Target, "#")
	case core.DocLinkSymbolRef:
		return "symbol:" + link.Target
	default:
		return ""
	}
}
