package term

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
)

// picturePNG encodes a small picture with the given side length.
func picturePNG(t testing.TB, side int) []byte {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			picture.SetNRGBA(x, y, color.NRGBA{uint8(x * 7), uint8(y * 11), uint8(x ^ y), 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, picture); err != nil {
		t.Fatal(err)
	}
	return encoded.Bytes()
}

// TestControlStringsLoadInRuns feeds OSC, DCS and APC payloads in one Write, as
// a big image arrives, and checks each protocol sees the same bytes as when the
// payload is split across writes.
func TestControlStringsLoadInRuns(t *testing.T) {
	inOne := func(name string, sequence string) *Terminal {
		terminal := New(20, 6, 10)
		terminal.Write([]byte(sequence))
		terminal.WaitImages()
		return terminal
	}
	inParts := func(name string, sequence string) *Terminal {
		terminal := New(20, 6, 10)
		for index := 0; index < len(sequence); index += 7 {
			terminal.Write([]byte(sequence[index:min(index+7, len(sequence))]))
		}
		terminal.WaitImages()
		return terminal
	}
	encoded := base64.StdEncoding.EncodeToString(picturePNG(t, 40))
	iterm := "\x1b]1337;File=inline=1:" + encoded + "\x07"
	sixel := "\x1bPq#1;2;100;0;0!40~\x1b\\"
	kitty := "\x1b_Ga=T,f=32,s=2,v=1,c=2,r=1;" + base64.StdEncoding.EncodeToString([]byte{0, 0, 255, 255, 0, 255, 0, 255}) + "\x1b\\"
	for name, sequence := range map[string]string{"iterm": iterm, "sixel": sixel, "kitty": kitty} {
		whole, split := inOne(name, sequence), inParts(name, sequence)
		wholeImages, splitImages := whole.Images(), split.Images()
		if len(wholeImages) != 1 || len(splitImages) != 1 {
			t.Fatalf("%s: whole=%d split=%d placements", name, len(wholeImages), len(splitImages))
		}
		if !bytes.Equal(wholeImages[0].Image.Pix, splitImages[0].Image.Pix) {
			t.Fatalf("%s: pixels differ between one write and split writes", name)
		}
	}
}

// TestOverlongOSCIsIgnoredWhole checks the limit still drops an ordinary OSC
// string longer than maxOSC even when it arrives in one Write.
func TestOverlongOSCIsIgnoredWhole(t *testing.T) {
	terminal := New(20, 6, 0)
	terminal.Write([]byte("\x1b]0;short\x07"))
	if terminal.Title() != "short" {
		t.Fatalf("title = %q", terminal.Title())
	}
	terminal.Write([]byte("\x1b]0;" + strings.Repeat("t", maxOSC+100) + "\x07"))
	if terminal.Title() != "short" {
		t.Fatalf("an overlong OSC changed the title to %q", terminal.Title())
	}
	// The image limit is the exception: a 1337;File= string may be megabytes.
	terminal.Write([]byte("\x1b]0;after\x07"))
	if terminal.Title() != "after" {
		t.Fatalf("title after the overlong string = %q", terminal.Title())
	}
}

// TestControlStringC0BytesStillSeparateRuns checks a C0 byte inside an OSC
// payload is ignored without breaking the payload around it, as it was when
// every byte went through the state machine.
func TestControlStringC0BytesStillSeparateRuns(t *testing.T) {
	terminal := New(20, 6, 0)
	terminal.Write([]byte("\x1b]0;one\x00two\x07"))
	if terminal.Title() != "onetwo" {
		t.Fatalf("title = %q", terminal.Title())
	}
	// CAN/SUB cancel the whole sequence, so the earlier title stands.
	terminal.Write([]byte("\x1b]0;three\x1atail\x07"))
	if terminal.Title() != "onetwo" {
		t.Fatalf("a canceled string changed the title to %q", terminal.Title())
	}
}
