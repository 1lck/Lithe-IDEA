// Package bundledfont registers the fonts the macOS client ships with, for this process only.
//
// The font files are tracked in fonts/ beside this package: the Inter 4.1 static OTF faces, the
// JetBrains Mono 2.304 static TTF faces and the four JetBrains Mono Nerd Font Mono faces of Nerd
// Fonts v3.5.1, unmodified, with their licenses and sources in fonts/NOTICE.txt. The packaged
// macOS build compiles that folder into the executable under the lithe_bundled_fonts build tag
// (scripts/desktop/package-desktop.sh passes it); every other build carries no fonts, Files is nil
// and every caller keeps the system's fonts.
//
// The fonts travel inside the executable rather than as files in the app bundle: the packaging
// tool has no step that adds files to the bundle, and an embedded face needs none. Nothing reads
// or writes the installed package for them, so the signed bundle and its update baseline stay as
// they were built. app.RegisterFont stages each face in the user's cache directory and registers
// it with CoreText at process scope; the user's font library is never changed.
package bundledfont

import (
	"io/fs"
	"path"
	"strings"
)

// Set names the families the bundled fonts registered under. An empty name means that group is
// not bundled and the caller keeps the system font.
type Set struct {
	// UI is the interface font (Inter), Mono the code font (JetBrains Mono) and Terminal the
	// terminal's Nerd Font (JetBrainsMono Nerd Font Mono), whose glyphs include the cell-aligned
	// prompt symbols of shells such as Starship and Powerlevel10k.
	UI, Mono, Terminal string
}

// Registrar registers one font file's data and returns its family name, as app.RegisterFont does.
type Registrar func(data []byte) (family string, unregister func(), err error)

// groups map a file name prefix to the Set field it fills. The prefixes end at the dash before the
// style, so the Nerd Font faces are never taken for the plain JetBrains Mono ones.
var groups = []struct {
	prefix string
	field  func(*Set) *string
}{
	{"Inter-", func(s *Set) *string { return &s.UI }},
	{"JetBrainsMono-", func(s *Set) *string { return &s.Mono }},
	{"JetBrainsMonoNerdFontMono-", func(s *Set) *string { return &s.Terminal }},
}

// Register reads the font files at the root of files and registers them. Only .otf, .ttf and .ttc
// files whose name starts with a known group prefix are used; each weight and style is its own file
// of the same family, so the first file of a group that registers names it. A file that cannot be
// read or registered is skipped, so one damaged face does not hide the others. A nil files or
// register registers nothing.
func Register(files fs.FS, register Registrar) Set {
	var set Set
	if files == nil || register == nil {
		return set
	}
	entries, err := fs.ReadDir(files, ".")
	if err != nil {
		return set
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !fontFile(name) {
			continue
		}
		field := groupField(&set, name)
		if field == nil {
			continue
		}
		data, err := fs.ReadFile(files, name)
		if err != nil {
			continue
		}
		family, _, err := register(data)
		if err != nil || family == "" {
			continue
		}
		if *field == "" {
			*field = family
		}
	}
	return set
}

// groupField is the field of set the file name belongs to, or nil for a file of no group.
func groupField(set *Set, name string) *string {
	for _, group := range groups {
		if strings.HasPrefix(name, group.prefix) {
			return group.field(set)
		}
	}
	return nil
}

func fontFile(name string) bool {
	switch strings.ToLower(path.Ext(name)) {
	case ".otf", ".ttf", ".ttc":
		return true
	}
	return false
}
