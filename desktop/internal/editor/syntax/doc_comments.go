package syntax

import (
	"bytes"
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/textmate"
)

const (
	// DocShellBlockStar identifies /** ... */ and /*! ... */ documentation blocks.
	DocShellBlockStar = "block-star"
	// DocShellLineSlash identifies consecutive /// or //! documentation lines.
	DocShellLineSlash = "line-slash"

	// maxDocCommentBlocks caps extracted documentation blocks per file so huge
	// comment-heavy files keep bounded memory and work.
	maxDocCommentBlocks = 1024

	fnvOffset64 = 14695981039346656037
	fnvPrime64  = 1099511628211
)

// DocCommentRange describes one standalone full-line documentation comment
// confirmed by a completed lexical pass over the document.
type DocCommentRange struct {
	StartLine, EndLine int
	StartByte, EndByte int
	ShellKind, Dialect string
	ContentHash        uint64
}

// ExtractDocComments runs a completed lexical pass from line 0 through the end
// of text using syn's TextMate grammar (never guessed checkpoints) and returns
// standalone full-line documentation comment ranges with explicit shell
// boundaries. It returns (nil, true) without reading rope bytes when
// text.Len() > maxBytes, (nil, false) when syn declares no documentation
// comment dialects, and sets truncated when the scan stops at the block cap or
// context cancellation.
func ExtractDocComments(ctx context.Context, syn *Syntax, text rope.Rope, maxBytes int) ([]DocCommentRange, bool) {
	if syn == nil || syn.grammar == nil {
		return nil, false
	}
	dialects := syn.DocComments()
	if dialects.Block == "" && dialects.Line == "" {
		return nil, false
	}
	if text.Len() > maxBytes {
		return nil, true
	}
	if ctx != nil && ctx.Err() != nil {
		return nil, true
	}

	isRust := syn.language != nil && syn.language.ID == "rust"
	tz := syn.grammar.NewTokenizer()
	var (
		state     *textmate.StateStack
		lineBuf   []byte
		tokensBuf []textmate.Token
		ranges    []DocCommentRange
	)

	// Open block-star doc comment tracker.
	var (
		inBlock        bool
		blockInvalid   bool
		blockStartLine int
		blockStartByte int
	)

	// Open consecutive line-slash doc comment tracker.
	var (
		inLine        bool
		linePrefix    string // "///" or "//!"
		lineStartLine int
		lineEndLine   int
		lineStartByte int
		lineEndByte   int
		lineHasBody   bool
	)

	appendRange := func(r DocCommentRange) bool {
		if len(ranges) >= maxDocCommentBlocks {
			return false
		}
		r.ContentHash = hashRopeRange(text, r.StartByte, r.EndByte)
		ranges = append(ranges, r)
		return true
	}

	flushLine := func() bool {
		if !inLine {
			return true
		}
		inLine = false
		if !lineHasBody {
			return true
		}
		return appendRange(DocCommentRange{
			StartLine: lineStartLine,
			EndLine:   lineEndLine,
			StartByte: lineStartByte,
			EndByte:   lineEndByte,
			ShellKind: DocShellLineSlash,
			Dialect:   dialects.Line,
		})
	}

	lineCount := text.LineCount()
	for line := 0; line < lineCount; line++ {
		if ctx != nil && ctx.Err() != nil {
			return ranges, true
		}

		lineStart := text.LineStart(line)
		lineEnd := text.LineEnd(line)
		if lineEnd-lineStart > maxLineBytes {
			if !flushLine() {
				return ranges, true
			}
			inBlock = false
			blockInvalid = false
			// Skipping an over-limit line leaves the outgoing TextMate lexical
			// state unknown (for example, the skipped line may open a template
			// literal or multi-line string). Stop scanning rather than reusing
			// the stale pre-skip state on subsequent lines.
			return ranges, true
		}

		lineBuf = text.AppendLine(lineBuf[:0], line)
		prevState := state
		prevBlockDepth := stateBlockCommentDepth(prevState)
		// Pass 0 for line time limit so lazy grammar pattern compilation (e.g. PHP/C++)
		// never aborts a completed lexical pass; work is bounded by maxBytes, maxLineBytes,
		// regexp2's backtrack limit, maxDocCommentBlocks, and ctx.
		tokens, endState, _ := tz.TokenizeLine(tokensBuf[:0], lineBuf, prevState, 0)
		tokensBuf = tokens
		state = endState
		endBlockDepth := stateBlockCommentDepth(endState)

		startCol, endCol := trimLineSpan(lineBuf)

		// Continuation of an open multi-line block-star doc comment.
		if inBlock {
			if endBlockDepth > 0 {
				if startCol < endCol && !allRangeInBlockComment(tokens, len(lineBuf), startCol, endCol) {
					blockInvalid = true
				}
				continue
			}
			// Block comment closed on this line.
			inBlock = false
			if blockInvalid || startCol >= endCol {
				blockInvalid = false
				continue
			}
			if allRangeInBlockComment(tokens, len(lineBuf), startCol, endCol) {
				endByte := lineStart + endCol
				if validBlockCommentShell(text, blockStartByte, endByte, isRust) {
					if !appendRange(DocCommentRange{
						StartLine: blockStartLine,
						EndLine:   line,
						StartByte: blockStartByte,
						EndByte:   endByte,
						ShellKind: DocShellBlockStar,
						Dialect:   dialects.Block,
					}) {
						return ranges, true
					}
				}
			}
			blockInvalid = false
			continue
		}

		// Already inside a non-doc block comment (or multiline construct that owns
		// block comments); cannot open a standalone top-level doc comment here.
		if prevBlockDepth > 0 {
			if !flushLine() {
				return ranges, true
			}
			continue
		}

		// Blank line ends any open line-slash run.
		if startCol >= endCol {
			if !flushLine() {
				return ranges, true
			}
			continue
		}

		trimmed := lineBuf[startCol:endCol]
		openScopes := tokenAt(tokens, startCol)

		// Check line-slash documentation comments (/// or //!).
		if dialects.Line != "" && endBlockDepth == 0 {
			if prefix, ok := matchLineDocPrefix(trimmed, openScopes, isRust); ok {
				if inLine && linePrefix != prefix {
					if !flushLine() {
						return ranges, true
					}
				}
				if !inLine {
					inLine = true
					linePrefix = prefix
					lineStartLine = line
					lineStartByte = lineStart + startCol
					lineHasBody = false
				}
				lineEndLine = line
				lineEndByte = lineStart + endCol
				if !lineHasBody && hasNonWhitespace(trimmed[len(prefix):]) {
					lineHasBody = true
				}
				continue
			}
		}

		// Not a continuing line-slash comment: close any active line-slash run.
		if !flushLine() {
			return ranges, true
		}

		// Check block-star documentation comments (/** ... */ or /*! ... */).
		if dialects.Block == "" {
			continue
		}
		if !opensBlockDocComment(trimmed, openScopes, isRust) {
			continue
		}
		if !allRangeInBlockComment(tokens, len(lineBuf), startCol, endCol) {
			continue
		}

		if endBlockDepth == 0 {
			// Single-line block doc comment.
			startByte := lineStart + startCol
			endByte := lineStart + endCol
			if validBlockCommentShell(text, startByte, endByte, isRust) {
				if !appendRange(DocCommentRange{
					StartLine: line,
					EndLine:   line,
					StartByte: startByte,
					EndByte:   endByte,
					ShellKind: DocShellBlockStar,
					Dialect:   dialects.Block,
				}) {
					return ranges, true
				}
			}
			continue
		}

		// Multi-line block doc comment opens cleanly on this line.
		inBlock = true
		blockInvalid = false
		blockStartLine = line
		blockStartByte = lineStart + startCol
	}

	if !flushLine() {
		return ranges, true
	}
	return ranges, false
}

