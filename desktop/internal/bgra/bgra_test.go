package bgra

import (
	"bytes"
	"image"
	"image/color"
	"testing"
)

func TestBitmapIsPremultipliedBGRAFromTheImageOrigin(t *testing.T) {
	whole := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	whole.SetNRGBA(1, 1, color.NRGBA{R: 255, G: 64, A: 128})
	whole.SetNRGBA(2, 1, color.NRGBA{B: 200, A: 255})
	// A part of an image whose bounds do not start at the origin.
	part := whole.SubImage(image.Rect(1, 1, 3, 2))
	bitmap := Bitmap(part, 42)
	if bitmap.Width != 2 || bitmap.Height != 1 || bitmap.Stride != 8 || bitmap.ID != 42 || bitmap.Version != 1 {
		t.Fatalf("bitmap = %dx%d stride %d id %d version %d", bitmap.Width, bitmap.Height, bitmap.Stride, bitmap.ID, bitmap.Version)
	}
	want := []byte{0, 32, 128, 128, 200, 0, 0, 255}
	if !bytes.Equal(bitmap.Pix, want) {
		t.Fatalf("pixels = %v, want %v", bitmap.Pix, want)
	}
}
