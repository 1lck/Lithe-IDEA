package term

import (
	"strings"
	"unicode"
)

// Link is one explicit OSC 8 or detected HTTP/HTTPS target in the retained
// terminal buffer. End is exclusive. A link may cross rows only where the
// terminal soft-wrapped them.
type Link struct {
	Start  BufferPosition
	End    BufferPosition
	Target string
}

// Links returns explicit OSC 8 links and finds HTTP/HTTPS targets in unlinked
// retained text, reusing dst. At most limit links are retained; truncated
// reports that more existed. Detection is performed only when Links is called.
func (t *Terminal) Links(dst []Link, limit int) ([]Link, bool) {
	if limit <= 0 {
		return dst[:0], false
	}
	scanner := linkScanner{dst: dst[:0], limit: limit}
	stopped := t.scanLinks(&scanner, 0, t.bufferLineCount())
	return scanner.dst, stopped
}

// linkGroupStart is the first line of the soft-wrapped group that holds line.
func (t *Terminal) linkGroupStart(line int) int {
	for line > 0 && t.bufferLine(line-1).wrapped {
		line--
	}
	return line
}

// linkGroupEnd is one past the last line of the group that holds line.
func (t *Terminal) linkGroupEnd(line int) int {
	total := t.bufferLineCount()
	for line < total && t.bufferLine(line).wrapped {
		line++
	}
	return min(line+1, total)
}

// LinksAt returns the link covering position, if one exists. It scans only the
// soft-wrapped line group that holds the position, so moving the pointer over a
// terminal with thousands of lines of history does not rescan them.
func (t *Terminal) LinksAt(position BufferPosition) (Link, bool) {
	if position.Line < 0 || position.Line >= t.bufferLineCount() {
		return Link{}, false
	}
	scanner := linkScanner{want: position, hasWant: true, limit: linksAtLimit}
	t.scanLinks(&scanner, t.linkGroupStart(position.Line), t.linkGroupEnd(position.Line))
	if scanner.found {
		return scanner.target, true
	}
	return Link{}, false
}

// linksAtLimit bounds what one wrapped group may collect before the pointer's
// link when LinksAt scans it. A group of ordinary width holds far fewer.
const linksAtLimit = 16 << 10

// scanLinks runs the scanner over buffer lines [first, last). It reports
// whether the scan stopped early: the limit was reached, or a link covered the
// position the scanner wants.
func (t *Terminal) scanLinks(scanner *linkScanner, first, last int) bool {
	if scanner == nil || last <= first || scanner.limit <= 0 && !scanner.hasWant {
		return false
	}
	var explicitID uint32
	var explicitStart, explicitEnd BufferPosition
	finishExplicit := func() bool {
		if explicitID == 0 {
			return false
		}
		target := t.hyperlinkTarget(explicitID)
		explicitID = 0
		if target == "" {
			return false
		}
		link := Link{Start: explicitStart, End: explicitEnd, Target: target}
		if scanner.accept(link) {
			return true
		}
		return len(scanner.dst) >= scanner.limit
	}
	for lineIndex := first; lineIndex < last; lineIndex++ {
		line := t.bufferLine(lineIndex)
		used := retainedLineUsedCells(line)
		mark := 0
		for column := 0; column < used; column++ {
			cell := line.cells[column]
			if cell.Attr&WideTail != 0 {
				continue
			}
			width := 1
			if cell.Attr&WideHead != 0 {
				width = 2
			}
			value := cell.R
			if value == 0 || value < 0x20 || value >= 0x7f && value < 0xa0 || cell.Attr&Hidden != 0 {
				value = ' '
			}
			start := BufferPosition{Line: lineIndex, Column: column}
			end := BufferPosition{Line: lineIndex, Column: min(column+width, t.cols)}
			hyperlink := line.hyperlinkAt(column)
			if hyperlink != explicitID {
				if finishExplicit() {
					return true
				}
				if hyperlink != 0 {
					if scanner.breakLine() {
						return true
					}
					explicitID = hyperlink
					explicitStart = start
				}
			}
			if explicitID != 0 {
				explicitEnd = end
				continue
			}
			if scanner.write(value, start, end) {
				return true
			}
			for mark < len(line.marks) && int(line.marks[mark].Col) < column {
				mark++
			}
			for mark < len(line.marks) && int(line.marks[mark].Col) == column {
				if scanner.write(line.marks[mark].R, start, end) {
					return true
				}
				mark++
			}
		}
		if !line.wrapped {
			if finishExplicit() || scanner.breakLine() {
				return true
			}
		}
	}
	if finishExplicit() {
		return true
	}
	return scanner.finish()
}

type linkScanner struct {
	dst   []Link
	limit int
	// want, when set, is the position LinksAt is looking for: the scan stops
	// as soon as a link covers it.
	want    BufferPosition
	hasWant bool
	found   bool
	target  Link

	previous rune
	start    BufferPosition
	scheme   [8]rune
	matched  int
	secure   bool
	active   bool

	text        strings.Builder
	safeBytes   int
	safeEnd     BufferPosition
	parentheses int
	brackets    int
	braces      int
}

