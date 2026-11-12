package editorview

// Link is one document link the view underlines while the pointer hovers it with the link
// modifier held. Lines are zero-based; columns are zero-based UTF-16 units, as the language
// protocol reports them. The end is exclusive. ID is the caller's index for the link.
type Link struct {
	ID          int
	StartLine   int
	StartColumn int
	EndLine     int
	EndColumn   int
}

// SetLinks replaces the document links the view can hover. A link that is empty or inverted is
// dropped, so an answer from a provider cannot underline nothing.
func (v *View) SetLinks(links []Link) {
	v.hovered = nil
	if len(links) == 0 {
		v.links = nil
		return
	}
	kept := make([]Link, 0, len(links))
	for _, link := range links {
		if linkEmpty(link) {
			continue
		}
		kept = append(kept, link)
	}
	v.links = kept
}

// SetHoveredLink underlines link, or clears the underline when link is nil. It reports whether the
// underline changed, so a caller repaints only then.
func (v *View) SetHoveredLink(link *Link) bool {
	if link == nil {
		changed := v.hovered != nil
		v.hovered = nil
		return changed
	}
	if v.hovered != nil && *v.hovered == *link {
		return false
	}
	copied := *link
	v.hovered = &copied
	return true
}

// LinkAt is the link under the window point (x, y), and false when none is there or the view has
// not painted yet.
func (v *View) LinkAt(x, y float32) (Link, bool) {
	line, column, ok := v.PositionAt(x, y)
	if !ok {
		return Link{}, false
	}
	for _, link := range v.links {
		if linkContains(link, line, column) {
			return link, true
		}
	}
	return Link{}, false
}

// linkEmpty says the link covers no text: its end is not after its start.
func linkEmpty(link Link) bool {
	return link.StartLine < 0 || link.StartColumn < 0 ||
		link.EndLine < link.StartLine || (link.EndLine == link.StartLine && link.EndColumn <= link.StartColumn)
}

// linkContains says the position (line, column) lies in the link's half-open range.
func linkContains(link Link, line, column int) bool {
	if line < link.StartLine || line > link.EndLine {
		return false
	}
	if line == link.StartLine && column < link.StartColumn {
		return false
	}
	return line != link.EndLine || column < link.EndColumn
}
