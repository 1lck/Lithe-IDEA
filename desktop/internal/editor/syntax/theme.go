package syntax

import (
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// Color is a 24-bit RGB color, 0xRRGGBB.
type Color uint32

// ParseColor parses "#RRGGBB" or "#RRGGBBAA", with or without the "#", as Monaco's token theme
// does: the alpha is dropped. It reports false for anything else.
func ParseColor(s string) (Color, bool) {
	s = strings.TrimPrefix(s, "#")
	if len(s) != 6 && len(s) != 8 {
		return 0, false
	}
	v, err := strconv.ParseUint(s[:6], 16, 32)
	if err != nil {
		return 0, false
	}
	if len(s) == 8 {
		if _, err := strconv.ParseUint(s[6:], 16, 8); err != nil {
			return 0, false
		}
	}
	return Color(v), true
}

// FontStyle is a set of font style flags.
type FontStyle uint8

const (
	Italic FontStyle = 1 << iota
	Bold
	Underline
	Strikethrough
)

// Style is how a token is drawn.
type Style struct {
	Foreground Color
	Font       FontStyle
}

// ThemeRule styles a token name and the names below it, as a Monaco token theme rule does.
type ThemeRule struct {
	// Token is a token name, or "" for the default style.
	Token string
	// Foreground is a color ParseColor accepts, or "" to keep the inherited one.
	Foreground string
	// FontStyle is a space-separated list of italic, bold, underline and strikethrough; "" is
	// no style. It applies only when SetsFontStyle is set; otherwise the inherited style stays.
	FontStyle     string
	SetsFontStyle bool
}

// Theme styles token names. It is a Monaco token theme: a name gets the style of the rule for
// its longest dotted prefix that has one, where each rule changes only what it sets of the
// style it inherits from the next shorter prefix, and rules for the same name apply in order.
// A Theme never changes and is safe for concurrent use.
type Theme struct {
	root *themeNode
	// styles caches Style by Name, for every Name made when the cache was last extended.
	styles atomic.Pointer[[]Style]
	mu     sync.Mutex
}

type themeNode struct {
	style    Style
	children map[string]*themeNode
}

// NewTheme builds a theme from rules. Colors ParseColor rejects are ignored; Monaco would
// reject the whole theme instead.
func NewTheme(rules []ThemeRule) *Theme {
	type parsed struct {
		token   string
		index   int
		fg      Color
		hasFG   bool
		font    FontStyle
		hasFont bool
	}
	list := make([]parsed, 0, len(rules))
	for i, rule := range rules {
		p := parsed{token: rule.Token, index: i}
		if rule.Foreground != "" {
			p.fg, p.hasFG = ParseColor(rule.Foreground)
		}
		if rule.SetsFontStyle {
			p.font, p.hasFont = parseFontStyle(rule.FontStyle), true
		}
		list = append(list, p)
	}
	slices.SortStableFunc(list, func(a, b parsed) int { return strings.Compare(a.token, b.token) })

	defaults := Style{Foreground: 0x000000}
	for len(list) > 0 && list[0].token == "" {
		if list[0].hasFG {
			defaults.Foreground = list[0].fg
		}
		if list[0].hasFont {
			defaults.Font = list[0].font
		}
		list = list[1:]
	}
	root := &themeNode{style: defaults}
	for _, p := range list {
		node := root
		for token := p.token; token != ""; {
			head, tail, _ := strings.Cut(token, ".")
			child := node.children[head]
			if child == nil {
				// A new name starts from its parent's style as it is now; rules are sorted,
				// so every rule of the parent has been applied.
				child = &themeNode{style: node.style}
				if node.children == nil {
					node.children = map[string]*themeNode{}
				}
				node.children[head] = child
			}
			node, token = child, tail
		}
		if p.hasFG {
			node.style.Foreground = p.fg
		}
		if p.hasFont {
			node.style.Font = p.font
		}
	}
	t := &Theme{root: root}
	t.extend()
	return t
}

func parseFontStyle(s string) FontStyle {
	var font FontStyle
	for part := range strings.SplitSeq(s, " ") {
		switch part {
		case "italic":
			font |= Italic
		case "bold":
			font |= Bold
		case "underline":
			font |= Underline
		case "strikethrough":
			font |= Strikethrough
		}
	}
	return font
}

// Match returns the style of token.
func (t *Theme) Match(token string) Style {
	node := t.root
	for token != "" {
		head, tail, _ := strings.Cut(token, ".")
		child := node.children[head]
		if child == nil {
			break
		}
		node, token = child, tail
	}
	return node.style
}

// Default is the style of tokens no rule styles.
func (t *Theme) Default() Style { return t.root.style }

// Style returns the style of n. It does not allocate once n's style is cached.
func (t *Theme) Style(n Name) Style {
	if styles := *t.styles.Load(); int(n) < len(styles) {
		return styles[n]
	}
	return t.extend()[n]
}

// extend caches the styles of every Name made so far and returns the cache.
func (t *Theme) extend() []Style {
	t.mu.Lock()
	defer t.mu.Unlock()
	var styles []Style
	if old := t.styles.Load(); old != nil {
		styles = *old
	}
	count := nameCount()
	if len(styles) >= count {
		return styles
	}
	grown := make([]Style, count)
	copy(grown, styles)
	for n := len(styles); n < count; n++ {
		grown[n] = t.Match(Name(n).String())
	}
	t.styles.Store(&grown)
	return grown
}
