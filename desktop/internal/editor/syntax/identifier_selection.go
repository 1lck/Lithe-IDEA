package syntax

import "unicode"

// IdentifierContinuation classifies the glyphs that the editor groups for a
// code-word selection. Like Core, it uses Unicode ID_Continue plus join
// controls and '$'. Go's Unicode tables expose the constituent properties.
func IdentifierContinuation(r rune) bool {
	if r == '$' {
		return true
	}
	return (identifierStart(r) || unicode.In(r, unicode.Mn, unicode.Mc, unicode.Nd, unicode.Pc,
		unicode.Other_ID_Continue, unicode.Join_Control)) &&
		!unicode.In(r, unicode.Pattern_Syntax, unicode.Pattern_White_Space)
}

func identifierStart(r rune) bool {
	return r == '_' || r == '$' || unicode.In(r, unicode.Letter, unicode.Nl, unicode.Other_ID_Start)
}

// IdentifierSelection reports whether a selection can name one code identifier.
// A language server decides its meaning, and Core checks its search boundaries.
func IdentifierSelection(value string) bool {
	for at, r := range value {
		if at == 0 && !identifierStart(r) || !IdentifierContinuation(r) {
			return false
		}
	}
	return value != ""
}
