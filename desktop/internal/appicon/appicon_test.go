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
