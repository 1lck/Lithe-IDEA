package editorview

import "strings"

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
		st.searching, st.prompt = false, nil
		v.vimCancel()
	case vimEnter:
		st.searching = false
		pat := string(st.prompt)
		st.prompt = nil
		v.vimCancel()
		if pat == "" {
			pat = st.pattern
		}
		if pat == "" {
			return
		}
		st.pattern, st.searchBackward = pat, st.searchBack
		v.vimSearchFrom(pat, st.searchBackward)
	case vimBackspace:
		if len(st.prompt) == 0 {
			st.searching = false
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
// set. It wraps around the text. The second result is false when pat does not occur.
func (v *View) vimSearchFrom(pat string, back bool) bool {
	text := v.text.String()
	c := v.caret
	at := -1
	if !back {
		from := min(v.nextRune(c), len(text))
		if i := strings.Index(text[from:], pat); i >= 0 {
			at = from + i
		} else if i := strings.Index(text, pat); i >= 0 {
			at = i
		}
	} else {
		if i := strings.LastIndex(text[:c], pat); i >= 0 {
			at = i
		} else if i := strings.LastIndex(text, pat); i >= 0 {
			at = i
		}
	}
	if at < 0 {
		return false
	}
	v.vimMoveCaret(vimMove{to: at})
	return true
}
