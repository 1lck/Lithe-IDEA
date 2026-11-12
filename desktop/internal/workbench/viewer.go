package workbench

import (
	"context"
	"errors"
	"fmt"
	"image"
	_ "image/gif"  // GIF images open in a viewer tab.
	_ "image/jpeg" // JPEG images open in a viewer tab.
	_ "image/png"  // PNG images open in a viewer tab.
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// Viewer tabs show a file that is not text in the editor area, as a tab that is selected,
// moved and closed like a file's: its member in a tab group is "view:<id>". An image is
// drawn, fitted to the tab or at its own size; a PDF, audio or video file offers to open
// in the system's application; any other binary file shows its leading bytes in hex,
// read only.

const (
	viewerMemberPrefix = "view:"
	// viewerImageBytes and viewerImagePixels bound the images a tab decodes.
	viewerImageBytes  = 64 << 20
	viewerImagePixels = 64 << 20
	// viewerHexBytes is how much of a binary file the hex view shows.
	viewerHexBytes = 64 << 10
)

// viewerKind is what a viewer tab shows.
type viewerKind int

const (
	viewerHex viewerKind = iota
	viewerImage
	viewerExternal
)

var (
	viewerImageExtensions    = []string{".png", ".jpg", ".jpeg", ".gif"}
	viewerExternalExtensions = []string{".pdf", ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".mp4", ".mov", ".m4v", ".webm", ".avi", ".mkv", ".webp", ".heic", ".tif", ".tiff", ".bmp", ".ico", ".icns", ".psd"}
)

// viewerKindOf is the viewer a path opens in by its extension; false for a file the
// editor opens as text first.
func viewerKindOf(path string) (viewerKind, bool) {
	ext := strings.ToLower(filepath.Ext(path))
	switch {
	case slices.Contains(viewerImageExtensions, ext):
		return viewerImage, true
	case slices.Contains(viewerExternalExtensions, ext):
		return viewerExternal, true
	}
	return 0, false
}

// viewerSet is the project's viewer tabs.
type viewerSet struct {
	list []*viewerTab
	next int
}

func (s *viewerSet) find(id int) *viewerTab {
	for _, t := range s.list {
		if t.id == id {
			return t
		}
	}
	return nil
}

func (s *viewerSet) byPath(path string) *viewerTab {
	for _, t := range s.list {
		if t.path == path {
			return t
		}
	}
	return nil
}

func viewerMember(id int) string { return viewerMemberPrefix + strconv.Itoa(id) }

func memberViewer(member string) (int, bool) {
	rest, ok := strings.CutPrefix(member, viewerMemberPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.Atoi(rest)
	return id, err == nil && id > 0
}

// selectedViewer is the viewer tab group shows, nil when it shows something else.
func (p *project) selectedViewer(group string) *viewerTab {
	g := p.terms.bench.Group(group)
	if g == nil {
		return nil
	}
	if id, ok := memberViewer(g.Selected); ok {
		return p.viewers.find(id)
	}
	return nil
}

// viewerTab is one viewer tab and what was read for it.
type viewerTab struct {
	id         int
	path, name string
	kind       viewerKind
	loading    bool
	failure    string
	size       int64
	// bitmap is the decoded image; actual shows it at its own size instead of fitted.
	bitmap gfx.Bitmap
	actual bool
	// hex are the hex view's lines; truncated says the file is longer than they show.
	hex       []string
	truncated bool
}

// openViewer shows path in a viewer tab of kind, selecting the one that shows it already.
func (a *App) openViewer(p *project, path string, kind viewerKind) {
	if t := p.viewers.byPath(path); t != nil {
		a.selectViewer(p, t.id)
		return
	}
	set := &p.terms
	state := set.bench
	group, added := a.documentGroup(p), ""
	if group == "" {
		added = editorGroupID(set.nextGroup + 1)
		state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: added})
		group = added
	}
	id := p.viewers.next + 1
	if !a.reduceTerminals(p, state, core.OpenEditor(group, viewerMember(id), true)) {
		return
	}
	p.viewers.next = id
	if added != "" {
		set.nextGroup++
		set.layout = newLeaf(added)
	}
	t := &viewerTab{id: id, path: path, name: filepath.Base(path), kind: kind, loading: kind != viewerExternal}
	if info, err := os.Stat(path); err == nil {
		t.size = info.Size()
	}
	p.viewers.list = append(p.viewers.list, t)
	p.docs.group = group
	a.focus = focusTarget{}
	a.performed("editor.viewer.open", surfaceMenu)
	if kind == viewerExternal {
		return
	}
	a.background(p, 0, func(ctx context.Context) func(*App) {
		var bitmap gfx.Bitmap
		var lines []string
		var truncated bool
		var err error
		if kind == viewerImage {
			bitmap, err = decodeViewerImage(path, uint64(id))
		} else {
			lines, truncated, err = readViewerHex(path)
		}
		return func(a *App) {
			if p.viewers.find(id) != t {
				return
			}
			t.loading = false
			if err != nil {
				t.failure = err.Error()
				return
			}
			t.bitmap, t.hex, t.truncated = bitmap, lines, truncated
		}
	})
}

