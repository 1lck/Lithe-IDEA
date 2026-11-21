package workbench

import (
	"bytes"
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/encodingname"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// Text encodings of files.
//
// Core owns every encoding rule: which encodings exist, how a file's encoding is detected,
// how bytes decode and text encodes, what an unmappable character does. This file decides
// where the bytes come from and go to. The editor's text is always UTF-8; a document whose
// file is not plain UTF-8 also keeps the bytes it last read or wrote (diskBytes), because the
// guarded writer and the external-change check compare bytes, not text. Plain UTF-8 files
// take the unchanged fast path with no copy and no Core call.

// utf8BOM leads a UTF-8 file with a byte order mark.
var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// encodingID is the document's encoding as Core names it.
func (d *document) encodingID() string {
	if d.encoding == "" {
		return "utf-8"
	}
	return d.encoding
}

// needsCodec says the file's bytes differ from the editor's text, so saving and checking must
// go through Core.
func (d *document) needsCodec() bool {
	return d.encoding != "" && !(d.encoding == "utf-8" && !d.hasBOM)
}

// documentRead is a file read for the editor: the UTF-8 text and the encoding it came from.
type documentRead struct {
	text []byte
	// encoding is "" for plain UTF-8; disk holds the file's bytes otherwise.
	encoding string
	hasBOM   bool
	disk     []byte
}

// readDocumentEncoded reads the file at path through read as the editor opens it, up to the
// editor's default limit.
func readDocumentEncoded(ctx context.Context, kernel editorKernel, read documentBytes, path string) (documentRead, error) {
	return readDocumentEncodedLimit(ctx, kernel, read, path, 16<<20)
}

// readDocumentEncodedLimit reads up to limit bytes of the file at path through read as the
// editor opens it. Plain UTF-8 reads as it is; a file with a UTF-8 byte order mark, UTF-16 or a
// legacy encoding is detected and decoded by Core. A file Core cannot decode is refused for the
// reason classifiedDocument gave.
func readDocumentEncodedLimit(ctx context.Context, kernel editorKernel, read documentBytes, path string, limit int64) (documentRead, error) {
	raw, err := read(ctx, path, limit)
	if err != nil {
		return documentRead{}, err
	}
	data, err := classifiedDocument(raw, nil)
	if err == nil && !bytes.HasPrefix(data, utf8BOM) {
		return documentRead{text: data}, nil
	}
	if err != nil && !errors.Is(err, errNotText) && !errors.Is(err, errUnsupportedEncoding) {
		return documentRead{}, err
	}
	if kernel == nil {
		return documentRead{}, err
	}
	decoded, decodeErr := kernel.DecodeFileBytes(ctx, raw, "")
	if decodeErr != nil {
		if err != nil {
			return documentRead{}, err
		}
		return documentRead{}, decodeErr
	}
	return documentRead{text: []byte(decoded.Text), encoding: decoded.Encoding, hasBOM: decoded.HasBOM, disk: raw}, nil
}

// errLossyDecode is the failure logged when a file reopened in an encoding that cannot decode
// all of it: the window shows replacement characters for the bytes it lost.
var errLossyDecode = errors.New("the file has bytes the chosen encoding cannot decode")

// readDocumentAs reads the file at path through read decoded as encoding, which is the reopen
// path: a wrong choice shows replacement characters and Lossy says so.
func readDocumentAs(ctx context.Context, kernel editorKernel, read documentBytes, path, encoding string) (documentRead, bool, error) {
	raw, err := read(ctx, path, 16<<20)
	if err != nil {
		return documentRead{}, false, err
	}
	decoded, err := kernel.DecodeFileBytes(ctx, raw, encoding)
	if err != nil {
		return documentRead{}, false, err
	}
	opened := documentRead{text: []byte(decoded.Text), encoding: decoded.Encoding, hasBOM: decoded.HasBOM, disk: raw}
	if decoded.Encoding == "utf-8" && !decoded.HasBOM {
		opened.encoding, opened.disk = "", nil
	}
	return opened, decoded.Lossy, nil
}

// expectedDiskBytes is what the file must still hold for a guarded save.
func (d *document) expectedDiskBytes() []byte {
	if d.diskBytes != nil {
		return d.diskBytes
	}
	return d.view.SavedBytes()
}

// encodingState is the encoding menu's state.
type encodingState struct {
	open bool
}

// encodingMenu declares the menu the status bar's encoding item opens: reopen the file with an
// encoding, or save it in one.
func (a *App) encodingMenu(c ui.C, anchor ui.Box) {
	p := a.project
	if p == nil || !a.editor.encoding.open {
		return
	}
	d := p.selectedDocument(p.docs.group)
	if d == nil || d.virtual {
		a.editor.encoding.open = false
		return
	}
	language := a.language()
	ui.Menu(c, anchor, &a.editor.encoding.open, func(menu *ui.MenuItems) {
		menu.Above()
		menu.WidthRange(220, 220)
		menu.Sub(i18n.Shared(language, "desktop.encoding.reopen"), func(sub *ui.MenuItems) {
			sub.WidthRange(180, 180)
			for _, id := range core.FileEncodings {
				if sub.Item(encodingname.DisplayName(id)).Clicked() {
					c.After(func() { a.reopenWithEncoding(p, d, id) })
				}
			}
		})
		menu.Sub(i18n.Shared(language, "desktop.encoding.saveAs"), func(sub *ui.MenuItems) {
			sub.WidthRange(180, 180)
			for _, id := range core.FileEncodings {
				if sub.Item(encodingname.DisplayName(id)).Clicked() {
					c.After(func() { a.saveWithEncoding(p, d, id) })
				}
			}
		})
	})
}

// reopenWithEncoding reads the file again decoded as encoding. A document with unsaved edits
// is refused, because the new text would replace them; saving or discarding comes first.
func (a *App) reopenWithEncoding(p *project, d *document, encoding string) {
	kernel, ok := a.kernel.(editorKernel)
	if !ok || a.project != p || p.docs.find(d.id) != d || d.virtual {
		return
	}
	if d.dirty() || d.saving || d.view.IsComposing() {
		a.notify(i18n.Shared(a.language(), "desktop.encoding.reopenDirty"))
		return
	}
	a.performed("editor.encoding.reopen", surfaceMenu)
	revision := d.view.Revision()
	// Unchanged until the apply below, which checks the revision: the content is measured
	// against this text on the worker.
	base := d.view.TextSnapshot()
	bytesOf := a.documentBytesOf(p)
	a.background(p, 0, func(ctx context.Context) func(*App) {
		read, lossy, err := readDocumentAs(ctx, kernel, bytesOf, d.path, encoding)
		var content editorview.Content
		if err == nil {
			content = editorview.PrepareAgainst(base, read.text)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("editor_encoding_reopen", err)
				a.notifyError(i18n.Shared(a.language(), "desktop.encoding.reopenFailed"))
				return
			}
			if p.docs.find(d.id) != d || d.view.Revision() != revision || d.dirty() || d.saving {
				return
			}
			if !d.view.ResolveWithDisk(content) {
				return
			}
			d.encoding, d.hasBOM, d.diskBytes, d.encodingChanged = read.encoding, read.hasBOM, read.disk, false
			d.savedRevision = d.view.Revision()
			a.clearDocumentConflict(d)
			if lossy {
				// The file reopened, but not all of it: what the encoding cannot decode is lost.
				a.operationFailed("editor_encoding_reopen", errLossyDecode)
				a.notifyError(i18n.Shared(a.language(), "desktop.encoding.reopenLossy"))
			}
		}
	})
}

