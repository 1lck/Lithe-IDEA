package syntax

import "slices"

// BundledFileType is metadata observed from the editor's built-in catalog. It
// does not include plugin contributions and does not load or tokenize grammars.
type BundledFileType struct {
	ID          string
	Highlighted bool
	Extensions  []string
}

// BundledFileTypes returns independent metadata for settings and packaging. Core
// decides which suffixes can safely be registered with the operating system.
func BundledFileTypes() []BundledFileType {
	result := make([]BundledFileType, len(bundledLanguages))
	for i, language := range bundledLanguages {
		result[i] = BundledFileType{
			ID: language.ID, Highlighted: hasBundledGrammar(language.Scope),
			Extensions: slices.Clone(language.Extensions),
		}
	}
	return result
}
