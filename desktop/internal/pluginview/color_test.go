package pluginview

import (
	"encoding/json"
	"testing"

	"github.com/vivaui/viva/gfx"
)

// testPalette has one distinct color per token, so a test can tell which token resolved.
func testPalette(dark bool) Palette {
	return Palette{
		Dark: dark, Text: gfx.RGBA(1, 0, 0, 1), TextSecondary: gfx.RGBA(2, 0, 0, 1), TextMuted: gfx.RGBA(3, 0, 0, 1),
		Accent: gfx.RGBA(4, 0, 0, 1), Success: gfx.RGBA(5, 0, 0, 1), Warning: gfx.RGBA(6, 0, 0, 1), Error: gfx.RGBA(7, 0, 0, 1),
		Surface: gfx.RGBA(8, 0, 0, 1), Background: gfx.RGBA(9, 0, 0, 1), Sidebar: gfx.RGBA(10, 0, 0, 1), Line: gfx.RGBA(11, 0, 0, 1),
		Hover: gfx.RGBA(12, 0, 0, 1), Selection: gfx.RGBA(13, 0, 0, 1), Badge: gfx.RGBA(14, 0, 0, 1),
	}
}

func TestPalettePlainReadsHexAndTokens(t *testing.T) {
	p := testPalette(false)
	for _, tc := range []struct {
		value string
		want  gfx.Color
		ok    bool
	}{
		{"#112233", gfx.RGBA(0x11, 0x22, 0x33, 1), true},
		{"#11223380", gfx.RGBA(0x11, 0x22, 0x33, float32(0x80)/255), true},
		{"#ABCDEF", gfx.RGBA(0xab, 0xcd, 0xef, 1), true},
		{"$accent", p.Accent, true},
		{"$badge", p.Badge, true},
		{"$popover", gfx.Color{}, false},
		{"$", gfx.Color{}, false},
		{"#12345", gfx.Color{}, false},
		{"#GG2233", gfx.Color{}, false},
		{"112233", gfx.Color{}, false},
		{"red", gfx.Color{}, false},
		{"", gfx.Color{}, false},
	} {
		got, ok := p.plain(tc.value)
		if ok != tc.ok || got != tc.want {
			t.Errorf("plain(%q) = %v, %v; want %v, %v", tc.value, got, ok, tc.want, tc.ok)
		}
	}
}

func TestPaletteSolidPicksTheThemeSideAndTheFirstStop(t *testing.T) {
	pair := &Color{Light: "#ffffff", Dark: "$surface"}
	light, dark := testPalette(false), testPalette(true)
	if got, ok := light.Solid(pair); !ok || got != gfx.RGBA(255, 255, 255, 1) {
		t.Errorf("light side = %v, %v", got, ok)
	}
	if got, ok := dark.Solid(pair); !ok || got != dark.Surface {
		t.Errorf("dark side = %v, %v", got, ok)
	}
	gradient := &Color{Stops: []Stop{{At: 0, Color: "$success"}, {At: 1, Color: "#000000"}}}
	if got, ok := light.Solid(gradient); !ok || got != light.Success {
		t.Errorf("gradient's solid = %v, %v, want its first stop", got, ok)
	}
	if got, ok := light.Solid(&Color{Plain: "$line"}); !ok || got != light.Line {
		t.Errorf("plain = %v, %v", got, ok)
	}
	if _, ok := light.Solid(nil); ok {
		t.Error("a missing color resolved")
	}
	if _, ok := light.Solid(&Color{Dark: "#000000"}); ok {
		t.Error("a pair without a light side resolved in the light theme")
	}
}

func TestPaletteStopsFadeAndRefuseAnUnreadableStop(t *testing.T) {
	p := testPalette(false)
	gradient := &Color{Stops: []Stop{{At: 0, Color: "#ff0000"}, {At: 0.5, Color: "#00ff0080"}, {At: 1, Color: "$accent"}}}
	stops := p.Stops(gradient, 0.5)
	if len(stops) != 3 {
		t.Fatalf("stops = %v", stops)
	}
	want := []gfx.GradientStop{
		gfx.Stop(0, gfx.RGBA(255, 0, 0, 0.5)),
		gfx.Stop(0.5, gfx.RGBA(0, 255, 0, float32(0x80)/255*0.5)),
		gfx.Stop(1, p.Accent.WithAlpha(0.5)),
	}
	for i := range want {
		if stops[i] != want[i] {
			t.Errorf("stop %d = %v, want %v", i, stops[i], want[i])
		}
	}
	if p.Stops(&Color{Stops: []Stop{{At: 0, Color: "#ff0000"}}}, 1) != nil {
		t.Error("one stop made a gradient")
	}
	if p.Stops(&Color{Stops: []Stop{{At: 0, Color: "#ff0000"}, {At: 1, Color: "blue"}}}, 1) != nil {
		t.Error("a gradient with an unreadable stop was drawn")
	}
	if p.Stops(&Color{Plain: "#ff0000"}, 1) != nil {
		t.Error("a plain color made a gradient")
	}
}

func TestPaletteToneFallsBackForNoTone(t *testing.T) {
	p := testPalette(false)
	if got := p.Tone("warning", p.Text); got != p.Warning {
		t.Errorf("warning tone = %v", got)
	}
	if got := p.Tone("", p.Line); got != p.Line {
		t.Errorf("no tone = %v, want the fallback", got)
	}
	if got := p.Tone("primary", p.Text); got != p.Text {
		t.Errorf("a control-only tone = %v, want the fallback", got)
	}
}

func TestFadeKeepsOpaqueAndClampsBelowZero(t *testing.T) {
	color := gfx.RGBA(10, 20, 30, 0.8)
	if fade(color, 1) != color || fade(color, 2) != color {
		t.Error("an opacity of 1 or more changed the color")
	}
	if got := fade(color, -1); got.Alpha != 0 {
		t.Errorf("a negative opacity left alpha %v", got.Alpha)
	}
}

func TestColorUnmarshalReadsTheThreeForms(t *testing.T) {
	var colors struct {
		Plain    Color `json:"plain"`
		Pair     Color `json:"pair"`
		Down     Color `json:"down"`
		Sideways Color `json:"sideways"`
	}
	data := `{
		"plain": "$accent",
		"pair": {"light": "#ffffff", "dark": "#000000"},
		"down": {"linear": [[0, "#ff0000"], [1, "$accent"]]},
		"sideways": {"linear": [[0, "#ff0000"], [0.4, "#00ff00"], [1, "#0000ff"]], "angle": 90}
	}`
	if err := json.Unmarshal([]byte(data), &colors); err != nil {
		t.Fatal(err)
	}
	if colors.Plain.Plain != "$accent" {
		t.Errorf("plain = %+v", colors.Plain)
	}
	if colors.Pair.Light != "#ffffff" || colors.Pair.Dark != "#000000" {
		t.Errorf("pair = %+v", colors.Pair)
	}
	if colors.Down.Angle != 180 || len(colors.Down.Stops) != 2 || colors.Down.Stops[1] != (Stop{At: 1, Color: "$accent"}) {
		t.Errorf("gradient without an angle = %+v, want top to bottom", colors.Down)
	}
	if colors.Sideways.Angle != 90 || len(colors.Sideways.Stops) != 3 || colors.Sideways.Stops[1].At != 0.4 {
		t.Errorf("gradient with an angle = %+v", colors.Sideways)
	}
	var bad Color
	if err := json.Unmarshal([]byte(`{"linear": [["start", "#ff0000"]]}`), &bad); err == nil {
		t.Error("a stop offset that is not a number was read")
	}
}