// saveWithEncoding makes encoding the file's encoding and saves it in it, even when the text
// is unchanged. Core refuses a character the encoding cannot hold and nothing is written.
func (a *App) saveWithEncoding(p *project, d *document, id string) {
	if a.project != p || p.docs.find(d.id) != d || d.virtual || d.view.ReadOnly() {
		return
	}
	a.performed("editor.encoding.save", surfaceMenu)
	d.previousEncoding = &encodingChoice{encoding: d.encoding, hasBOM: d.hasBOM}
	d.encoding, d.hasBOM = id, false
	switch id {
	case "utf-8-bom", "utf-16le-bom", "utf-16be-bom":
		d.hasBOM = true
	}
	if id == "utf-8" {
		d.encoding = ""
	}
	d.encodingChanged = true
	a.saveDocument(p, d.id)
}

// encodeForSave is the bytes to write for the document's text, encoded by Core when the file
// is not plain UTF-8.
func (a *App) encodeForSave(ctx context.Context, d *document, text []byte) ([]byte, error) {
	if !d.needsCodec() {
		return text, nil
	}
	kernel, ok := a.kernel.(editorKernel)
	if !ok {
		return nil, errors.New("encoding is not available")
	}
	bom := d.hasBOM
	encoded, err := kernel.EncodeFileText(ctx, string(text), d.encodingID(), &bom)
	return encoded.Bytes, err
}

// encodingChoice is an encoding and byte order mark a document had before the user chose
// another to save in; a save that fails brings it back.
type encodingChoice struct {
	encoding string
	hasBOM   bool
}

// saveEncodingName is the name of the encoding of document id, for a failed save's message.
func (a *App) saveEncodingName(id int) string {
	if p := a.project; p != nil {
		if d := p.docs.find(id); d != nil {
			return encodingname.DisplayName(d.encodingID())
		}
	}
	return ""
}

// revertEncodingChoice undoes the encoding the user chose to save in, after the save failed.
func (d *document) revertEncodingChoice() {
	if d.previousEncoding != nil {
		d.encoding, d.hasBOM = d.previousEncoding.encoding, d.previousEncoding.hasBOM
	}
	d.previousEncoding, d.encodingChanged = nil, false
}

// rawDocumentLimit bounds the bytes of a file read without judging them as text, for a document
// whose file is compared and decoded through Core (documentRawOf).
const rawDocumentLimit = 64 << 20

// decodeExternal is the editor text of bytes read from the file of a document: the bytes
// themselves for plain UTF-8, or Core's decoding in the encoding the document was opened with.
func decodeExternal(ctx context.Context, kernel editorKernel, data []byte, encoding string, hasBOM, coded bool) ([]byte, error) {
	if !coded {
		return data, nil
	}
	if kernel == nil {
		return nil, errors.New("encoding is not available")
	}
	id := encoding
	if id == "" {
		id = "utf-8"
	}
	decoded, err := kernel.DecodeFileBytes(ctx, data, id)
	if err != nil {
		return nil, err
	}
	_ = hasBOM
	return []byte(decoded.Text), nil
}
