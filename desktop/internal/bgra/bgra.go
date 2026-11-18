// Package bgra converts decoded images to the bitmaps Viva's canvas draws.
package bgra

import (
	"image"
	"image/draw"

	"github.com/vivaui/viva/gfx"
)

// Bitmap converts an image to the canvas's premultiplied BGRA. id names the bitmap to the
// canvas, which keeps one texture per id and version.
func Bitmap(decoded image.Image, id uint64) gfx.Bitmap {
	bounds := decoded.Bounds()
	rgba := image.NewRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
	draw.Draw(rgba, rgba.Bounds(), decoded, bounds.Min, draw.Src)
	// image.RGBA is premultiplied RGBA; the canvas takes premultiplied BGRA.
	pix := rgba.Pix
	for i := 0; i+3 < len(pix); i += 4 {
		pix[i], pix[i+2] = pix[i+2], pix[i]
	}
	return gfx.Bitmap{Pix: pix, Width: rgba.Rect.Dx(), Height: rgba.Rect.Dy(), Stride: rgba.Stride, ID: id, Version: 1}
}
