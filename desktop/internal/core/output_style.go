package core

import (
	"context"
	"encoding/json"
)

// OutputColor is one colour of a styled output range: a palette entry
// (0-15 follow the theme, 16-255 the xterm cube and grey ramp) or a
// "#rrggbb" colour.
type OutputColor struct {
	Index *int   `json:"index,omitempty"`
	RGB   string `json:"rgb,omitempty"`
}

// OutputStyle is how a range of console output is drawn. Unset colours are the
// console's own.
type OutputStyle struct {
	Foreground    *OutputColor `json:"foreground,omitempty"`
	Background    *OutputColor `json:"background,omitempty"`
	Bold          bool         `json:"bold,omitempty"`
	Dim           bool         `json:"dim,omitempty"`
	Italic        bool         `json:"italic,omitempty"`
	Underline     bool         `json:"underline,omitempty"`
	Inverse       bool         `json:"inverse,omitempty"`
	Hidden        bool         `json:"hidden,omitempty"`
	Strikethrough bool         `json:"strikethrough,omitempty"`
}

// OutputSpan styles Length UTF-16 code units of a line from Start. Spans are
// ascending and never overlap; text outside every span is plain.
type OutputSpan struct {
	Start  int         `json:"start"`
	Length int         `json:"length"`
	Style  OutputStyle `json:"style"`
}

// OutputLine is one line of console output with its escapes removed.
type OutputLine struct {
	Text  string       `json:"text"`
	Spans []OutputSpan `json:"spans,omitempty"`
}

// OutputStyleDecoding is Core's answer for one chunk of console output.
type OutputStyleDecoding struct {
	// Lines are the lines the chunk finished, oldest first; the first one
	// continues the previous answer's Open line.
	Lines []OutputLine
	// Open is the line still being written, shown after Lines.
	Open OutputLine
	// State is passed back unchanged with the console's next chunk.
	State json.RawMessage
}

// DecodeOutputStyle turns one chunk of console output with ANSI escapes into
// plain lines and styled ranges. state is the State of the previous answer for
// the same console, or nil for its first chunk; chunks are at most 1 MiB.
func (c *Client) DecodeOutputStyle(ctx context.Context, text string, state json.RawMessage) (OutputStyleDecoding, error) {
	request := struct {
		Text  string          `json:"text"`
		State json.RawMessage `json:"state,omitempty"`
	}{Text: text, State: state}
	var response struct {
		Lines []OutputLine    `json:"lines"`
		State json.RawMessage `json:"state"`
	}
	if err := c.Execute(ctx, "outputStyle.decode", request, &response); err != nil {
		return OutputStyleDecoding{}, err
	}
	var open struct {
		Line OutputLine `json:"line"`
	}
	if err := json.Unmarshal(response.State, &open); err != nil {
		return OutputStyleDecoding{}, err
	}
	return OutputStyleDecoding{Lines: response.Lines, Open: open.Line, State: response.State}, nil
}