func trimLineSpan(line []byte) (start, end int) {
	end = len(line)
	for end > 0 && (line[end-1] == ' ' || line[end-1] == '\t' || line[end-1] == '\r') {
		end--
	}
	for start < end && (line[start] == ' ' || line[start] == '\t') {
		start++
	}
	return start, end
}

func hasNonWhitespace(b []byte) bool {
	for _, ch := range b {
		if ch != ' ' && ch != '\t' && ch != '\r' {
			return true
		}
	}
	return false
}

func stateBlockCommentDepth(state *textmate.StateStack) int {
	if state == nil {
		return 0
	}
	return blockCommentDepth(state.Scopes())
}

func blockCommentDepth(scopes *textmate.ScopeStack) int {
	depth := 0
	for at := scopes; at != nil; at = at.Parent() {
		if scopeMatches(at.Scope(), "comment.block") {
			depth++
		}
	}
	return depth
}

func outermostBlockCommentIsDoc(scopes *textmate.ScopeStack) bool {
	outer := ""
	for at := scopes; at != nil; at = at.Parent() {
		if scopeMatches(at.Scope(), "comment.block") {
			outer = at.Scope()
		}
	}
	if outer == "" {
		return false
	}
	return scopeMatches(outer, "comment.block.documentation") || scopeMatches(outer, "comment.block.javadoc")
}

func hasScopePrefix(scopes *textmate.ScopeStack, prefix string) bool {
	for at := scopes; at != nil; at = at.Parent() {
		if scopeMatches(at.Scope(), prefix) {
			return true
		}
	}
	return false
}

func tokenAt(tokens []textmate.Token, col int) *textmate.ScopeStack {
	var scopes *textmate.ScopeStack
	for _, tok := range tokens {
		if tok.Start > col {
			break
		}
		scopes = tok.Scopes
	}
	return scopes
}

