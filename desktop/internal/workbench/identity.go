package workbench

import (
	"unicode"

	"github.com/vivaui/viva/gfx"
)

// A project is recognized at a glance by a small square badge: the first letters of its
// name on a gradient that its path picks. The macOS client draws the same badge with the
// same nine gradients and the same hash, so a project looks alike in both clients.

// projectIdentity is what the badge of one project shows.
type projectIdentity struct {
	// initials are the letters on the badge: one or two characters, never empty.
	initials string
	// start and end are the colors of the gradient, from the top left corner to the bottom
	// right one.
	start, end gfx.Color
}

// identityGradients are the nine gradients a project can get, as 0xRRGGBB pairs. Their
// order is part of the identity: the index a path hashes to picks the entry, and the
// macOS client counts them the same way.
var identityGradients = [...][2]uint32{
	{0xE08855, 0xE9806F},
	{0xB08B14, 0xBB7F19},
	{0xA1A359, 0x87AA59},
	{0x3B92B8, 0x6183EC},
	{0x3574F0, 0x7A64F0},
	{0xC84D8F, 0xA956CF},
	{0x955AE0, 0xA84DE0},
	{0x24A394, 0x279CCD},
	{0x5FAD65, 0x3D968B},
}

const (
	// identityFallback is what a name with no letter or digit in it shows.
	identityFallback = "LI"

	// The 64-bit FNV-1a hash of a path picks its gradient. The hash is spelled out, and
	// not taken from hash/fnv, because it runs for every recent project on the frame the
	// project menu opens and a hasher would be allocated for each.
	fnvOffset64 = 14695981039346656037
	fnvPrime64  = 1099511628211

	// identityRadius is the corner radius of the badge as a share of its side, as on macOS.
	identityRadius = 0.235
	// The font size of the initials is identityFontPoints for a badge of identityFontBase,
	// and grows and shrinks with the badge, as on macOS: 13 points on a badge of 20.
	identityFontPoints = 13
	identityFontBase   = 20
	// identityFillShare is how much of the badge's side the initials may take up. Letters
	// that are wider than the monospaced ones of the macOS badge are set smaller to stay
	// inside it.
	identityFillShare = 0.9
	// identityLetterEms and identityWideEms are the width of a letter and of a wide
	// character (a Chinese, Japanese or Korean one), in ems, for a semibold face.
	identityLetterEms = 0.65
	identityWideEms   = 1.0

	// identityMissingOpacity is the opacity a project whose folder is gone is shown with,
	// its badge on the start screen and the whole row in the project menu.
	identityMissingOpacity = 0.5
)

// identityInk is the color of the initials on every gradient.
var identityInk = gfx.RGB24(0xFFFFFF)

// identityOf is the badge of the project at path whose folder is called name.
func identityOf(path, name string) projectIdentity {
	gradient := identityGradients[identityColorIndex(path)]
	return projectIdentity{
		initials: identityInitials(name),
		start:    gfx.RGB24(gradient[0]),
		end:      gfx.RGB24(gradient[1]),
	}
}

// identityColorIndex is the entry of identityGradients a path gets: its 64-bit FNV-1a hash
// over the UTF-8 bytes, modulo the number of gradients. The same path always gets the same
// color, in either client, whatever else is open.
func identityColorIndex(path string) int {
	hash := uint64(fnvOffset64)
	for i := 0; i < len(path); i++ {
		hash ^= uint64(path[i])
		hash *= fnvPrime64
	}
	return int(hash % uint64(len(identityGradients)))
}

// identityInitials are the first characters of the first two words of name, upper case.
// A word is a run of letters and digits, so "lithe-idea" is two words and "LI" its
// initials. A name with no word shows identityFallback.
func identityInitials(name string) string {
	var initials [2]rune
	count, inWord := 0, false
	for _, r := range name {
		switch {
		case unicode.IsMark(r):
			// A combining mark belongs to the character before it and does not end the word.
			continue
		case !unicode.IsLetter(r) && !unicode.IsDigit(r):
			inWord = false
			continue
		case inWord:
			continue
		}
		inWord = true
		initials[count] = unicode.ToUpper(r)
		count++
		if count == len(initials) {
			break
		}
	}
	if count == 0 {
		return identityFallback
	}
	return string(initials[:count])
}

// identityIsWide reports a character of a script that is set about one em wide, whatever
// the face: Chinese, Japanese and Korean.
func identityIsWide(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) ||
		unicode.Is(unicode.Katakana, r) || unicode.Is(unicode.Hangul, r)
}

// identityFont is the font size the initials are set in on a badge of the given side, and
// whether the face is monospaced. Plain ASCII initials are monospaced, as on macOS, which
// makes their width exact: two cells of 0.6 em. Any other initials use the proportional
// face and are made smaller when they would not fit, which two Chinese characters do at
// the size of the Latin ones.
func identityFont(initials string, side float32) (size float32, mono bool) {
	// The size is cut to whole points, like the macOS badge's.
	size = float32(int(identityFontPoints * side / identityFontBase))
	ems, ascii := float32(0), true
	for _, r := range initials {
		if r < 0x20 || r >= 0x7F {
			ascii = false
		}
		if identityIsWide(r) {
			ems += identityWideEms
		} else {
			ems += identityLetterEms
		}
	}
	if ascii {
		return size, true
	}
	if limit := side * identityFillShare; ems*size > limit {
		// The small amount keeps a quotient that is whole in exact arithmetic from being cut
		// down by float32 rounding.
		size = float32(int(limit/ems + 0.001))
	}
	return max(size, 1), false
}
