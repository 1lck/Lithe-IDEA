package appicon

import "testing"

func TestWindowIcon(t *testing.T) {
	icon := Window()
	if icon.Size < 1 || icon.Size > 1024 {
		t.Fatalf("icon size = %d, want a value in 1..1024", icon.Size)
	}
	if got, want := len(icon.RGBA), icon.Size*icon.Size*4; got != want {
		t.Fatalf("RGBA length = %d, want %d for size %d", got, want, icon.Size)
	}
	if icon.Size < 512 {
		t.Fatalf("icon size = %d, want at least 512", icon.Size)
	}
}

func TestWelcomeIconIsRetainedAndPremultiplied(t *testing.T) {
	icon, again := Welcome(), Welcome()
	if icon.Width != 64 || icon.Height != 64 || icon.Stride != 64*4 || len(icon.Pix) != 64*64*4 {
		t.Fatalf("welcome icon has unexpected geometry: %dx%d stride %d, %d bytes", icon.Width, icon.Height, icon.Stride, len(icon.Pix))
	}
	if icon.ID == 0 || icon.ID != again.ID || &icon.Pix[0] != &again.Pix[0] {
		t.Fatal("welcome icon was not retained between calls")
	}
	if icon.Pix[3] != 0 || icon.Pix[(32*64+32)*4+3] == 0 {
		t.Fatal("welcome icon does not have transparent rounded corners and a visible center")
	}
	for i := 0; i < len(icon.Pix); i += 4 {
		alpha := icon.Pix[i+3]
		if icon.Pix[i] > alpha || icon.Pix[i+1] > alpha || icon.Pix[i+2] > alpha {
			t.Fatalf("pixel %d is not premultiplied", i/4)
		}
	}
}
