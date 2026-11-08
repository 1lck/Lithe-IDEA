package fileicons

import (
	"testing"

	"github.com/vivaui/viva/ui"
)

// TestFileKind covers the supported name rules and their precedence.
func TestFileKind(t *testing.T) {
	tests := []struct {
		name string
		want kind
	}{
		{"a.jsonl", kindJSON},
		{"a.jsonlines", kindJSON},
		{"a.ndjson", kindJSON},
		{"a.ldjson", kindJSON},
		{"a.wbmp", kindImage},
		{"a.doc", kindDocument},
		{"a.docx", kindDocument},
		{"a.ppt", kindDocument},
		{"a.pptx", kindDocument},
		{"Localizable.strings", kindI18n},
		{"README.md", kindReadme},
		{"readme", kindReadme},
		{"LICENSE", kindLicense},
		{"LICENSE.txt", kindLicense},
		{"COPYING", kindLicense},
		{"license-mit.txt", kindLicense},
		{".env", kindProperties},
		{".env.local", kindProperties},
		{"Dockerfile", kindDocker},
		{"Dockerfile.dev", kindDocker},
		{"docker-compose.yml", kindDocker},
		{"package.json", kindNodePackage},
		{"package-lock.json", kindLock},
		{"Cargo.lock", kindLock},
		{"go.mod", kindGoSource},
		{"main.go", kindGoSource},
		{"Makefile", kindMakefile},
		{"rules.mk", kindMakefile},
		{".gitignore", kindGitignore},
		{".editorconfig", kindEditorConfig},
		{"build.gradle.kts", kindKotlin},
		{"Main.java", kindUnknown},
		{"notes", kindUnknown},
		{".bashrc", kindUnknown},
		{"file.", kindUnknown},
		{"App.TSX", kindJavaScript},
		{"archive.tar.gz", kindBinary},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := fileKind(test.name); got != test.want {
				t.Errorf("fileKind(%q) = %d, want %d", test.name, got, test.want)
			}
		})
	}
}

// TestDirectoryKind covers excluded directory names and regular directories.
func TestDirectoryKind(t *testing.T) {
	tests := []struct {
		name string
		want kind
	}{
		{"node_modules", kindExcludedFolder},
		{"Target", kindExcludedFolder},
		{".idea", kindExcludedFolder},
		{"src", kindFolder},
		{"META-INF", kindFolder},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := directoryKind(test.name); got != test.want {
				t.Errorf("directoryKind(%q) = %d, want %d", test.name, got, test.want)
			}
		})
	}
}

// TestSplitExt covers basename extensions and dotfile boundaries.
func TestSplitExt(t *testing.T) {
	tests := []struct {
		name string
		stem string
		ext  string
	}{
		{"", "", ""},
		{".", ".", ""},
		{".bashrc", ".bashrc", ""},
		{"a.", "a.", ""},
		{"a.b.c", "a.b", "c"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			stem, ext := splitExt(test.name)
			if stem != test.stem || ext != test.ext {
				t.Errorf("splitExt(%q) = (%q, %q), want (%q, %q)", test.name, stem, ext, test.stem, test.ext)
			}
		})
	}
}

// TestKindIconsHaveLayeredVectors checks that every kind has a generated layered icon.
func TestKindIconsHaveLayeredVectors(t *testing.T) {
	for iconKind := kind(0); iconKind < kindCount; iconKind++ {
		variants := kindIcons[iconKind]
		light := variants[0]
		if light == nil {
			t.Errorf("kind %d has no light icon", iconKind)
			continue
		}
		if light.ViewBox <= 0 {
			t.Errorf("kind %d has a non-positive light icon view box", iconKind)
		}
		if len(light.Commands) != 0 {
			t.Errorf("kind %d has top-level light icon commands", iconKind)
		}
		if len(light.Layers) == 0 {
			t.Errorf("kind %d has no light icon layers", iconKind)
		}
		if dark := variants[1]; dark != nil && len(dark.Layers) == 0 {
			t.Errorf("kind %d has no dark icon layers", iconKind)
		}
	}
}

// TestForFileUsesDarkVariant checks that the dark look gets a kind's dark sibling when it has
// one and its light icon otherwise.
func TestForFileUsesDarkVariant(t *testing.T) {
	cases := []struct {
		name string
		dark bool
		want *ui.Icon
	}{
		{"a.json", true, &JsonDark},
		{"a.json", false, &Json},
		{"main.go", true, &Go},
		{"main.go", false, &Go},
	}
	for _, c := range cases {
		// The returned icon is a copy that shares the generated icon's layers.
		got := ForFile(c.name, c.dark)
		if len(got.Layers) == 0 || &got.Layers[0] != &c.want.Layers[0] {
			t.Errorf("ForFile(%q, %v) is not the expected generated icon", c.name, c.dark)
		}
	}
}
