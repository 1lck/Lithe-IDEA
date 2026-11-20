package core

import (
	"context"
	"encoding/base64"
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
	// Open is the line still being written, shown after Lines. Core holds its
	// bytes until it ends, so a later answer may show it differently.
	Open OutputLine
	// State is passed back unchanged with the console's next chunk.
	State json.RawMessage
}

// OutputEncodingPolicy is how Core decides the characters of a process's
// output bytes, line by line.
type OutputEncodingPolicy struct {
	// Setting is the user's console encoding: empty or "auto" tries the
	// candidates in order, any other id decodes every line with that encoding.
	Setting string `json:"setting,omitempty"`
	// Declared is the encoding whoever started the process says it writes, such
	// as a plugin's run plan; empty when nobody said.
	Declared string `json:"declared,omitempty"`
	// Windows enables the Windows default: try GBK only after UTF-8 fails.
	Windows bool `json:"windows,omitempty"`
}

// OutputEncodings is what an output encoding policy means on this machine.
type OutputEncodings struct {
	// Candidates are the encoding ids a line is tried in, in order.
	Candidates []string `json:"candidates"`
	// Encodings are every id a setting may choose, in menu order.
	Encodings []string `json:"encodings"`
}

// DecodeOutputStyle turns one chunk of a process's output bytes with ANSI
// escapes into plain lines and styled ranges, decoding each line with the
// encoding policy picks for it. state is the State of the previous answer for
// the same console, or nil for its first chunk; chunks are at most 1 MiB and
// may end inside a character.
func (c *Client) DecodeOutputStyle(ctx context.Context, chunk []byte, policy OutputEncodingPolicy, state json.RawMessage) (OutputStyleDecoding, error) {
	request := struct {
		Bytes    string               `json:"bytes"`
		Encoding OutputEncodingPolicy `json:"encoding"`
		State    json.RawMessage      `json:"state,omitempty"`
	}{Bytes: base64.StdEncoding.EncodeToString(chunk), Encoding: policy, State: state}
	var response struct {
		Lines []OutputLine    `json:"lines"`
		Open  OutputLine      `json:"open"`
		State json.RawMessage `json:"state"`
	}
	if err := c.Execute(ctx, "outputStyle.decode", request, &response); err != nil {
		return OutputStyleDecoding{}, err
	}
	return OutputStyleDecoding{Lines: response.Lines, Open: response.Open, State: response.State}, nil
}

// ResolveOutputEncoding asks Core which encodings policy tries, in order, and
// which encodings a setting may choose, for the console encoding setting.
func (c *Client) ResolveOutputEncoding(ctx context.Context, policy OutputEncodingPolicy) (OutputEncodings, error) {
	var response OutputEncodings
	if err := c.Execute(ctx, "outputEncoding.resolve", policy, &response); err != nil {
		return OutputEncodings{}, err
	}
	return response, nil
}
