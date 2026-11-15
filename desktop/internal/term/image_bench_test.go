package term

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strconv"
	"testing"
)

// encodedPicture builds an image whose pixels defeat PNG and JPEG compression,
// which is the slow case for the decoder, at the given side length.
func encodedPicture(b *testing.B, side int, format string) []byte {
	b.Helper()
	source := image.NewNRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			source.SetNRGBA(x, y, color.NRGBA{uint8(x * 13), uint8(y * 7), uint8(x ^ y), 255})
		}
	}
	var encoded bytes.Buffer
	var err error
	switch format {
	case "png":
		err = png.Encode(&encoded, source)
	case "jpeg":
		err = jpeg.Encode(&encoded, source, &jpeg.Options{Quality: 92})
	}
	if err != nil {
		b.Fatal(err)
	}
	return encoded.Bytes()
}

// BenchmarkDecodeImage measures the whole inline-image path: decode plus the
// conversion to the terminal's premultiplied BGRA pixels.
func BenchmarkDecodeImage(b *testing.B) {
	for _, format := range []string{"png", "jpeg"} {
		for _, side := range []int{1024, 2048} {
			data := encodedPicture(b, side, format)
			b.Run(format+"/"+strconv.Itoa(side), func(b *testing.B) {
				b.SetBytes(int64(len(data)))
				b.ReportAllocs()
				for b.Loop() {
					if _, _, _, err := decodeImage(data); err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
