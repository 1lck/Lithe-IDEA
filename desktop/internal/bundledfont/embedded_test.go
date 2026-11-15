//go:build darwin && lithe_bundled_fonts

package bundledfont

import (
	"bytes"
	"io/fs"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/vivaui/viva/app"
)

// TestTheEmbeddedFontsAreTheTrackedFolder checks that the packaged build carries every tracked
// file, licenses included, byte for byte.
func TestTheEmbeddedFontsAreTheTrackedFolder(t *testing.T) {
	embedded, tracked := Files(), os.DirFS("fonts")
	if embedded == nil {
		t.Fatal("the lithe_bundled_fonts build carries no fonts")
	}
	names := func(files fs.FS) []string {
		entries, err := fs.ReadDir(files, ".")
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, entry := range entries {
			out = append(out, entry.Name())
		}
		return out
	}
	if got, want := names(embedded), names(tracked); !slices.Equal(got, want) {
		t.Fatalf("embedded files %q, tracked %q", got, want)
	}
	for _, name := range names(tracked) {
		got, err := fs.ReadFile(embedded, name)
		if err != nil {
			t.Fatal(err)
		}
		want, err := fs.ReadFile(tracked, name)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("the embedded %s differs from the tracked file", name)
		}
	}
}

// TestTheEmbeddedFontsRegisterTheirFamilies registers the real faces with CoreText and checks the
// families the client draws in, and that the terminal's Nerd Font is listed as a fixed-pitch
// family. The staged copies go to a temporary cache directory.
func TestTheEmbeddedFontsRegisterTheirFamilies(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	started := time.Now()
	set := Register(Files(), app.RegisterFont)
	t.Logf("registering the bundled fonts took %v", time.Since(started))
	want := Set{UI: "Inter", Mono: "JetBrains Mono", Terminal: "JetBrainsMono Nerd Font Mono"}
	if set != want {
		t.Fatalf("registered families = %+v, want %+v", set, want)
	}
	if !slices.Contains(app.MonospaceFamilies(), set.Terminal) {
		t.Fatalf("%q is not listed among the fixed-pitch families", set.Terminal)
	}
}
