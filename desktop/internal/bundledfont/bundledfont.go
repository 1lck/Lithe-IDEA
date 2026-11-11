// Package bundledfont finds the fonts the macOS package ships with and registers them for the
// process. The package is read-only: it reads the Fonts folder inside the application bundle and
// never writes there, so the signed bundle and its update baseline stay as they were built.
//
// Font files are a build-time input. The package staging step copies them into the bundle's
// Resources, in the folder FolderName (Inter 4.1 static OTF and JetBrains Mono 2.304 static TTF,
// with their licenses); until that step ships, the folder is absent and every caller falls back
// to the system's fonts, which is what the client did before. installedpackage locates the folder.
package bundledfont

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
)

// FolderName is the folder inside the bundle's Resources that holds the font files.
const FolderName = "Fonts"

// Set names the families the bundled fonts registered under. An empty name means that group is
// not bundled and the caller keeps the system font.
type Set struct {
	// UI is the family of the interface font (Inter), Mono the family of the code font.
	UI, Mono string
}

// Registrar registers one font file's data and returns its family name, as app.RegisterFont does.
type Registrar func(data []byte) (family string, unregister func(), err error)

// groups are the file name prefixes of each family, in the order the files are read.
var groups = []struct {
	prefix string
	set    func(*Set, string)
}{
	{"Inter", func(s *Set, f string) { s.UI = f }},
	{"JetBrainsMono", func(s *Set, f string) { s.Mono = f }},
}

// Folder returns the Fonts folder of the running application bundle, or "" when the client is
// not running from a macOS app bundle (development builds, other platforms).
func Folder() string {
	return installedpackage.ResourceFolder(FolderName)
}

// Register reads the font files of folder and registers them. Only .otf, .ttf and .ttc files whose
// name starts with a known family are used; the first file of a family names it. Files that fail to
// register are skipped, so one damaged file does not hide the others.
func Register(folder string, register Registrar) Set {
	var set Set
	if folder == "" || register == nil {
		return set
	}
	entries, err := os.ReadDir(folder)
	if err != nil {
		return set
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !fontFile(name) {
			continue
		}
		for _, group := range groups {
			if !strings.HasPrefix(name, group.prefix) {
				continue
			}
			data, err := os.ReadFile(filepath.Join(folder, name))
			if err != nil {
				break
			}
			family, _, err := register(data)
			if err != nil || family == "" {
				break
			}
			// Each weight is its own file; the family is the same, so the first one names it.
			current := ""
			switch group.prefix {
			case "Inter":
				current = set.UI
			case "JetBrainsMono":
				current = set.Mono
			}
			if current == "" {
				group.set(&set, family)
			}
			break
		}
	}
	return set
}

func fontFile(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".otf", ".ttf", ".ttc":
		return true
	}
	return false
}
