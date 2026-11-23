package pluginicons

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vivaui/viva/gfx"
)

const pluginID = "dev.lithe.test.icons"

// brand is a two-color original icon: a blue square with a white dot.
const brand = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M1 1H15V15H1Z" fill="#548AF7"/><circle cx="8" cy="8" r="2" fill="#FFFFFF"/></svg>`

func writePackage(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		target := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func readOne(t *testing.T, files map[string]string, declaration Declaration) (Icon, error) {
	t.Helper()
	var cache Cache
	dir := writePackage(t, files)
	err := cache.Read(pluginID, dir, declaration)
	icon, ok := cache.Lookup(pluginID, declaration)
	if ok != (err == nil) {
		t.Fatalf("Lookup = %v after Read = %v", ok, err)
	}
	return icon, err
}

func TestOriginalIconsKeepTheirColorsAndDarkVariant(t *testing.T) {
	dark := strings.ReplaceAll(brand, "#548AF7", "#1E1F22")
	icon, err := readOne(t, map[string]string{"icons/a.svg": brand, "icons/a-dark.svg": dark},
		Declaration{Path: "icons/a.svg", DarkPath: "icons/a-dark.svg", Mode: ModeOriginal})
	if err != nil {
		t.Fatal(err)
	}
	light := icon.For(false)
	if light.ViewBox != 16 || len(light.Layers) != 2 || len(light.Commands) != 0 {
		t.Fatalf("light = viewBox %v, %d layers, %d commands", light.ViewBox, len(light.Layers), len(light.Commands))
	}
	if blue := light.Layers[0].Fill; blue.Blue < 0.9 || blue.Red > 0.4 {
		t.Fatalf("the brand color was not kept: %+v", blue)
	}
	if fill := icon.For(true).Layers[0].Fill; fill.Blue > 0.2 {
		t.Fatalf("the dark theme does not use the dark variant: %+v", fill)
	}
}

func TestCompileSVGUsesTheSameDecoderWithoutAPackage(t *testing.T) {
	icon, err := CompileSVG("marketplace.svg", []byte(brand))
	if err != nil || icon.ViewBox != 16 || len(icon.Layers) != 2 || icon.Stroke != 0 {
		t.Fatalf("compiled SVG = %+v, error = %v", icon, err)
	}
	if fill := icon.Layers[0].Fill; fill.Blue < 0.9 || fill.Red > 0.4 {
		t.Fatalf("original color = %+v", fill)
	}
	for _, scenario := range []struct {
		name, data string
		want       error
	}{
		{"oversize", strings.Repeat("x", int(MaxFileBytes)+1), ErrRefused},
		{"script", `<svg><script/></svg>`, ErrRefused},
		{"png", "\x89PNG\r\n\x1a\n", ErrRefused},
		{"unsupported", `<svg viewBox="0 0 16 16"><text>A</text></svg>`, ErrUnsupported},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			if _, err := CompileSVG("marketplace.svg", []byte(scenario.data)); !errors.Is(err, scenario.want) {
				t.Fatalf("error = %v, want %v", err, scenario.want)
			}
		})
	}
}

func TestAnIconWithoutDarkVariantIsUsedInBothThemes(t *testing.T) {
	icon, err := readOne(t, map[string]string{"a.svg": brand}, Declaration{Path: "a.svg", Mode: ModeOriginal})
	if err != nil {
		t.Fatal(err)
	}
	if len(icon.For(true).Layers) != 2 {
		t.Fatal("the dark theme has no icon")
	}
}

func TestTemplateIconsAreDrawnInTheTint(t *testing.T) {
	icon, err := readOne(t, map[string]string{"a.svg": brand}, Declaration{Path: "a.svg"})
	if err != nil {
		t.Fatal(err)
	}
	glyph := icon.For(false)
	if len(glyph.Layers) != 0 || len(glyph.Commands) == 0 || glyph.Stroke != 0 {
		t.Fatalf("template = %d layers, %d commands, stroke %v", len(glyph.Layers), len(glyph.Commands), glyph.Stroke)
	}
}

func TestShapesWithoutPaintAreFilledAsInSVG(t *testing.T) {
	filled := `<svg viewBox="0 0 16 16"><path d="M2 2H14V14H2Z"/></svg>`
	icon, err := readOne(t, map[string]string{"a.svg": filled}, Declaration{Path: "a.svg"})
	if err != nil {
		t.Fatal(err)
	}
	if glyph := icon.For(false); glyph.Stroke != 0 || len(glyph.Commands) == 0 {
		t.Fatalf("an unpainted shape is stroked %v", glyph.Stroke)
	}
	stroked := `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12h14"/></svg>`
	icon, err = readOne(t, map[string]string{"a.svg": stroked}, Declaration{Path: "a.svg"})
	if err != nil {
		t.Fatal(err)
	}
	if glyph := icon.For(false); glyph.Stroke != 2 {
		t.Fatalf("a stroked icon has stroke %v", glyph.Stroke)
	}
}

