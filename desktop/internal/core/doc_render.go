package core

import (
	"context"
	"encoding/json"
	"fmt"
)

// Doc block kinds returned by Core's editor.renderDocComment and editor.renderHoverDoc.
const (
	DocBlockParagraph = "paragraph"
	DocBlockHeading   = "heading"
	DocBlockItem      = "item"
	DocBlockCode      = "code"
	DocBlockRule      = "rule"
	DocBlockTable     = "table"
	DocBlockLabeled   = "labeled"
)

// Doc link kinds carried by DocSpan.Link.
const (
	DocLinkExternal  = "external"
	DocLinkAnchor    = "anchor"
	DocLinkSymbolRef = "symbolRef"
	DocLinkNone      = "none"
)

// DocRenderResponse is the structured native document IR returned by
// editor.renderDocComment and editor.renderHoverDoc.
type DocRenderResponse struct {
	FallbackToSource bool        `json:"fallbackToSource"`
	FallbackReason   string      `json:"fallbackReason,omitempty"`
	Blocks           []DocBlock  `json:"blocks"`
	Anchors          []DocAnchor `json:"anchors,omitempty"`
}

// DocAnchor attaches a normalized anchor identifier to a top-level IR block.
type DocAnchor struct {
	ID         string `json:"id"`
	BlockIndex int    `json:"blockIndex"`
}

// DocBlock is one top-level block of structured documentation content.
// Kind is one of "paragraph", "heading", "item", "code", "rule", "table", or "labeled".
type DocBlock struct {
	Kind       string           `json:"kind"`
	Quote      int              `json:"quote,omitempty"`
	Level      int              `json:"level,omitempty"`
	Number     int              `json:"number,omitempty"`
	Language   string           `json:"language,omitempty"`
	Text       string           `json:"text,omitempty"`
	Columns    int              `json:"columns,omitempty"`
	Rows       [][]DocTableCell `json:"rows,omitempty"`
	TagKind    string           `json:"tagKind,omitempty"`
	LabelText  string           `json:"labelText,omitempty"`
	LabelSpans []DocSpan        `json:"labelSpans,omitempty"`
	Spans      []DocSpan        `json:"spans,omitempty"`
}

// UnmarshalJSON decodes both Core's current Rust serde enum-variant field names
// (tag_kind, label_text, label_spans) and camelCase (tagKind, labelText, labelSpans).
func (b *DocBlock) UnmarshalJSON(data []byte) error {
	type docBlockWire struct {
		Kind            string           `json:"kind"`
		Quote           int              `json:"quote,omitempty"`
		Level           int              `json:"level,omitempty"`
		Number          int              `json:"number,omitempty"`
		Language        string           `json:"language,omitempty"`
		Text            string           `json:"text,omitempty"`
		Columns         int              `json:"columns,omitempty"`
		Rows            [][]DocTableCell `json:"rows,omitempty"`
		TagKind         string           `json:"tagKind,omitempty"`
		TagKindSnake    string           `json:"tag_kind,omitempty"`
		LabelText       string           `json:"labelText,omitempty"`
		LabelTextSnake  string           `json:"label_text,omitempty"`
		LabelSpans      []DocSpan        `json:"labelSpans,omitempty"`
		LabelSpansSnake []DocSpan        `json:"label_spans,omitempty"`
		Spans           []DocSpan        `json:"spans,omitempty"`
	}
	var wire docBlockWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	*b = DocBlock{
		Kind:       wire.Kind,
		Quote:      wire.Quote,
		Level:      wire.Level,
		Number:     wire.Number,
		Language:   wire.Language,
		Text:       wire.Text,
		Columns:    wire.Columns,
		Rows:       wire.Rows,
		TagKind:    wire.TagKind,
		LabelText:  wire.LabelText,
		LabelSpans: wire.LabelSpans,
		Spans:      wire.Spans,
	}
	if b.TagKind == "" {
		b.TagKind = wire.TagKindSnake
	}
	if b.LabelText == "" {
		b.LabelText = wire.LabelTextSnake
	}
	if len(b.LabelSpans) == 0 {
		b.LabelSpans = wire.LabelSpansSnake
	}
	return nil
}

// DocTableCell is one cell of a "table" DocBlock.
type DocTableCell struct {
	Align string    `json:"align,omitempty"`
	Spans []DocSpan `json:"spans"`
}

// DocSpan is one inline styled run inside a block or table cell.
type DocSpan struct {
	Text   string   `json:"text"`
	Bold   bool     `json:"bold,omitempty"`
	Italic bool     `json:"italic,omitempty"`
	Strike bool     `json:"strike,omitempty"`
	Code   bool     `json:"code,omitempty"`
	Link   *DocLink `json:"link,omitempty"`
}

// DocLink is a typed link target carried by a DocSpan.
type DocLink struct {
	Kind   string `json:"kind"`
	Target string `json:"target"`
}

type renderDocCommentRequest struct {
	ShellKind string `json:"shellKind,omitempty"`
	Dialect   string `json:"dialect"`
	Language  string `json:"language,omitempty"`
}

type renderHoverDocRequest struct {
	IsMarkdown bool   `json:"isMarkdown"`
	Language   string `json:"language,omitempty"`
}

// ExecuteDocument runs one kernel command that borrows immutable source bytes
// across the C ABI without copying them into the JSON request payload.
func (c *Client) ExecuteDocument(ctx context.Context, command string, source []byte, payload, result any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if payload == nil {
		payload = struct{}{}
	}
	id := fmt.Sprintf("desktop-%d", nextCoreOperation.Add(1))
	request, err := json.Marshal(requestEnvelope{
		OperationID: id,
		Command:     command,
		Payload:     payload,
		Origin:      requestOriginOf(ctx),
	})
	if err != nil {
		return &Error{
			Command: command,
			Code:    CodeInvalidRequest,
			Message: "request could not be encoded",
			Details: err.Error(),
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	stop := watchCancellation(ctx, id)
	defer stop()
	return decodeResponse(ctx, command, executeDocumentJSON(request, source), result)
}

// RenderDocComment parses one confirmed documentation comment slice into
// structured native IR through the borrowed-document C ABI.
func (c *Client) RenderDocComment(ctx context.Context, source []byte, shellKind, dialect, language string) (DocRenderResponse, error) {
	var result DocRenderResponse
	err := c.ExecuteDocument(ctx, "editor.renderDocComment", source, renderDocCommentRequest{
		ShellKind: shellKind,
		Dialect:   dialect,
		Language:  language,
	}, &result)
	return result, err
}

// RenderHoverDoc parses one hover payload into structured native IR through
// the borrowed-document C ABI.
func (c *Client) RenderHoverDoc(ctx context.Context, contents []byte, isMarkdown bool, language string) (DocRenderResponse, error) {
	var result DocRenderResponse
	err := c.ExecuteDocument(ctx, "editor.renderHoverDoc", contents, renderHoverDocRequest{
		IsMarkdown: isMarkdown,
		Language:   language,
	}, &result)
	return result, err
}
