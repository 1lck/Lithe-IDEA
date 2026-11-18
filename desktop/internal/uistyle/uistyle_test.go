package uistyle

import (
	"testing"

	"github.com/vivaui/viva/gfx"
)

// Both looks draw a dark tip with light text and no border: a white tip on a white panel
// needs an outline to stand apart, and the light look's IDEA tooltip is dark.
func TestTooltipIsADarkTipWithLightTextInBothLooks(t *testing.T) {
	for _, dark := range []bool{false, true} {
		style := Tooltip(dark)
		if luminance(style.Background) >= luminance(style.Text) {
			t.Errorf("dark=%v: tip body %v is not darker than its text %v", dark, style.Background, style.Text)
		}
		if luminance(style.Background) > 0.25 {
			t.Errorf("dark=%v: tip body %v is not a dark surface", dark, style.Background)
		}
		if style.BorderSize != 0 {
			t.Errorf("dark=%v: tip draws a %v point border, want none", dark, style.BorderSize)
		}
		if style.FontSize != 12 || style.Radius != 4 || style.PadX != 12 || style.PadY != 6 {
			t.Errorf("dark=%v: tip metrics %+v, want twelve point text, a four point corner and 12×6 padding", dark, style)
		}
	}
	if Tooltip(false).Background != gfx.RGB24(0x27282E) || Tooltip(true).Background != gfx.RGB24(0x33353B) {
		t.Errorf("tip bodies %v and %v, want IDEA's light #27282E and the dark look's #33353B", Tooltip(false).Background, Tooltip(true).Background)
	}
}

func luminance(color gfx.Color) float32 {
	return 0.2126*color.Red + 0.7152*color.Green + 0.0722*color.Blue
}
