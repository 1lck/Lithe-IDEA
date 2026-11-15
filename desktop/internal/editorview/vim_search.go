package editorview

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// vim_search.go is the Vim search: the / and ? prompts, and n and N that repeat the last search. A
// search finds the text as typed, with no pattern syntax, from the character after the caret, and
// wraps around the end of the text.

// vimSearchStart opens the prompt for a search forward (/) or back (?).
func (v *View) vimSearchStart(back bool) {
	v.vimCancel()
	st := &v.vim
	st.searching, st.searchBack, st.prompt = true, back, nil
}

// vimSearchInput takes a key of the open prompt: typed text joins the pattern, Backspace removes its
// last character, Enter searches for it and Escape gives the prompt up. Backspace on an empty
// pattern gives it up too.
func (v *View) vimSearchInput(s string) {
	st := &v.vim
	switch s {
	case vimEscape:
		st.searching, st.exPrompt, st.prompt = false, false, nil
		v.vimCancel()
	case vimEnter:
		st.searching = false
		pat := string(st.prompt)
		st.prompt = nil
		v.vimCancel()
		if st.exPrompt {
			st.exPrompt = false
			v.vimExecute(pat)
			return
		}
		if pat == "" {
			pat = st.pattern
		}
		if pat == "" {
			return
		}
		st.pattern, st.searchBackward, st.wholeWord = pat, st.searchBack, false
		v.vimSearchFrom(pat, st.searchBackward)
	case vimBackspace:
		if len(st.prompt) == 0 {
			st.searching, st.exPrompt = false, false
			v.vimCancel()
			return
		}
		st.prompt = st.prompt[:len(st.prompt)-1]
	default:
		for _, r := range s {
			if vimPrintable(r) {
				st.prompt = append(st.prompt, r)
			}
		}
	}
}

// vimSearchRepeat is n (forward) and N (back): the last search again, in its direction or the
// opposite one.
func (v *View) vimSearchRepeat(forward bool) {
	st := &v.vim
	if st.pattern == "" {
		return
	}
	back := st.searchBackward
	if !forward {
		back = !back
	}
	v.vimSearchFrom(st.pattern, back)
}

// vimSearchFrom moves the caret to the next occurrence of pat after it, or before it when back is
// set, and wraps around the text. With wholeWord set, an occurrence must not touch a word character
// on either side. The second result is false when pat does not occur.
func (v *View) vimSearchFrom(pat string, back bool) bool {
	text := v.text.String()
	c := v.caret
	var hits []int
	for i := 0; ; {
		j := strings.Index(text[i:], pat)
		if j < 0 {
			break
		}
		at := i + j
		if !v.vim.wholeWord || vimWholeAt(text, at, len(pat)) {
			hits = append(hits, at)
		}
		i = at + 1
	}
	if len(hits) == 0 {
		return false
	}
	at := -1
	if !back {
		for _, h := range hits {
			if h >= v.nextRune(c) {
				at = h
				break
			}
		}
		if at < 0 {
			at = hits[0]
		}
	} else {
		for k := len(hits) - 1; k >= 0; k-- {
			if hits[k] < c {
				at = hits[k]
				break
			}
		}
		if at < 0 {
			at = hits[len(hits)-1]
		}
	}
	v.vimMoveCaret(vimMove{to: at})
	return true
}

// vimWholeAt says the occurrence of length n at at is a whole word: no word character touches it.
func vimWholeAt(text string, at, n int) bool {
	if at > 0 {
		r, _ := utf8.DecodeLastRuneInString(text[:at])
		if vimWordRune(r) {
			return false
		}
	}
	if end := at + n; end < len(text) {
		r, _ := utf8.DecodeRuneInString(text[end:])
		if vimWordRune(r) {
			return false
		}
	}
	return true
}

// vimWordRune says r is a word character for * and #: a letter, a digit or an underscore.
func vimWordRune(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

// vimSearchWordUnder is * (forward) and # (back): search for the word under the caret, as a whole
// word. Nothing happens when the caret is not on a word.
func (v *View) vimSearchWordUnder(back bool) {
	if v.vimClass(v.caret, false) != 2 {
		return
	}
	start, end, ok := v.vimWordObject(true, false)
	if !ok {
		return
	}
	word := string(v.text.AppendRange(nil, start, end))
	st := &v.vim
	st.pattern, st.searchBackward, st.wholeWord = word, back, true
	v.vimSearchFrom(word, back)
}

// vimToggleCase is ~: the case of the count characters from the caret is swapped, and the caret
// moves past them.
func (v *View) vimToggleCase() {
	n := max(v.vimRawCount(), 1)
	from := v.caret
	end := v.lineEnd(v.text.LineOf(from))
	var b strings.Builder
	to := from
	for i := 0; i < n && to < end; i++ {
		r := v.runeAt(to)
		switch {
		case unicode.IsUpper(r):
			b.WriteRune(unicode.ToLower(r))
		case unicode.IsLower(r):
			b.WriteRune(unicode.ToUpper(r))
		default:
			b.WriteRune(r)
		}
		to = v.nextRune(to)
	}
	if to == from {
		return
	}
	v.vim.changed = true
	v.edit(from, to, b.String(), editOther)
	v.moveTo(v.caret, false)
	v.vimClamp()
}
