package syntax

import (
	"math"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

const (
	// maxLineBytes is the longest line that is tokenized, VS Code's
	// editor.maxTokenizationLineLength: a longer line is one token in the default style and
	// leaves the state as it found it.
	maxLineBytes = 20000
	// DefaultLineLimit is how long tokenizing one line may take before it stops, the previous
	// editor's limit. The line keeps the tokens found so far and the next line starts in the
	// state the line started in, as VS Code's TextMate support does.
	DefaultLineLimit = 20 * time.Millisecond
	// replayLimit is how many lines before a line the highlighter tokenizes to learn its start
	// state; further from any known state it guesses one instead.
	replayLimit = 4 * segmentLines
	// guessWalkLimit bounds how far up guessing a start state looks for enclosing lines.
	guessWalkLimit = 2000
)

// Token is a run of a line in one style: it starts at byte Start and runs to the next token's
// start or the end of the line. Name is the token's name for a Theme.
type Token struct {
	Start int32
	Name  Name
}

// HighlighterOptions configure a Highlighter.
type HighlighterOptions struct {
	// OnChange is called when the tokens of lines from first to last may have changed after
	// they were last read, from the background goroutine or from SetSemantic's caller, never
	// with the highlighter's lock held. A view repaints those of them it shows.
	OnChange func(first, last int)
	// LineLimit bounds the time tokenizing one line may take; 0 means DefaultLineLimit and a
	// negative value means no limit.
	LineLimit time.Duration
	// CacheLines is how many lines' tokens are kept; 0 means a default of dozens of screens.
	CacheLines int
}

// Highlighter colors one document. It keeps tokenizer states only at checkpoints, every
// segmentLines lines, and tokens only for lines a view asked for recently; any other line's
// tokens are computed when asked for, from the checkpoint before it, and not kept.
//
// After an edit the edited lines are tokenized at once, so typing never shows them uncolored;
// a background goroutine then brings the checkpoints after the edit up to date, a segment at a
// time and without holding the lock while it tokenizes, and stops as soon as the states match
// what they were before. Lines it finds colored differently are reported through OnChange.
//
// Its methods are safe for concurrent use. A view calls Prepare and then Line for each line it
// paints, and Edit for each change of the text.
type Highlighter struct {
	syntax   *Syntax
	onChange func(first, last int)
	// background says changes start a goroutine; tests drive step themselves instead.
	background bool

	mu      sync.Mutex
	text    rope.Rope
	gen     uint64
	cp      checkpoints
	cache   tokenCache
	ui      lineTokenizer
	running bool
	closed  bool
	// memo is the states of the line the UI side tokenized last, so that the next line, as
	// when scrolling down, starts from its end, and typing on it starts from its start.
	memo     memoState
	semantic semanticTokens
	// guess is scratch for guessing start states.
	guess []int

	worker lineTokenizer
}

// memoState is the state a line starts in and the one it ends in, each nil when not known.
type memoState struct {
	gen        uint64
	line       int
	start, end *textmate.StateStack
	ok         bool
}

// lineTokenizer tokenizes lines into token pairs. Each goroutine needs its own.
type lineTokenizer struct {
	tz     *textmate.Tokenizer
	names  *classifier
	limit  time.Duration
	line   []byte
	tokens []textmate.Token
	out    []uint32
}

// tokenize appends the tokens of line, starting in state, to t.out as start and Name pairs,
// merging neighbors of the same name, and returns the state the line ends in.
func (t *lineTokenizer) tokenize(text rope.Rope, line int, state *textmate.StateStack) *textmate.StateStack {
	t.line = text.AppendLine(t.line[:0], line)
	if len(t.line) > maxLineBytes {
		t.out = append(t.out, 0, 0)
		return state
	}
	tokens, end, stopped := t.tz.TokenizeLine(t.tokens[:0], t.line, state, t.limit)
	t.tokens = tokens
	if stopped {
		end = state
	}
	first := len(t.out)
	for _, token := range tokens {
		name := uint32(t.names.name(token.Scopes))
		if len(t.out) > first && t.out[len(t.out)-1] == name {
			continue
		}
		t.out = append(t.out, uint32(token.Start), name)
	}
	if len(t.out) == first {
		t.out = append(t.out, 0, 0)
	}
	return end
}

// NewHighlighter returns a highlighter of text with syntax, or one that shows text plain when
// syntax is nil. It starts tokenizing text in the background.
func NewHighlighter(syntax *Syntax, text rope.Rope, options HighlighterOptions) *Highlighter {
	return newHighlighter(syntax, text, options, true)
}

func newHighlighter(syntax *Syntax, text rope.Rope, options HighlighterOptions, background bool) *Highlighter {
	limit := options.LineLimit
	switch {
	case limit == 0:
		limit = DefaultLineLimit
	case limit < 0:
		limit = 0
	}
	capacity := options.CacheLines
	if capacity <= 0 {
		capacity = defaultCacheLines
	}
	h := &Highlighter{
		syntax:     syntax,
		onChange:   options.OnChange,
		background: background,
		text:       text,
		cache:      newTokenCache(capacity),
	}
	if syntax != nil {
		h.ui = lineTokenizer{tz: syntax.grammar.NewTokenizer(), names: syntax.names, limit: limit}
		h.worker = lineTokenizer{tz: syntax.grammar.NewTokenizer(), names: syntax.names, limit: limit}
	}
	h.cp.reset()
	h.mu.Lock()
	h.kickLocked()
	h.mu.Unlock()
	return h
}

// Syntax is the highlighter's syntax, nil for plain text.
func (h *Highlighter) Syntax() *Syntax { return h.syntax }

// Close stops the background work. The highlighter still answers, from what it has.
func (h *Highlighter) Close() {
	h.mu.Lock()
	h.closed = true
	h.mu.Unlock()
}

// SetText replaces the whole text, as when a file is reloaded: everything known is dropped.
func (h *Highlighter) SetText(text rope.Rope) {
	h.mu.Lock()
	h.text = text
	h.gen++
	h.memo = memoState{}
	h.cp.reset()
	h.cache.clear()
	h.semantic = nil
	h.kickLocked()
	h.mu.Unlock()
}

// Edit tells the highlighter that text is its text with the bytes from start to oldEnd of
// its previous text replaced by those from start to newEnd.
func (h *Highlighter) Edit(text rope.Rope, start, oldEnd, newEnd int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	old := h.text
	startLine := old.LineOf(start)
	startCol := start - old.LineStart(startLine)
	endLine := old.LineOf(oldEnd)
	endCol := oldEnd - old.LineStart(endLine)
	newEndLine := text.LineOf(newEnd)
	newlines := newEndLine - startLine
	lastLen := newEnd - start
	if newlines > 0 {
		lastLen = newEnd - text.LineStart(newEndLine)
	}
	var firstByte byte
	if newEnd > start {
		firstByte = text.ByteAt(start)
	}
	delta := newlines - (endLine - startLine)

	h.text = text
	h.gen++
	// The lines before the edit start and end as they did, so typing on the line tokenized
	// last starts from where it started.
	switch memo := h.memo; {
	case !memo.ok || memo.gen != h.gen-1 || memo.line > startLine:
		h.memo = memoState{}
	case memo.line == startLine:
		h.memo = memoState{gen: h.gen, line: startLine, start: memo.start, ok: memo.start != nil}
	default:
		h.memo.gen = h.gen
	}
	h.cp.edit(startLine, endLine, delta)
	h.cache.remove(startLine, endLine)
	h.cache.shift(endLine, delta)
	if len(h.semantic) > 0 {
		h.semantic = h.semantic.edit(startLine, startCol, endLine, endCol, newlines, lastLen, firstByte)
	}
	// The edited lines on screen are tokenized now; the rest follows in the background.
	if first, last := max(startLine, h.cache.pinFirst), min(newEndLine, h.cache.pinLast); first <= last {
		h.ensureLocked(first, last)
	}
	h.kickLocked()
}

// Prepare makes sure the tokens of lines first to last are ready and keeps them until the
// next Prepare: a view calls it with the lines it is about to paint, a screen's worth of
// margin included.
func (h *Highlighter) Prepare(first, last int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cache.pin(first, last)
	h.ensureLocked(first, last)
}

// Line appends the tokens of line to dst: its lexical tokens with the semantic ones laid over
// them. It tokenizes the line first when it is not cached.
func (h *Highlighter) Line(dst []Token, line int) []Token {
	h.mu.Lock()
	defer h.mu.Unlock()
	if line < 0 || line >= h.text.LineCount() {
		return dst
	}
	lexical := plainLine[:]
	if h.syntax != nil {
		tokens, ok := h.cache.get(line)
		if !ok {
			h.ensureLocked(line, line)
			tokens, _ = h.cache.get(line)
		}
		lexical = tokens
	}
	return h.overlayLocked(dst, line, lexical)
}

// plainLine is the tokens of a line without syntax: one token with no name.
var plainLine = [2]uint32{0, 0}

// overlayLocked appends lexical, start and Name pairs, to dst with the semantic tokens of line
// laid over them, merging neighbors of the same name.
func (h *Highlighter) overlayLocked(dst []Token, line int, lexical []uint32) []Token {
	si, se := h.semantic.lineRange(line)
	if si == se {
		for k := 0; k < len(lexical); k += 2 {
			dst = append(dst, Token{Start: int32(lexical[k]), Name: Name(lexical[k+1])})
		}
		return dst
	}
	length := h.text.LineEnd(line) - h.text.LineStart(line)
	first := len(dst)
	emit := func(start int, name Name) {
		if n := len(dst); n > first {
			if dst[n-1].Name == name {
				return
			}
			if int(dst[n-1].Start) == start {
				dst[n-1].Name = name
				if n-1 > first && dst[n-2].Name == name {
					dst = dst[:n-1]
				}
				return
			}
		}
		dst = append(dst, Token{Start: int32(start), Name: name})
	}
	for k := 0; k < len(lexical); k += 2 {
		start, name := int(lexical[k]), Name(lexical[k+1])
		end := length
		if k+2 < len(lexical) {
			end = int(lexical[k+2])
		}
		for at := start; at < end; {
			for si < se {
				if _, _, semEnd, _ := h.semantic.token(si); semEnd > at {
					break
				}
				si++
			}
			if si < se {
				_, semStart, semEnd, semName := h.semantic.token(si)
				if semStart <= at {
					emit(at, semName)
					at = min(end, semEnd)
					continue
				}
				emit(at, name)
				at = min(end, semStart)
				continue
			}
			emit(at, name)
			at = end
		}
	}
	if len(dst) == first {
		// An empty line still has its one token.
		dst = append(dst, Token{Start: 0, Name: Name(lexical[1])})
	}
	return dst
}

// ensureLocked tokenizes the lines from first to last that are not cached.
func (h *Highlighter) ensureLocked(first, last int) {
	if h.syntax == nil {
		return
	}
	first, last = max(first, 0), min(last, h.text.LineCount()-1)
	for line := first; line <= last; {
		if h.cache.has(line) {
			line++
			continue
		}
		state := h.startStateLocked(line)
		for ; line <= last; line++ {
			start := state
			h.ui.out = h.ui.out[:0]
			state = h.ui.tokenize(h.text, line, state)
			h.cache.put(line, h.ui.out)
			h.memo = memoState{gen: h.gen, line: line, start: start, end: state, ok: true}
			if line+1 <= last && h.cache.has(line+1) {
				line++
				break
			}
		}
	}
}

// startStateLocked returns the state line starts in: from the line tokenized last when it is
// that line or the one before, else by tokenizing from the checkpoint or the last tokenized
// line before it when one is near, else a guess.
func (h *Highlighter) startStateLocked(line int) *textmate.StateStack {
	if line == 0 {
		return nil
	}
	m := h.memo
	known := m.ok && m.gen == h.gen
	switch {
	case known && m.line == line-1 && m.end != nil:
		return m.end
	case known && m.line == line && m.start != nil:
		return m.start
	}
	c := h.cp.find(line)
	from, state := int(h.cp.lines[c]), h.cp.states[c]
	switch {
	case !known || m.line >= line:
	case m.end != nil && m.line+1 >= from:
		from, state = m.line+1, m.end
	case m.start != nil && m.line >= from:
		from, state = m.line, m.start
	}
	if line-from > replayLimit {
		return h.guessLocked(line)
	}
	for l := from; l < line; l++ {
		h.ui.out = h.ui.out[:0]
		state = h.ui.tokenize(h.text, l, state)
	}
	return state
}

// guessLocked guesses the state line starts in as VS Code does far from any known state: it
// tokenizes, from the initial state, just the lines above it that each are indented less than
// the one below, the lines that most likely open what line is in.
func (h *Highlighter) guessLocked(line int) *textmate.StateStack {
	indent := h.indentLocked(line)
	if indent < 0 {
		indent = math.MaxInt
	}
	h.guess = h.guess[:0]
	for l := line - 1; indent > 0 && l >= 0 && line-l <= guessWalkLimit; l-- {
		if ind := h.indentLocked(l); ind >= 0 && ind < indent {
			h.guess = append(h.guess, l)
			indent = ind
		}
	}
	var state *textmate.StateStack
	for i := len(h.guess) - 1; i >= 0; i-- {
		h.ui.out = h.ui.out[:0]
		state = h.ui.tokenize(h.text, h.guess[i], state)
	}
	return state
}

// indentLocked returns the bytes of white space line starts with, or -1 for a blank line.
func (h *Highlighter) indentLocked(line int) int {
	h.ui.line = h.text.AppendLine(h.ui.line[:0], line)
	for i, b := range h.ui.line {
		if b != ' ' && b != '\t' {
			return i
		}
	}
	return -1
}

func (h *Highlighter) kickLocked() {
	if h.background && !h.running && !h.closed && h.syntax != nil && h.cp.firstDirty < len(h.cp.lines) {
		h.running = true
		go h.run()
	}
}

func (h *Highlighter) run() {
	for h.step() {
	}
}

// step brings the first dirty segment up to date, at most segmentLines lines of it, and says
// whether there may be more to do. Only one goroutine runs it at a time.
func (h *Highlighter) step() bool {
	h.mu.Lock()
	if h.closed || h.syntax == nil || h.cp.firstDirty >= len(h.cp.lines) {
		h.running = false
		h.mu.Unlock()
		return false
	}
	i := h.cp.firstDirty
	text, gen := h.text, h.gen
	count := text.LineCount()
	from, state := int(h.cp.lines[i]), h.cp.states[i]
	to := h.cp.end(i, count)
	limit := min(to, from+segmentLines)
	h.mu.Unlock()

	w := &h.worker
	w.out = w.out[:0]
	var offsets [segmentLines + 1]int
	for line := from; line < limit; line++ {
		offsets[line-from] = len(w.out)
		state = w.tokenize(text, line, state)
	}
	offsets[limit-from] = len(w.out)

	h.mu.Lock()
	if h.gen != gen || h.closed {
		h.mu.Unlock()
		return true
	}
	switch {
	case limit < to:
		// The segment is longer than a segment should be: it is split here.
		h.cp.insert(i, limit, state, true)
		h.cp.clean(i)
	case i+1 < len(h.cp.lines):
		if !state.Equal(h.cp.states[i+1]) {
			h.cp.states[i+1] = state
			h.cp.dirty[i+1] = true
		}
		h.cp.clean(i)
	default:
		h.cp.clean(i)
	}
	if h.memo.line >= from {
		// The memo may have been computed from a state this step just corrected.
		h.memo = memoState{}
	}
	changedFirst, changedLast := -1, -1
	for line := from; line < limit; line++ {
		if !h.cache.has(line) {
			continue
		}
		if h.cache.put(line, w.out[offsets[line-from]:offsets[line-from+1]]) {
			if changedFirst < 0 {
				changedFirst = line
			}
			changedLast = line
		}
	}
	more := h.cp.firstDirty < len(h.cp.lines)
	if !more {
		h.running = false
	}
	onChange := h.onChange
	h.mu.Unlock()
	if changedFirst >= 0 && onChange != nil {
		onChange(changedFirst, changedLast)
	}
	return more
}

// SetSemantic lays a language server's semantic tokens of text over the lexical ones,
// replacing those laid before. It reports false, and drops the tokens, when the highlighter's
// text is no longer text: the server answered for a version since edited. The tokens are
// sorted and converted before the lock is taken, so a large answer never stalls painting.
func (h *Highlighter) SetSemantic(text rope.Rope, legend *SemanticLegend, tokens []SemanticToken) bool {
	built := buildSemantic(text, legend, tokens)
	h.mu.Lock()
	if !h.text.Same(text) {
		h.mu.Unlock()
		return false
	}
	h.semantic = built
	count := h.text.LineCount()
	onChange := h.onChange
	h.mu.Unlock()
	if onChange != nil {
		onChange(0, count-1)
	}
	return true
}

// ClearSemantic drops the semantic tokens, as when the language server stops.
func (h *Highlighter) ClearSemantic() {
	h.mu.Lock()
	had := len(h.semantic) > 0
	h.semantic = nil
	count := h.text.LineCount()
	onChange := h.onChange
	h.mu.Unlock()
	if had && onChange != nil {
		onChange(0, count-1)
	}
}
