package term

import (
	"testing"
	"unicode"
)

func TestWidth(t *testing.T) {
	for _, test := range []struct {
		r    rune
		want int
		name string
	}{
		{'a', 1, "ascii"},
		{'é', 1, "latin"},
		{0x301, 0, "combining acute"},
		{0x200D, 0, "zero width joiner"},
		{0xFE0F, 0, "variation selector"},
		{0xAD, 1, "soft hyphen"},
		{'я', 1, "cyrillic"},
		{'─', 1, "box drawing"},
		{'世', 2, "ideograph"},
		{'한', 2, "hangul"},
		{'ひ', 2, "hiragana"},
		{'，', 2, "fullwidth comma"},
		{'Ａ', 2, "fullwidth latin"},
		{'ｱ', 1, "halfwidth katakana"},
		{0x3099, 0, "combining voiced sound mark"},
		{'😀', 2, "emoji"},
		{'✓', 1, "check mark is narrow"},
		{0x20000, 2, "extension B ideograph"},
		{0x1F1E6, 1, "regional indicator"},
	} {
		if got := Width(test.r); got != test.want {
			t.Errorf("Width(%U %s) = %d, want %d", test.r, test.name, got, test.want)
		}
	}
}

func TestWideRangesAreSortedAndDisjoint(t *testing.T) {
	for i, r := range wideRanges {
		if r[0] > r[1] {
			t.Errorf("range %d is inverted: %x", i, r)
		}
		if i > 0 && r[0] <= wideRanges[i-1][1] {
			t.Errorf("range %d overlaps or is out of order: %x after %x", i, r, wideRanges[i-1])
		}
		// The bitmap covers [wideBase, wideLast]; a range outside it would index
		// past the table in buildWideBits and panic during package init.
		if r[0] < wideBase || r[1] > wideLast {
			t.Errorf("range %d (%U-%U) is outside the bitmap's [%U, %U]", i, r[0], r[1], wideBase, wideLast)
		}
	}
}

func TestIsWideMatchesTheRanges(t *testing.T) {
	rangeAt := func(r rune) bool {
		for _, w := range wideRanges {
			if r < w[0] {
				return false
			}
			if r <= w[1] {
				return true
			}
		}
		return false
	}
	for r := rune(0); r <= 0x10FFFF; r++ {
		if got, want := isWide(r), rangeAt(r); got != want {
			t.Fatalf("isWide(%U) = %v, want %v", r, got, want)
		}
	}
}

func TestIsWideCJKMatchesTheRanges(t *testing.T) {
	for r := rune(0); r <= 0x10FFFF; r++ {
		if isWideCJK(r) {
			if !isWide(r) {
				t.Fatalf("isWideCJK(%U) = true, but isWide is false", r)
			}
			if (r >= 0x302A && r <= 0x302D) || (r >= 0x3099 && r <= 0x309A) {
				t.Fatalf("isWideCJK(%U) is a combining mark", r)
			}
			if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) || unicode.Is(unicode.Cf, r) {
				t.Fatalf("isWideCJK(%U) is zero-width", r)
			}
		}
	}
}

func BenchmarkWidth(b *testing.B) {
	runes := []rune("The quick 世界 brown ｆｏｘ é ✓ 😀")
	b.ReportAllocs()
	n := 0
	for b.Loop() {
		for _, r := range runes {
			n += Width(r)
		}
	}
	_ = n
}
