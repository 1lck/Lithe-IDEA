package bundledfont

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"maps"
	"os"
	"slices"
	"strings"
	"testing"
	"testing/fstest"
)

func TestRegisterTakesEachGroupFromItsOwnFiles(t *testing.T) {
	files := fstest.MapFS{
		"Inter-Regular.otf":                  {Data: []byte("inter-regular")},
		"Inter-Bold.otf":                     {Data: []byte("inter-bold")},
		"JetBrainsMono-Regular.ttf":          {Data: []byte("mono-regular")},
		"JetBrainsMono-Damaged.ttf":          {Data: []byte("damaged")},
		"JetBrainsMonoNerdFontMono-Bold.ttf": {Data: []byte("nerd-bold")},
		"OFL.txt":                            {Data: []byte("license")},
		"Unrelated-Regular.ttf":              {Data: []byte("unrelated")},
		"JetBrainsMono-Italic.woff2":         {Data: []byte("not a supported format")},
		"nested/Inter-Thin.otf":              {Data: []byte("nested")},
	}
	var registered []string
	set := Register(files, func(data []byte) (string, func(), error) {
		registered = append(registered, string(data))
		switch text := string(data); {
		case text == "damaged":
			return "", nil, errors.New("damaged font")
		case strings.HasPrefix(text, "inter"):
			return "Inter", func() {}, nil
		case strings.HasPrefix(text, "nerd"):
			return "JetBrainsMono Nerd Font Mono", func() {}, nil
		default:
			return "JetBrains Mono", func() {}, nil
		}
	})

	want := Set{UI: "Inter", Mono: "JetBrains Mono", Terminal: "JetBrainsMono Nerd Font Mono"}
	if set != want {
		t.Fatalf("registered families = %+v, want %+v", set, want)
	}
	slices.Sort(registered)
	if wantFiles := []string{"damaged", "inter-bold", "inter-regular", "mono-regular", "nerd-bold"}; !slices.Equal(registered, wantFiles) {
		t.Fatalf("registered %q; want only the font files of the three groups at the root, %q", registered, wantFiles)
	}
}

func TestRegisterWithoutFilesRegistersNothing(t *testing.T) {
	called := false
	register := func([]byte) (string, func(), error) {
		called = true
		return "Inter", func() {}, nil
	}
	if set := Register(nil, register); called || set != (Set{}) {
		t.Fatalf("no files registered %+v (called %v)", set, called)
	}
	if set := Register(fstest.MapFS{"Inter-Regular.otf": {Data: []byte("x")}}, nil); set != (Set{}) {
		t.Fatalf("no registrar named %+v", set)
	}
}

// TestTheFontFolderMatchesItsManifest checks the tracked faces against the SHA-256 manifest in
// NOTICE.txt: every face is listed with its hash, nothing listed is missing, and the faces of
// each family are all there. A replaced or added face has to update the manifest with its source.
func TestTheFontFolderMatchesItsManifest(t *testing.T) {
	folder := os.DirFS("fonts")
	notice, err := fs.ReadFile(folder, "NOTICE.txt")
	if err != nil {
		t.Fatal(err)
	}
	manifest := map[string]string{}
	scanner := bufio.NewScanner(bytes.NewReader(notice))
	inList := false
	for scanner.Scan() {
		line := scanner.Text()
		if line == "SHA-256:" {
			inList = true
			continue
		}
		if !inList || line == "" {
			continue
		}
		sum, name, ok := strings.Cut(line, "  ")
		if !ok || len(sum) != 64 {
			t.Fatalf("manifest line %q is not \"<sha-256>  <file>\"", line)
		}
		manifest[name] = sum
	}

	entries, err := fs.ReadDir(folder, ".")
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() {
			t.Errorf("the font folder holds a directory %q", name)
			continue
		}
		if !fontFile(name) {
			continue
		}
		data, err := fs.ReadFile(folder, name)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(data)
		if got, want := hex.EncodeToString(sum[:]), manifest[name]; got != want {
			t.Errorf("%s has SHA-256 %s; the manifest lists %q", name, got, want)
		}
		delete(manifest, name)
		var set Set
		switch groupField(&set, name) {
		case &set.UI:
			counts["Inter"]++
		case &set.Mono:
			counts["JetBrains Mono"]++
		case &set.Terminal:
			counts["JetBrainsMono Nerd Font Mono"]++
		default:
			t.Errorf("%s belongs to no family", name)
		}
	}
	for name := range manifest {
		t.Errorf("the manifest lists %s, which is not in the folder", name)
	}
	if want := map[string]int{"Inter": 18, "JetBrains Mono": 16, "JetBrainsMono Nerd Font Mono": 4}; !maps.Equal(counts, want) {
		t.Errorf("faces per family = %v, want %v", counts, want)
	}
	for _, license := range []string{"Inter-LICENSE.txt", "OFL.txt", "AUTHORS.txt", "JetBrainsMonoNerdFont-OFL.txt"} {
		if _, err := fs.Stat(folder, license); err != nil {
			t.Errorf("license %s: %v", license, err)
		}
	}
}