func (s *linkScanner) write(value rune, start, end BufferPosition) bool {
	if s.active {
		if linkTerminator(value) {
			if s.finish() {
				return true
			}
			s.previous = value
			return false
		}
		switch value {
		case ')':
			if s.parentheses == 0 {
				if s.finish() {
					return true
				}
				s.previous = value
				return false
			}
			s.parentheses--
		case ']':
			if s.brackets == 0 {
				if s.finish() {
					return true
				}
				s.previous = value
				return false
			}
			s.brackets--
		case '}':
			if s.braces == 0 {
				if s.finish() {
					return true
				}
				s.previous = value
				return false
			}
			s.braces--
		case '(':
			s.parentheses++
		case '[':
			s.brackets++
		case '{':
			s.braces++
		}

		s.text.WriteRune(value)
		if !linkTrailingPunctuation(value) {
			s.safeBytes = s.text.Len()
			s.safeEnd = end
		}
		s.previous = value
		return false
	}

	if s.matched == 0 {
		if (value == 'h' || value == 'H') && linkSchemeBoundary(s.previous) {
			s.start = start
			s.scheme[0] = value
			s.matched = 1
		}
		s.previous = value
		return false
	}

	if s.matchScheme(value) {
		s.scheme[s.matched] = value
		s.matched++
		if s.schemeComplete() {
			s.active = true
			s.text.Grow(64)
			for index := 0; index < s.matched; index++ {
				s.text.WriteRune(s.scheme[index])
			}
			s.safeBytes = s.text.Len()
			s.safeEnd = end
		}
		s.previous = value
		return false
	}

	s.matched = 0
	s.secure = false
	if (value == 'h' || value == 'H') && linkSchemeBoundary(s.previous) {
		s.start = start
		s.scheme[0] = value
		s.matched = 1
	}
	s.previous = value
	return false
}

func (s *linkScanner) matchScheme(value rune) bool {
	switch s.matched {
	case 1, 2:
		return value == 't' || value == 'T'
	case 3:
		return value == 'p' || value == 'P'
	case 4:
		if value == 's' || value == 'S' {
			s.secure = true
			return true
		}
		return value == ':'
	case 5:
		if s.secure {
			return value == ':'
		}
		return value == '/'
	case 6:
		return value == '/'
	case 7:
		return s.secure && value == '/'
	default:
		return false
	}
}

func (s *linkScanner) schemeComplete() bool {
	return !s.secure && s.matched == 7 || s.secure && s.matched == 8
}

func (s *linkScanner) breakLine() bool {
	truncated := s.finish()
	s.previous = 0
	s.matched = 0
	s.secure = false
	return truncated
}

func (s *linkScanner) finish() bool {
	if !s.active {
		s.matched = 0
		s.secure = false
		return false
	}
	text := s.text.String()[:s.safeBytes]
	stopped := false
	if validLinkTarget(text, s.schemeLength()) {
		link := Link{Start: s.start, End: s.safeEnd, Target: text}
		if s.accept(link) {
			stopped = true
		} else if len(s.dst) >= s.limit {
			stopped = true
		}
	}
	s.resetCandidate()
	return stopped
}

// linkPositionLess orders two positions in the retained buffer.
func linkPositionLess(left, right BufferPosition) bool {
	return left.Line < right.Line || left.Line == right.Line && left.Column < right.Column
}

// accept records a link, or stops the scan when it covers the wanted position.
func (s *linkScanner) accept(link Link) bool {
	if s.hasWant && !linkPositionLess(s.want, link.Start) && linkPositionLess(s.want, link.End) {
		s.found, s.target = true, link
		return true
	}
	if len(s.dst) < s.limit {
		s.dst = append(s.dst, link)
	}
	return false
}

func (s *linkScanner) schemeLength() int {
	if s.secure {
		return len("https://")
	}
	return len("http://")
}

func (s *linkScanner) resetCandidate() {
	s.matched = 0
	s.secure = false
	s.active = false
	s.text = strings.Builder{}
	s.safeBytes = 0
	s.safeEnd = BufferPosition{}
	s.parentheses = 0
	s.brackets = 0
	s.braces = 0
}

func validLinkTarget(target string, schemeLength int) bool {
	authority := target[schemeLength:]
	if end := indexLinkAuthorityEnd(authority); end >= 0 {
		authority = authority[:end]
	}
	if at := strings.LastIndexByte(authority, '@'); at >= 0 {
		authority = authority[at+1:]
	}
	if len(authority) == 0 {
		return false
	}
	if authority[0] == '[' {
		close := strings.IndexByte(authority, ']')
		return close > 1
	}
	if colon := strings.LastIndexByte(authority, ':'); colon >= 0 {
		authority = authority[:colon]
	}
	for _, value := range authority {
		if unicode.IsLetter(value) || unicode.IsNumber(value) {
			return true
		}
	}
	return false
}

func indexLinkAuthorityEnd(authority string) int {
	for index, value := range authority {
		if value == '/' || value == '?' || value == '#' {
			return index
		}
	}
	return -1
}

func linkSchemeBoundary(value rune) bool {
	if value > unicode.MaxASCII {
		return true
	}
	return value == 0 || !isASCIIAlphaNumeric(value) && value != '_' && value != '+' && value != '-' && value != '.'
}

func isASCIIAlphaNumeric(value rune) bool {
	return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z' || value >= '0' && value <= '9'
}

func linkTerminator(value rune) bool {
	if unicode.IsSpace(value) || unicode.IsControl(value) {
		return true
	}
	switch value {
	case '<', '>', '"', '\'', '`', '\\',
		'，', '。', '；', '：', '！', '？', '、',
		'（', '）', '［', '］', '｛', '｝', '【', '】', '《', '》', '〈', '〉', '“', '”', '‘', '’':
		return true
	default:
		return false
	}
}

func linkTrailingPunctuation(value rune) bool {
	switch value {
	case '.', ',', ';', ':', '!', '?', '#', '&':
		return true
	default:
		return false
	}
}
