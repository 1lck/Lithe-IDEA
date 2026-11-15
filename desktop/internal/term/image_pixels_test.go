package term

import (
	"bytes"
	"image"
	"image/color"
	"testing"
)

// referencePixels is the conversion the terminal used before the type switch:
// every pixel through image.Image.At, then premultiplied BGRA.
func referencePixels(source image.Image) []byte {
	bounds := source.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	out := make([]byte, width*height*4)
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			red, green, blue, alpha := source.At(bounds.Min.X+x, bounds.Min.Y+y).RGBA()
			offset := (y*width + x) * 4
			out[offset], out[offset+1], out[offset+2], out[offset+3] = byte(blue>>8), byte(green>>8), byte(red>>8), byte(alpha>>8)
		}
	}
	return out
}

// TestImagePixelsMatchesTheGenericConversion keeps the direct per-format copies
// byte-identical to the generic pixel-by-pixel conversion, including alpha,
// odd strides and sub-images whose origin is not zero.
func TestImagePixelsMatchesTheGenericConversion(t *testing.T) {
	for _, size := range [][2]int{{1, 1}, {13, 11}, {64, 33}} {
		width, height := size[0], size[1]
		rect := image.Rect(5, 7, 5+width, 7+height)

		rgba := image.NewRGBA(rect)
		nrgba := image.NewNRGBA(rect)
		gray := image.NewGray(rect)
		gray16 := image.NewGray16(rect)
		paletted := image.NewPaletted(rect, color.Palette{
			color.RGBA{0, 0, 0, 255}, color.RGBA{10, 200, 30, 255}, color.NRGBA{200, 40, 90, 128},
		})
		ycbcr := map[image.YCbCrSubsampleRatio]*image.YCbCr{}
		for _, ratio := range []image.YCbCrSubsampleRatio{
			image.YCbCrSubsampleRatio444, image.YCbCrSubsampleRatio422,
			image.YCbCrSubsampleRatio420, image.YCbCrSubsampleRatio440,
		} {
			ycbcr[ratio] = image.NewYCbCr(rect, ratio)
		}
		for y := rect.Min.Y; y < rect.Max.Y; y++ {
			for x := rect.Min.X; x < rect.Max.X; x++ {
				r, g, b := uint8(x*13+y*7), uint8(x*3+y*29), uint8(x*17+y*5)
				a := uint8(x*11 + y*23)
				rgba.SetRGBA(x, y, color.RGBA{r, g, b, a})
				nrgba.SetNRGBA(x, y, color.NRGBA{r, g, b, a})
				gray.SetGray(x, y, color.Gray{uint8(x*9 + y*3)})
				gray16.SetGray16(x, y, color.Gray16{uint16(x)*257 + uint16(y)*13})
				paletted.SetColorIndex(x, y, uint8((x+y)%len(paletted.Palette)))
				for _, plane := range ycbcr {
					luma := plane.YOffset(x, y)
					chroma := plane.COffset(x, y)
					plane.Y[luma] = uint8(x*5 + y*3)
					plane.Cb[chroma] = uint8(x*7 + y*11)
					plane.Cr[chroma] = uint8(x*13 + y*2)
				}
			}
		}

		cases := map[string]image.Image{
			"rgba":    rgba,
			"nrgba":   nrgba,
			"gray":    gray,
			"gray16":  gray16,
			"palette": paletted,
		}
		for ratio, source := range ycbcr {
			cases["ycbcr-"+ratio.String()] = source
		}
		for name, source := range cases {
			bounds := source.Bounds()
			want := referencePixels(source)
			got := imagePixels(source, bounds.Dx(), bounds.Dy())
			if len(got) != len(want) {
				t.Fatalf("%s %dx%d: got %d bytes, want %d", name, width, height, len(got), len(want))
			}
			for index := range want {
				if got[index] != want[index] {
					t.Fatalf("%s %dx%d: byte %d = %d, want %d", name, width, height, index, got[index], want[index])
				}
			}
			for _, sub := range []image.Image{
				source,
				subImage(source, image.Rect(bounds.Min.X+1, bounds.Min.Y+1, bounds.Max.X-1, bounds.Max.Y-1)),
			} {
				if sub == nil {
					continue
				}
				sb := sub.Bounds()
				if sb.Dx() <= 0 || sb.Dy() <= 0 {
					continue
				}
				want := referencePixels(sub)
				got := imagePixels(sub, sb.Dx(), sb.Dy())
				if !bytes.Equal(got, want) {
					t.Fatalf("%s sub-image %v: conversion differs", name, sb)
				}
			}
		}
	}
}

// subImage crops img, keeping its concrete type so the test exercises the fast
// path on a picture whose origin is not zero.
func subImage(img image.Image, rect image.Rectangle) image.Image {
	type subImager interface {
		SubImage(image.Rectangle) image.Image
	}
	if sub, ok := img.(subImager); ok {
		if rect.Dx() <= 0 || rect.Dy() <= 0 {
			return nil
		}
		return sub.SubImage(rect)
	}
	return nil
}

// TestImagePixelsDoesNotAllocatePerPixel guards the fast paths: only the output
// buffer may be allocated, no matter the pixel count.
func TestImagePixelsDoesNotAllocatePerPixel(t *testing.T) {
	for _, source := range []image.Image{
		image.NewRGBA(image.Rect(0, 0, 64, 64)),
		image.NewNRGBA(image.Rect(0, 0, 64, 64)),
		image.NewYCbCr(image.Rect(0, 0, 64, 64), image.YCbCrSubsampleRatio420),
		image.NewGray(image.Rect(0, 0, 64, 64)),
	} {
		bounds := source.Bounds()
		allocs := testing.AllocsPerRun(20, func() {
			imagePixels(source, bounds.Dx(), bounds.Dy())
		})
		if allocs > 1 {
			t.Fatalf("%T: %v allocs per call, want at most 1 (the output)", source, allocs)
		}
	}
}
