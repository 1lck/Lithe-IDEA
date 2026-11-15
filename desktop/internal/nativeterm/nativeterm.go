// Package nativeterm reads the ANSI colors of the system terminal's default profile, so the
// built-in terminal can draw programs in the colors the user chose for them there. Only macOS's
// Terminal.app keeps such a profile; elsewhere nothing is read.
package nativeterm

import "sync"

// Colors is the 16 ANSI colors as 8-bit sRGB channels, and which of them the profile sets: a
// profile that keeps the built-in colors stores none of them.
type Colors struct {
	ANSI [16][3]uint8
	Set  [16]bool
}

var (
	once   sync.Once
	cached *Colors
)

// ANSI is the default profile's colors, read once; nil when there is no profile or it sets none.
func ANSI() *Colors {
	once.Do(func() {
		colors, ok := read()
		if !ok {
			return
		}
		for _, set := range colors.Set {
			if set {
				cached = &colors
				return
			}
		}
	})
	return cached
}
