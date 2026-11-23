package fileassociations

import (
	"context"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/syntax"
	"github.com/vivaui/viva/tools/manifest"
)

func TestFileAssociationsMatchBundledSyntaxAndNativePackages(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	formats, err := Catalog(ctx, core.NewClient())
	if err != nil {
		t.Fatal(err)
	}
	packaged, err := manifest.Load(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	if len(formats) != len(packaged.App.FileTypes) || len(formats) < 2 {
		t.Fatalf("catalog=%d, native package=%d", len(formats), len(packaged.App.FileTypes))
	}
	registry := syntax.NewRegistry()
	for index, format := range formats {
		kind := packaged.App.FileTypes[index]
		if len(kind.Extensions) != 1 || kind.Extensions[0] != strings.TrimPrefix(format.Extension, ".") {
			t.Fatalf("native package type %+v differs from settings %+v", kind, format)
		}
		language, ok := registry.ForPath("sample" + format.Extension)
		if !ok || language.ID != format.Language || (format.Language != "plaintext" && language.Scope == "") {
			t.Fatalf("catalog entry %+v does not resolve to bundled highlighting: %+v", format, language)
		}
		if format.Extension == ".rlib" || format.Extension == ".svgz" {
			t.Fatalf("non-text container included: %s", format.Extension)
		}
	}
}
