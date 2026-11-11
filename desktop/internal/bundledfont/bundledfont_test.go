package bundledfont

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// manifest maps every entry under root to its mode and, for files, the hash of its bytes.
func manifest(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		value := info.Mode().String() + " " + info.ModTime().UTC().String()
		if entry.Type().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			sum := sha256.Sum256(data)
			value += " " + hex.EncodeToString(sum[:])
		}
		out[relative] = value
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestRegisterReadsTheBundleFontsWithoutChangingTheBundle(t *testing.T) {
	bundle := filepath.Join(t.TempDir(), "Lithe.app")
	folder := filepath.Join(bundle, "Contents", "Resources", FolderName)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"Inter-Regular.otf":          "inter-regular",
		"Inter-Bold.otf":             "inter-bold",
		"JetBrainsMono-Regular.ttf":  "mono-regular",
		"JetBrainsMono-Damaged.ttf":  "damaged",
		"OFL.txt":                    "license",
		"Unrelated-Regular.ttf":      "unrelated",
		"JetBrainsMono-Italic.woff2": "not a supported format",
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(folder, name), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	before := manifest(t, bundle)

	var registered []string
	set := Register(folder, func(data []byte) (string, func(), error) {
		registered = append(registered, string(data))
		switch {
		case string(data) == "damaged":
			return "", nil, errors.New("damaged font")
		case strings.HasPrefix(string(data), "inter"):
			return "Inter", func() {}, nil
		default:
			return "JetBrains Mono", func() {}, nil
		}
	})

	if set.UI != "Inter" || set.Mono != "JetBrains Mono" {
		t.Fatalf("registered families = %+v", set)
	}
	if len(registered) != 4 {
		t.Fatalf("registered %q; want the four Inter and JetBrains Mono font files only", registered)
	}
	if after := manifest(t, bundle); !maps.Equal(before, after) {
		t.Fatalf("reading the bundled fonts changed the bundle:\nbefore %v\nafter  %v", before, after)
	}
}

func TestRegisterWithoutAFolderRegistersNothing(t *testing.T) {
	called := false
	set := Register("", func([]byte) (string, func(), error) {
		called = true
		return "Inter", func() {}, nil
	})
	if called || set != (Set{}) {
		t.Fatalf("an absent folder registered %+v (called %v)", set, called)
	}
}
