package workbench

import (
	"bytes"
	"context"
	"errors"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
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

// encodingLabels are the names shown for Core's encoding ids; they are the encodings' own
// names, not translations.
var encodingLabels = map[string]string{
	"utf-8": "UTF-8", "utf-8-bom": "UTF-8 BOM", "utf-16le-bom": "UTF-16 LE BOM", "utf-16be-bom": "UTF-16 BE BOM",
	"utf-16le": "UTF-16 LE", "utf-16be": "UTF-16 BE", "gbk": "GBK", "gb18030": "GB18030", "big5": "Big5",
	"shift-jis": "Shift JIS", "euc-jp": "EUC-JP", "euc-kr": "EUC-KR", "windows-1250": "Windows-1250",
	"windows-1251": "Windows-1251", "windows-1252": "Windows-1252", "koi8-r": "KOI8-R",
}

func encodingLabel(id string) string {
	if label, ok := encodingLabels[id]; ok {
		return label
	}
	return id
}

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

// readDocumentEncoded reads the file at path as the editor opens it. Plain UTF-8 reads as
// before; a file with a UTF-8 byte order mark, UTF-16 or a legacy encoding is detected and
// decoded by Core. A file Core cannot decode is refused for the reason readDocument gave.
func readDocumentEncoded(ctx context.Context, kernel editorKernel, path string) (documentRead, error) {
	data, err := readDocument(path)
	if err == nil && !bytes.HasPrefix(data, utf8BOM) {
		return documentRead{text: data}, nil
	}
	if err != nil && !errors.Is(err, errNotText) && !errors.Is(err, errUnsupportedEncoding) {
		return documentRead{}, err
	}
	if kernel == nil {
		return documentRead{}, err
	}
	raw := data
	if err != nil {
		var readErr error
		if raw, readErr = documentio.ReadFile(path); readErr != nil {
			return documentRead{}, err
		}
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

// readDocumentAs reads the file at path decoded as encoding, which is the reopen path: a wrong
// choice shows replacement characters and Lossy says so.
func readDocumentAs(ctx context.Context, kernel editorKernel, path, encoding string) (documentRead, bool, error) {
	raw, err := documentio.ReadFile(path)
	if err != nil {
		return documentRead{}, false, err
	}
	decoded, err := kernel.DecodeFileBytes(ctx, raw, encoding)
	if err != nil {
		return documentRead{}, false, err
	}
	read := documentRead{text: []byte(decoded.Text), encoding: decoded.Encoding, hasBOM: decoded.HasBOM, disk: raw}
	if decoded.Encoding == "utf-8" && !decoded.HasBOM {
		read.encoding, read.disk = "", nil
	}
	return read, decoded.Lossy, nil
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
				if sub.Item(encodingLabel(id)).Clicked() {
					c.After(func() { a.reopenWithEncoding(p, d, id) })
				}
			}
		})
		menu.Sub(i18n.Shared(language, "desktop.encoding.saveAs"), func(sub *ui.MenuItems) {
			sub.WidthRange(180, 180)
			for _, id := range core.FileEncodings {
				if sub.Item(encodingLabel(id)).Clicked() {
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
	a.background(p, 0, func(ctx context.Context) func(*App) {
		read, lossy, err := readDocumentAs(ctx, kernel, d.path, encoding)
		var content editorview.Content
		if err == nil {
			content = editorview.Prepare(read.text)
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("editor_encoding_reopen", err))
				a.notify(i18n.Shared(a.language(), "desktop.encoding.reopenFailed"))
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
				a.notify(i18n.Shared(a.language(), "desktop.encoding.reopenLossy"))
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
			return encodingLabel(d.encodingID())
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

// readRawDocument reads a file's bytes without judging them as text, for a document whose
// file is compared and decoded through Core.
func readRawDocument(path string) ([]byte, error) { return documentio.ReadFile(path) }

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
