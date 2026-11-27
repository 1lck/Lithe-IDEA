package editorview

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
)

// CopyDocumentDecorationsFrom initializes a second view of the same immutable text. Foreground
// spans are copied because edits move them in place; the palette, bracket index and scope geometry
// are immutable and can be shared. It does no document scan and is not called from painting.
func (v *View) CopyDocumentDecorationsFrom(source *View) bool {
	if source == nil || !v.text.Same(source.text) {
		return false
	}
	if v == source {
		return true
	}
	v.decor.colors = append(v.decor.colors[:0], source.decor.colors...)
	v.decor.colorPalette, v.decor.colorLine = source.decor.colorPalette, nil
	matches := source.bracketMatches
	if source.bracketRevision != source.revision {
		matches = nil
	}
	v.SetBracketMatches(matches)
	scopes := source.indentGuideScopes
	if source.indentGuideRevision != source.revision {
		scopes = nil
	}
	v.indentGuideScopes, v.indentGuideRevision = scopes, v.revision
	if v.cfg.Notify != nil {
		v.cfg.Notify()
	}
	return true
}

// CloneFor prepares independent foreground spans for a mirrored view's snapshot on the worker.
// Mirrored edits can produce equal ropes with different roots, so identity alone cannot validate
// these coordinates. The receiving view still checks the target snapshot's identity at install.
func (p PreparedColorDecorations) CloneFor(text rope.Rope) PreparedColorDecorations {
	if !p.text.Equal(text) {
		return PreparedColorDecorations{}
	}
	p.text, p.spans = text, slices.Clone(p.spans)
	return p
}

// ForSnapshot rebinds immutable scope geometry to an equal mirrored snapshot on the worker.
func (p PreparedIndentGuideScopes) ForSnapshot(text rope.Rope) PreparedIndentGuideScopes {
	if !p.text.Equal(text) {
		return PreparedIndentGuideScopes{}
	}
	p.text = text
	return p
}
