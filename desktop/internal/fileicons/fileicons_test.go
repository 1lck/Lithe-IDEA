package fileicons

import (
	"testing"

	"github.com/vivaui/viva/gfx"
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
		{"Main.java", kindJava},
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
		want *gfx.Icon
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

func TestForDirectoryMark(t *testing.T) {
	if MarkPlain != 0 {
		t.Errorf("MarkPlain = %d, want zero value", MarkPlain)
	}
	cases := []struct {
		name      string
		mark      DirectoryMark
		lightIcon *gfx.Icon
		darkIcon  *gfx.Icon
	}{
		{"plain", MarkPlain, &Folder, &FolderDark},
		{"sources", MarkSources, &SourceRoot, &SourceRootDark},
		{"resources", MarkResources, &ResourcesRoot, &ResourcesRootDark},
		{"excluded", MarkExcluded, &ExcludeRoot, &ExcludeRootDark},
		{"module", MarkModule, &ModuleJava, &ModuleJavaDark},
		{"package", MarkPackage, &Package, &PackageDark},
		{"unknown", DirectoryMark(255), &Folder, &FolderDark},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			requireGeneratedIcon(t, ForDirectoryMark(test.mark, false), test.lightIcon)
			requireGeneratedIcon(t, ForDirectoryMark(test.mark, true), test.darkIcon)
		})
	}
}

func TestForSourceDirectory(t *testing.T) {
	cases := []struct {
		label     string
		directory string
		lightIcon *gfx.Icon
		darkIcon  *gfx.Icon
	}{
		{"com", "com", &Package, &PackageDark},
		{"_internal", "_internal", &Package, &PackageDark},
		{"v2", "v2", &Package, &PackageDark},
		{"中文", "中文", &Package, &PackageDark},
		{"META-INF", "META-INF", &Folder, &FolderDark},
		{"1abc", "1abc", &Folder, &FolderDark},
		{"my-lib", "my-lib", &Folder, &FolderDark},
		{"a.b", "a.b", &Folder, &FolderDark},
		{"empty", "", &Folder, &FolderDark},
		{"build", "build", &ExcludeRoot, &ExcludeRootDark},
		{"target", "target", &ExcludeRoot, &ExcludeRootDark},
	}
	for _, test := range cases {
		t.Run(test.label, func(t *testing.T) {
			requireGeneratedIcon(t, ForSourceDirectory(test.directory, false), test.lightIcon)
			requireGeneratedIcon(t, ForSourceDirectory(test.directory, true), test.darkIcon)
		})
	}
}

func TestIsPackageSegmentName(t *testing.T) {
	cases := []struct {
		label string
		name  string
		want  bool
	}{
		{"com", "com", true},
		{"_internal", "_internal", true},
		{"v2", "v2", true},
		{"中文", "中文", true},
		{"META-INF", "META-INF", false},
		{"1abc", "1abc", false},
		{"my-lib", "my-lib", false},
		{"a.b", "a.b", false},
		{"empty", "", false},
		{"build", "build", true},
		{"target", "target", true},
	}
	for _, test := range cases {
		t.Run(test.label, func(t *testing.T) {
			if got := IsPackageSegmentName(test.name); got != test.want {
				t.Errorf("IsPackageSegmentName(%q) = %v, want %v", test.name, got, test.want)
			}
		})
	}
}

func TestForTypeUsesClassVariants(t *testing.T) {
	requireGeneratedIcon(t, ForType(false), &Class)
	requireGeneratedIcon(t, ForType(true), &ClassDark)
}

func TestForSymbolUsesVariableWithoutDarkVariant(t *testing.T) {
	requireGeneratedIcon(t, ForSymbol(false), &Variable)
	requireGeneratedIcon(t, ForSymbol(true), &Variable)
}

func TestForBreakpoint(t *testing.T) {
	cases := []struct {
		name      string
		enabled   bool
		verified  bool
		muted     bool
		lightIcon *gfx.Icon
		darkIcon  *gfx.Icon
	}{
		{"disabled-unverified", false, false, false, &DbDisabledBreakpoint, &DbDisabledBreakpointDark},
		{"muted-disabled-unverified", false, false, true, &DbMutedBreakpoint, &DbMutedBreakpointDark},
		{"disabled-verified", false, true, false, &DbDisabledBreakpoint, &DbDisabledBreakpointDark},
		{"muted-disabled-verified", false, true, true, &DbMutedBreakpoint, &DbMutedBreakpointDark},
		{"enabled-unverified", true, false, false, &DbSetBreakpoint, &DbSetBreakpointDark},
		{"muted-enabled-unverified", true, false, true, &DbMutedBreakpoint, &DbMutedBreakpointDark},
		{"enabled-verified", true, true, false, &DbVerifiedBreakpoint, &DbVerifiedBreakpointDark},
		{"muted-enabled-verified", true, true, true, &DbMutedBreakpoint, &DbMutedBreakpointDark},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			requireGeneratedIcon(t, ForBreakpoint(test.enabled, test.verified, test.muted, false), test.lightIcon)
			requireGeneratedIcon(t, ForBreakpoint(test.enabled, test.verified, test.muted, true), test.darkIcon)
		})
	}
}

func requireGeneratedIcon(t *testing.T, got gfx.Icon, want *gfx.Icon) {
	t.Helper()
	if len(got.Layers) == 0 || len(want.Layers) == 0 || &got.Layers[0] != &want.Layers[0] {
		t.Errorf("got icon with %d layers; want generated asset with %d layers", len(got.Layers), len(want.Layers))
	}
}
