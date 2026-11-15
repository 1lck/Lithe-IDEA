package term

import (
	"bytes"
	"strconv"
	"strings"
)

type itermDimension struct {
	value int
	cells bool
}

// itermImage handles one iTerm2 inline-image sequence. It reports whether it
// took ownership of payload's bytes: the parser detaches them for the decoder
// instead of copying a picture that can be megabytes.
func (t *Terminal) itermImage(payload []byte) bool {
	if !bytes.HasPrefix(payload, []byte("File=")) {
		return false
	}
	separator := bytes.IndexByte(payload, ':')
	if separator < 0 {
		return false
	}
	metadata, encoded := payload[len("File="):separator], payload[separator+1:]
	inline := false
	preserveAspect := true
	declaredSize := -1
	var width, height itermDimension
	for len(metadata) > 0 {
		field := metadata
		if semicolon := bytes.IndexByte(metadata, ';'); semicolon >= 0 {
			field, metadata = metadata[:semicolon], metadata[semicolon+1:]
		} else {
			metadata = nil
		}
		key, value, ok := bytes.Cut(field, []byte{'='})
		if !ok {
			continue
		}
		switch string(key) {
		case "inline":
			inline = bytes.Equal(value, []byte{'1'})
		case "preserveAspectRatio":
			preserveAspect = !bytes.Equal(value, []byte{'0'})
		case "size":
			if parsed, err := strconv.Atoi(string(value)); err == nil && parsed >= 0 && parsed <= maxImageBytes {
				declaredSize = parsed
			} else {
				return false
			}
		case "width":
			width = parseItermDimension(value)
		case "height":
			height = parseItermDimension(value)
		}
	}
	if !inline {
		return false
	}
	lineID, column, placed := t.imageAnchor()
	var placement uint64
	if placed {
		// Reserve the place now: an erase or resize between these bytes and the
		// decode must see the image, as it did when decoding was synchronous.
		rawCells, rawRows, rawPixels, rawPixelsH := itermSize(width, height)
		placement, placed = t.reserveImagePlacement(lineID, column, 0, 0, 0, 0, rawCells, rawRows, rawPixels, rawPixelsH, 0, 0)
	}
	job := &imageJob{wake: t.imageWake, size: len(encoded), decode: func() imageResult {
		compressed, err := decodeBase64Image(encoded)
		if err != nil {
			return imageResult{err: err}
		}
		if declaredSize >= 0 && declaredSize != len(compressed) {
			return imageResult{err: errImageSizeMismatch}
		}
		pixels, pixelWidth, pixelHeight, err := decodeImage(compressed)
		return imageResult{pixels: pixels, width: pixelWidth, height: pixelHeight, err: err}
	}}
	job.apply = func(t *Terminal, result imageResult) {
		if result.err != nil || result.pixels == nil {
			if placed {
				t.dropImagePlacement(placement)
			}
			return
		}
		image := t.acceptImage(result.pixels, result.width, result.height, 0)
		if image == nil {
			if placed {
				t.dropImagePlacement(placement)
			}
			return
		}
		if !placed {
			return
		}
		t.attachImagePlacement(placement, image, func(p *ImagePlacement) {
			p.WidthCells, p.HeightCells, p.WidthPixels, p.HeightPixels = itermPlacement(width, height, preserveAspect, result.width, result.height)
		})
	}
	t.queueImageJob(job)
	return true
}

// itermSize is the display size the width and height fields name before the
// decoded dimensions are known.
func itermSize(width, height itermDimension) (widthCells, heightCells, widthPixels, heightPixels int) {
	if width.cells {
		widthCells = width.value
	} else {
		widthPixels = width.value
	}
	if height.cells {
		heightCells = height.value
	} else {
		heightPixels = height.value
	}
	return widthCells, heightCells, widthPixels, heightPixels
}

// itermPlacement turns the width/height fields of an iTerm2 image into cells
// and pixels, honoring the requested aspect ratio.
func itermPlacement(width, height itermDimension, preserveAspect bool, pixelWidth, pixelHeight int) (widthCells, heightCells, widthPixels, heightPixels int) {
	if width.cells {
		widthCells = width.value
	} else {
		widthPixels = width.value
	}
	if height.cells {
		heightCells = height.value
	} else {
		heightPixels = height.value
	}
	if preserveAspect {
		switch {
		case widthCells > 0 && heightCells == 0 && heightPixels == 0:
			heightCells = 0
		case heightCells > 0 && widthCells == 0 && widthPixels == 0:
			widthCells = 0
		case widthPixels > 0 && heightPixels == 0 && heightCells == 0:
			heightPixels = max(1, widthPixels*pixelHeight/pixelWidth)
		case heightPixels > 0 && widthPixels == 0 && widthCells == 0:
			widthPixels = max(1, heightPixels*pixelWidth/pixelHeight)
		}
	}
	return widthCells, heightCells, widthPixels, heightPixels
}

func parseItermDimension(value []byte) itermDimension {
	text := string(value)
	if text == "" || text == "auto" || strings.HasSuffix(text, "%") {
		return itermDimension{}
	}
	cells := true
	if strings.HasSuffix(text, "px") {
		cells = false
		text = strings.TrimSuffix(text, "px")
	}
	number, err := strconv.Atoi(text)
	if err != nil || number < 1 {
		return itermDimension{}
	}
	if cells {
		number = min(number, maxCols)
	} else {
		number = min(number, maxImageWidth)
	}
	return itermDimension{value: number, cells: cells}
}
