package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

// FileEncodings are the encoding ids Core accepts, in the order a menu lists them.
var FileEncodings = []string{
	"utf-8", "utf-8-bom", "utf-16le-bom", "utf-16be-bom", "utf-16le", "utf-16be",
	"gbk", "gb18030", "big5", "shift-jis", "euc-jp", "euc-kr",
	"windows-1250", "windows-1251", "windows-1252", "koi8-r",
}

// CodeEncodingUnmappable is the code of the error that says the text has a character the
// chosen encoding cannot represent; its details name the encoding, the scalar offset and the
// code point of the first one. Nothing was written.
const CodeEncodingUnmappable ErrorCode = "encoding_unmappable"

// DecodedFile is bytes decoded as text by Core.
type DecodedFile struct {
	// Text is the decoded text without its byte order mark.
	Text string `json:"text"`
	// Encoding is the stable id of the encoding used, detected when none was asked for.
	Encoding string `json:"encoding"`
	// HasBOM says a byte order mark led the bytes and was removed.
	HasBOM bool `json:"hasBom"`
	// Lossy says an explicitly chosen encoding replaced invalid sequences with U+FFFD.
	Lossy bool `json:"lossy"`
	// Identity is the SHA-256 of the exact bytes decoded.
	Identity string `json:"identity"`
}

// EncodedText is text encoded as bytes by Core.
type EncodedText struct {
	Bytes []byte
	// Encoding and HasBOM are what Core wrote.
	Encoding string
	HasBOM   bool
}

// Core's file commands read and write files under a workspace root, and the encoding rules
// live behind them. The bytes a document was read from and is written to are guarded by the
// host (documentio), so the host hands Core a private temporary directory holding only the
// bytes to decode, or taking the bytes just encoded, and removes it again. No encoding rule
// is repeated here.

// DecodeFileBytes decodes data with encoding, or detects the encoding when it is empty.
// Detection fails with parse_failed for bytes that are valid in none of the supported
// encodings; an explicit encoding never fails for that reason and reports Lossy instead.
func (c *Client) DecodeFileBytes(ctx context.Context, data []byte, encoding string) (DecodedFile, error) {
	root, err := os.MkdirTemp("", "lithe-decode-*")
	if err != nil {
		return DecodedFile{}, err
	}
	defer os.RemoveAll(root)
	if err := os.WriteFile(filepath.Join(root, "document"), data, 0o600); err != nil {
		return DecodedFile{}, err
	}
	payload := struct {
		Root     string `json:"root"`
		Path     string `json:"path"`
		Encoding string `json:"encoding,omitempty"`
	}{root, "document", encoding}
	var decoded DecodedFile
	err = c.Execute(ctx, "file.read", payload, &decoded)
	return decoded, err
}

// EncodeFileText encodes text with encoding. bom, when not nil, overrides whether the Unicode
// encodings write a byte order mark. A character the encoding cannot represent fails with
// CodeEncodingUnmappable.
func (c *Client) EncodeFileText(ctx context.Context, text, encoding string, bom *bool) (EncodedText, error) {
	root, err := os.MkdirTemp("", "lithe-encode-*")
	if err != nil {
		return EncodedText{}, err
	}
	defer os.RemoveAll(root)
	payload := struct {
		Root     string `json:"root"`
		Path     string `json:"path"`
		Text     string `json:"text"`
		Encoding string `json:"encoding,omitempty"`
		BOM      *bool  `json:"bom,omitempty"`
	}{root, "document", text, encoding, bom}
	var written struct {
		Encoding string `json:"encoding"`
		HasBOM   bool   `json:"hasBom"`
	}
	if err := c.Execute(ctx, "file.write", payload, &written); err != nil {
		return EncodedText{}, err
	}
	data, err := os.ReadFile(filepath.Join(root, "document"))
	if err != nil {
		return EncodedText{}, err
	}
	return EncodedText{Bytes: data, Encoding: written.Encoding, HasBOM: written.HasBOM}, nil
}

// IsEncodingUnmappable reports whether err says the text cannot be written in the chosen
// encoding, and returns the kernel's details (encoding, scalar offset and code point).
func IsEncodingUnmappable(err error) (details string, ok bool) {
	var failure *Error
	if errors.As(err, &failure) && failure.Code == CodeEncodingUnmappable {
		return failure.Details, true
	}
	return "", false
}