func allRangeInBlockComment(tokens []textmate.Token, lineLen, start, end int) bool {
	if start >= end || len(tokens) == 0 {
		return false
	}
	covered := false
	for i, tok := range tokens {
		tokEnd := lineLen
		if i+1 < len(tokens) {
			tokEnd = tokens[i+1].Start
		}
		if tokEnd <= start {
			continue
		}
		if tok.Start >= end {
			break
		}
		if blockCommentDepth(tok.Scopes) == 0 {
			return false
		}
		covered = true
	}
	return covered
}

func matchLineDocPrefix(trimmed []byte, scopes *textmate.ScopeStack, isRust bool) (string, bool) {
	if len(trimmed) < 3 || blockCommentDepth(scopes) != 0 {
		return "", false
	}
	if bytes.HasPrefix(trimmed, []byte("///")) {
		// Four or more slashes (////) is a regular comment, not a doc comment.
		if len(trimmed) > 3 && trimmed[3] == '/' {
			return "", false
		}
		if hasScopePrefix(scopes, "comment.line.documentation") {
			return "///", true
		}
		return "", false
	}
	if bytes.HasPrefix(trimmed, []byte("//!")) {
		if hasScopePrefix(scopes, "comment.line.documentation") {
			return "//!", true
		}
		// The bundled Rust TextMate grammar tags //! as comment.line.double-slash.rust
		// rather than comment.line.documentation.rust; confirm it is a genuine line comment.
		if isRust && hasScopePrefix(scopes, "comment.line") {
			return "//!", true
		}
	}
	return "", false
}

func opensBlockDocComment(trimmed []byte, scopes *textmate.ScopeStack, isRust bool) bool {
	if len(trimmed) < 3 {
		return false
	}
	isStar := bytes.HasPrefix(trimmed, []byte("/**"))
	isBang := bytes.HasPrefix(trimmed, []byte("/*!"))
	if !isStar && !isBang {
		return false
	}
	// Reject trivial empty /**/ comments immediately.
	if isStar && len(trimmed) >= 4 && trimmed[3] == '/' {
		return false
	}
	// In Rust, /*** is a regular block comment, not a doc comment.
	if isRust && isStar && len(trimmed) >= 4 && trimmed[3] == '*' {
		return false
	}
	if outermostBlockCommentIsDoc(scopes) {
		return true
	}
	// The bundled Rust TextMate grammar tags /*! as comment.block.rust rather than
	// comment.block.documentation.rust; confirm it is a genuine top-level block comment.
	return isRust && isBang && blockCommentDepth(scopes) == 1
}

// validBlockCommentShell verifies explicit /** ... */ or /*! ... */ boundaries
// over exact rope bytes startByte..endByte so two adjacent blocks never merge
// and empty/banner-only shells are skipped.
func validBlockCommentShell(text rope.Rope, startByte, endByte int, allowNested bool) bool {
	length := endByte - startByte
	if length < 5 {
		return false
	}
	var (
		pos     int
		open    [3]byte
		depth   = 1
		pending byte
		hasBody bool
		ok      = true
	)
	text.Chunks(startByte, endByte, func(chunk string) bool {
		for i := 0; i < len(chunk); i++ {
			b := chunk[i]
			if pos < 3 {
				open[pos] = b
				pos++
				if pos == 3 {
					if open[0] != '/' || open[1] != '*' || (open[2] != '*' && open[2] != '!') {
						ok = false
						return false
					}
				}
				continue
			}
			if pos == 3 && open[2] == '*' && b == '/' {
				// Trivial /**/ closed immediately at pos 3.
				ok = false
				return false
			}
			if allowNested && pos == 3 && open[2] == '*' && b == '*' {
				// In Rust, /*** is not a doc comment.
				ok = false
				return false
			}
			if allowNested && pending == '/' && b == '*' {
				depth++
				pending = 0
				pos++
				continue
			}
			if pending == '*' && b == '/' {
				depth--
				pending = 0
				if depth == 0 {
					if pos != length-1 {
						// Comment closed before the end of the slice (e.g. /** a *//** b */).
						ok = false
					}
					pos++
					return false
				}
				pos++
				continue
			}
			if pos < length-2 && b != ' ' && b != '\t' && b != '\r' && b != '\n' && b != '*' {
				hasBody = true
			}
			pending = b
			pos++
		}
		return true
	})
	return ok && pos == length && depth == 0 && hasBody
}

func hashRopeRange(text rope.Rope, start, end int) uint64 {
	var h uint64 = fnvOffset64
	text.Chunks(start, end, func(chunk string) bool {
		for i := 0; i < len(chunk); i++ {
			h ^= uint64(chunk[i])
			h *= fnvPrime64
		}
		return true
	})
	return h
}