// selectViewer shows viewer tab id in its group.
func (a *App) selectViewer(p *project, id int) {
	member := viewerMember(id)
	g := p.terms.bench.GroupOf(member)
	if g == nil {
		return
	}
	if g.Selected != member && !a.reduceTerminals(p, p.terms.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	p.docs.group = g.ID
}

// closeViewer closes viewer tab id; its group shows the neighbouring tab.
func (a *App) closeViewer(p *project, id int) {
	t := p.viewers.find(id)
	if t == nil {
		return
	}
	member := viewerMember(id)
	if g := p.terms.bench.GroupOf(member); g != nil {
		group := g.ID
		if !a.reduceTerminals(p, p.terms.bench, core.CloseEditor(group, member, emptyPolicy(group), core.SelectAdjacent)) {
			return
		}
		a.focusSelected(p, group)
	}
	p.viewers.list = slices.DeleteFunc(p.viewers.list, func(x *viewerTab) bool { return x == t })
}

// decodeViewerImage reads and decodes an image into premultiplied BGRA.
func decodeViewerImage(path string, id uint64) (gfx.Bitmap, error) {
	file, err := os.Open(path)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	defer file.Close()
	if info, err := file.Stat(); err == nil && info.Size() > viewerImageBytes {
		return gfx.Bitmap{}, errors.New("image is too large to preview")
	}
	config, _, err := image.DecodeConfig(file)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width*config.Height > viewerImagePixels {
		return gfx.Bitmap{}, errors.New("image is too large to preview")
	}
	if _, err := file.Seek(0, 0); err != nil {
		return gfx.Bitmap{}, err
	}
	decoded, _, err := image.Decode(file)
	if err != nil {
		return gfx.Bitmap{}, err
	}
	return bitmapOf(decoded, 0x5669657700000000|id), nil
}

// readViewerHex is the hex view of the leading bytes of a file: offset, sixteen bytes
// and their printable characters per line.
func readViewerHex(path string) ([]string, bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer file.Close()
	buffer := make([]byte, viewerHexBytes+1)
	n, err := file.Read(buffer)
	if err != nil && n == 0 {
		return nil, false, err
	}
	truncated := n > viewerHexBytes
	data := buffer[:min(n, viewerHexBytes)]
	lines := make([]string, 0, (len(data)+15)/16)
	for offset := 0; offset < len(data); offset += 16 {
		row := data[offset:min(offset+16, len(data))]
		var hex, text strings.Builder
		for i := range 16 {
			if i < len(row) {
				fmt.Fprintf(&hex, "%02x ", row[i])
				if row[i] >= 0x20 && row[i] < 0x7f {
					text.WriteByte(row[i])
				} else {
					text.WriteByte('.')
				}
			} else {
				hex.WriteString("   ")
			}
			if i == 7 {
				hex.WriteByte(' ')
			}
		}
		lines = append(lines, fmt.Sprintf("%08x  %s %s", offset, hex.String(), text.String()))
	}
	return lines, truncated, nil
}
