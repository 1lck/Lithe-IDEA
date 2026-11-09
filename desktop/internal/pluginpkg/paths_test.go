package pluginpkg

import (
	"errors"
	"strings"
	"testing"
)

func TestValidatePathAcceptsPackagePaths(t *testing.T) {
	valid := []string{
		"plugin.json",
		"lib/a.txt",
		"a/b/c/d",
		"languages/java/tmLanguage.json",
		"语法/Java 语法.json",
		"COM0",
		"COM10",
		"lib/auxiliary.txt",
	}
	for _, name := range valid {
		t.Run(name, func(t *testing.T) {
			got, err := ValidatePath(name)
			if err != nil {
				t.Fatalf("ValidatePath(%q) = %v", name, err)
			}
			if got != name {
				t.Fatalf("ValidatePath(%q) = %q", name, got)
			}
		})
	}
}

func TestValidatePathRefusesUnsafeNames(t *testing.T) {
	invalid := map[string]string{
		"empty":              "",
		"absolute":           "/etc/passwd",
		"backslash":          `lib\a.txt`,
		"empty segment":      "a//b",
		"current directory":  "a/./b",
		"parent directory":   "a/../b",
		"only parent":        "..",
		"only current":       ".",
		"trailing separator": "lib/",
		"drive letter":       "C:/lib",
		"colon":              "a/b:c",
		"nul byte":           "a\x00b",
		"control character":  "a\x1fb",
		"trailing dot":       "a/b.",
		"trailing space":     "a/b ",
		"device con":         "CON",
		"device con suffix":  "con.txt",
		"device com1":        "COM1",
		"device lpt9":        "lpt9",
		"device aux":         "AUX",
		"device nul":         "NUL",
	}
	for name, path := range invalid {
		t.Run(name, func(t *testing.T) {
			if _, err := ValidatePath(path); !errors.Is(err, ErrUnsafePath) {
				t.Fatalf("ValidatePath(%q) = %v", path, err)
			}
		})
	}
}

func TestValidatePathBoundsLength(t *testing.T) {
	longest := strings.Repeat("a", MaxPathLength)
	if _, err := ValidatePath(longest); err != nil {
		t.Fatalf("a path of exactly %d bytes was refused: %v", MaxPathLength, err)
	}
	if _, err := ValidatePath(longest + "a"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("a path over the length limit was accepted: %v", err)
	}
}

func TestValidatePathBoundsDepth(t *testing.T) {
	deepest := strings.Repeat("a/", MaxPathDepth-1) + "a"
	if _, err := ValidatePath(deepest); err != nil {
		t.Fatalf("a path of exactly %d segments was refused: %v", MaxPathDepth, err)
	}
	if _, err := ValidatePath(deepest + "/a"); !errors.Is(err, ErrUnsafePath) {
		t.Fatalf("a path over the depth limit was accepted: %v", err)
	}
}

func TestParentDirectories(t *testing.T) {
	got := parentDirectories("a/b/c")
	want := []string{"a", "a/b"}
	if len(got) != len(want) {
		t.Fatalf("parentDirectories = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("parentDirectories = %v", got)
		}
	}
	if got := parentDirectories("a"); got != nil {
		t.Fatalf("parentDirectories(\"a\") = %v", got)
	}
}

func TestFoldPathIgnoresCase(t *testing.T) {
	if foldPath("Lib/A.TXT") != foldPath("lib/a.txt") {
		t.Fatal("foldPath does not fold case")
	}
}
