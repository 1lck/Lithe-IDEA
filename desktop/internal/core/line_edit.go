package core

import "context"

// LineEditOperation names a Core-owned line transformation.
type LineEditOperation string

const (
	ToggleLineComment LineEditOperation = "toggleLineComment"
	DuplicateLine     LineEditOperation = "duplicateLine"
	DeleteLine        LineEditOperation = "deleteLine"
	MoveLineUp        LineEditOperation = "moveLineUp"
	MoveLineDown      LineEditOperation = "moveLineDown"
	CopyLineUp        LineEditOperation = "copyLineUp"
	CopyLineDown      LineEditOperation = "copyLineDown"
)

// LineEditRequest uses UTF-16 offsets into Source, as required by Core.
type LineEditRequest struct {
	Operation       LineEditOperation `json:"operation"`
	Source          string            `json:"source"`
	SelectionStart  int               `json:"selectionStart"`
	SelectionLength int               `json:"selectionLength"`
	CommentToken    *string           `json:"commentToken,omitempty"`
}

// LineEditOutcome is Core's replacement and resulting UTF-16 selection. When
// Applied is false the caller must leave the document and shortcut untouched.
type LineEditOutcome struct {
	Applied         bool   `json:"applied"`
	Text            string `json:"text"`
	ReplacedStart   int    `json:"replacedStart"`
	ReplacedLength  int    `json:"replacedLength"`
	SelectionStart  int    `json:"selectionStart"`
	SelectionLength int    `json:"selectionLength"`
}

// LineCommentToken returns Core's language token or nil when none is known.
// The identifier may be a filename, extension or language ID.
func (c *Client) LineCommentToken(ctx context.Context, identifier string) (*string, error) {
	var response struct {
		Token *string `json:"token"`
	}
	err := c.Execute(ctx, "editor.lineCommentToken", struct {
		Identifier string `json:"identifier"`
	}{Identifier: identifier}, &response)
	return response.Token, err
}

// LineEdit asks Core for a pure transformation. It does not write the file or
// change the live editor; the caller must check the captured document version
// and selection before applying the answer as one undoable edit.
func (c *Client) LineEdit(ctx context.Context, request LineEditRequest) (LineEditOutcome, error) {
	var response LineEditOutcome
	err := c.Execute(ctx, "editor.lineEdit", request, &response)
	return response, err
}