func TestContentTheContractRefuses(t *testing.T) {
	cases := map[string]string{
		"script":       `<svg viewBox="0 0 16 16"><script>alert(1)</script><path d="M1 1H2V2Z"/></svg>`,
		"style":        `<svg viewBox="0 0 16 16"><style>path{fill:red}</style><path d="M1 1H2V2Z"/></svg>`,
		"style attr":   `<svg viewBox="0 0 16 16"><path style="fill:red" d="M1 1H2V2Z"/></svg>`,
		"handler":      `<svg viewBox="0 0 16 16" onload="x()"><path d="M1 1H2V2Z"/></svg>`,
		"image":        `<svg viewBox="0 0 16 16"><image href="data:image/png;base64,AAAA"/></svg>`,
		"external use": `<svg viewBox="0 0 16 16"><use href="other.svg#a"/></svg>`,
		"external url": `<svg viewBox="0 0 16 16"><path fill="url(https://example.com/g)" d="M1 1H2V2Z"/></svg>`,
		"doctype":      `<!DOCTYPE svg [<!ENTITY a "b">]><svg viewBox="0 0 16 16"><path d="M1 1H2V2Z"/></svg>`,
		"instruction":  `<?xml-stylesheet href="a.css"?><svg viewBox="0 0 16 16"><path d="M1 1H2V2Z"/></svg>`,
		"too wide":     `<svg viewBox="0 0 2048 16"><path d="M1 1H2V2Z"/></svg>`,
		"too tall":     `<svg width="16" height="4096" viewBox="0 0 16 16"><path d="M1 1H2V2Z"/></svg>`,
		"too large":    `<svg viewBox="0 0 16 16"><path d="M1 1H2V2Z"/><!--` + strings.Repeat("x", int(MaxFileBytes)) + `--></svg>`,
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := readOne(t, map[string]string{"a.svg": content}, Declaration{Path: "a.svg", Mode: ModeOriginal})
			if !errors.Is(err, ErrRefused) || Reason(err) != "refused" {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestIconsThisHostCannotDraw(t *testing.T) {
	cases := map[string]struct {
		files       map[string]string
		declaration Declaration
	}{
		"png":     {map[string]string{"a.png": "\x89PNG"}, Declaration{Path: "a.png"}},
		"format":  {map[string]string{"a.gif": "GIF89a"}, Declaration{Path: "a.gif"}},
		"mode":    {map[string]string{"a.svg": brand}, Declaration{Path: "a.svg", Mode: "tinted"}},
		"element": {map[string]string{"a.svg": `<svg viewBox="0 0 16 16"><text>A</text></svg>`}, Declaration{Path: "a.svg"}},
		"mixed template": {map[string]string{"a.svg": `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor">
<path d="M1 1H2"/><path fill="#000" d="M3 3H5V5Z"/></svg>`}, Declaration{Path: "a.svg"}},
		"evenodd template": {map[string]string{"a.svg": `<svg viewBox="0 0 16 16"><path fill="#000" fill-rule="evenodd" d="M1 1H15V15H1ZM4 4H12V12H4Z"/></svg>`}, Declaration{Path: "a.svg"}},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := readOne(t, c.files, c.declaration)
			if !errors.Is(err, ErrUnsupported) || Reason(err) != "unsupported_format" {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestIconsOutsideThePackageAreUnreadable(t *testing.T) {
	for _, name := range []string{"missing.svg", "../a.svg", "/a.svg", `icons\a.svg`} {
		_, err := readOne(t, map[string]string{"a.svg": brand}, Declaration{Path: name})
		if !errors.Is(err, ErrUnreadable) || Reason(err) != "unreadable" {
			t.Fatalf("%s: err = %v", name, err)
		}
	}
	dir := writePackage(t, map[string]string{"a.svg": brand})
	if err := os.Symlink(filepath.Join(dir, "a.svg"), filepath.Join(dir, "b.svg")); err != nil {
		t.Skipf("symbolic links are unavailable: %v", err)
	}
	var cache Cache
	if err := cache.Read(pluginID, dir, Declaration{Path: "b.svg"}); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("an icon was read through a link: %v", err)
	}
}

func TestReadReportsAFailureOnceAndRereadsAnUpdatedPackage(t *testing.T) {
	declaration := Declaration{Path: "a.svg", Mode: ModeOriginal}
	broken := writePackage(t, map[string]string{"a.svg": `<svg><script/></svg>`})
	var cache Cache
	if err := cache.Read(pluginID, broken, declaration); err == nil {
		t.Fatal("a refused icon was read")
	}
	if err := cache.Read(pluginID, broken, declaration); err != nil {
		t.Fatalf("the same failure was reported again: %v", err)
	}
	if _, ok := cache.Lookup(pluginID, declaration); ok {
		t.Fatal("a refused icon is drawn")
	}
	updated := writePackage(t, map[string]string{"a.svg": brand})
	if err := cache.Read(pluginID, updated, declaration); err != nil {
		t.Fatal(err)
	}
	if _, ok := cache.Lookup(pluginID, declaration); !ok {
		t.Fatal("the updated package's icon is not drawn")
	}
}

func TestAPackageIconsShareOnePixelBudget(t *testing.T) {
	files := map[string]string{}
	for index := range 5 {
		files[fmt.Sprintf("i%d.svg", index)] = `<svg viewBox="0 0 1024 1024"><path d="M1 1H1000V1000Z"/></svg>`
	}
	dir := writePackage(t, files)
	var cache Cache
	for index := range 4 {
		if err := cache.Read(pluginID, dir, Declaration{Path: fmt.Sprintf("i%d.svg", index)}); err != nil {
			t.Fatalf("icon %d: %v", index, err)
		}
	}
	// The same file named again with another mode costs nothing more.
	if err := cache.Read(pluginID, dir, Declaration{Path: "i0.svg", Mode: ModeOriginal}); err != nil {
		t.Fatalf("a counted file was charged again: %v", err)
	}
	if err := cache.Read(pluginID, dir, Declaration{Path: "i4.svg"}); !errors.Is(err, ErrRefused) {
		t.Fatalf("the fifth 1024×1024 icon was read: %v", err)
	}
	var _ gfx.Icon = Icon{}.For(false)
}
