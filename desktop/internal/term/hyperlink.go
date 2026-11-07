package term

import (
	"bytes"
	"unicode"
	"unicode/utf8"
)

// setHyperlink applies OSC 8's params;URI payload to subsequently printed
// cells. Parameters are deliberately not interpreted: they describe link
// identity to the producer, while the retained terminal only needs the URI.
func (t *Terminal) setHyperlink(payload []byte) {
	separator := bytes.IndexByte(payload, ';')
	if separator < 0 {
		return
	}
	target := payload[separator+1:]
	if len(target) == 0 {
		t.pen.hyperlink = 0
		return
	}
	t.pen.hyperlink = t.internHyperlink(target)
}

type hyperlinkRecord struct {
	target string
	token  uint32
}

func (l *line) hyperlinkAt(column int) uint32 {
	if l.hyperlinks == nil || column < 0 || column >= len(*l.hyperlinks) {
		return 0
	}
	return (*l.hyperlinks)[column]
}

func (l *line) setHyperlink(column int, token uint32) {
	l.setHyperlinkRange(column, column+1, token)
}

func (l *line) setHyperlinkRange(from, to int, token uint32) {
	if token == 0 && l.hyperlinks == nil {
		return
	}
	if l.hyperlinks == nil || len(*l.hyperlinks) != len(l.cells) {
		links := make([]uint32, len(l.cells))
		if l.hyperlinks != nil {
			copy(links, *l.hyperlinks)
		}
		l.hyperlinks = &links
	}
	for index := from; index < to; index++ {
		(*l.hyperlinks)[index] = token
	}
}

func (l *line) fitHyperlinks(columns int) {
	if l.hyperlinks == nil {
		return
	}
	links := *l.hyperlinks
	if cap(links) >= columns {
		old := len(links)
		links = links[:columns]
		if old < columns {
			clear(links[old:])
		}
		*l.hyperlinks = links
		return
	}
	grown := make([]uint32, columns)
	copy(grown, links)
	*l.hyperlinks = grown
}

func (t *Terminal) internHyperlink(target []byte) uint32 {
	if len(target) == 0 || len(target) > maxHyperlinkTarget || !utf8.Valid(target) {
		return 0
	}
	for _, value := range string(target) {
		if unicode.IsControl(value) {
			return 0
		}
	}
	text := string(target)
	if token := t.hyperlinkByTarget[text]; token != 0 && t.hyperlinkTarget(token) == text {
		return token
	}
	if t.hyperlinkByTarget == nil {
		t.hyperlinkByTarget = make(map[string]uint32, min(maxHyperlinks, 64))
	}
	if t.nextHyperlink == ^uint32(0) {
		clear(t.hyperlinkByTarget)
		clear(t.hyperlinks)
		t.nextHyperlink = 0
	}
	t.nextHyperlink++
	token := t.nextHyperlink
	record := hyperlinkRecord{target: text, token: token}
	if len(t.hyperlinks) < maxHyperlinks {
		t.hyperlinks = append(t.hyperlinks, record)
	} else {
		index := int((token - 1) % maxHyperlinks)
		old := t.hyperlinks[index]
		if t.hyperlinkByTarget[old.target] == old.token {
			delete(t.hyperlinkByTarget, old.target)
		}
		t.hyperlinks[index] = record
	}
	t.hyperlinkByTarget[text] = token
	return token
}

func (t *Terminal) hyperlinkTarget(token uint32) string {
	if token == 0 || len(t.hyperlinks) == 0 {
		return ""
	}
	record := t.hyperlinks[(token-1)%uint32(maxHyperlinks)]
	if record.token != token {
		return ""
	}
	return record.target
}
