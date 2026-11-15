package term

import "bytes"

type sixelDecoder struct {
	pixels        []byte
	width, height int
	usedWidth     int
	usedHeight    int
	x, y          int
	color         int
	palette       [256][4]byte
}

// sixel handles one DCS sixel sequence. It reports whether it took ownership of
// payload's bytes, which the parser detaches for the decoder.
func (t *Terminal) sixel(payload []byte) bool {
	q := bytes.IndexByte(payload, 'q')
	if q < 0 || q+1 >= len(payload) {
		return false
	}
	lineID, column, placed := t.imageAnchor()
	var placement uint64
	if placed {
		placement, placed = t.reserveImagePlacement(lineID, column, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	}
	job := &imageJob{wake: t.imageWake, size: len(payload) - q - 1, decode: func() imageResult {
		decoder := sixelDecoder{}
		decoder.initPalette()
		data := payload[q+1:]
		if !decoder.decode(data) || decoder.usedWidth == 0 || decoder.usedHeight == 0 {
			return imageResult{err: errSixelImage}
		}
		width, height := decoder.usedWidth, decoder.usedHeight
		pixels := make([]byte, width*height*4)
		for row := 0; row < height; row++ {
			copy(pixels[row*width*4:(row+1)*width*4], decoder.pixels[row*decoder.width*4:row*decoder.width*4+width*4])
		}
		return imageResult{pixels: pixels, width: width, height: height}
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
			p.WidthPixels, p.HeightPixels = result.width, result.height
		})
	}
	t.queueImageJob(job)
	return true
}

func (decoder *sixelDecoder) initPalette() {
	defaults := [...][3]byte{
		{0, 0, 0}, {0, 0, 255}, {255, 0, 0}, {0, 255, 0},
		{255, 0, 255}, {0, 255, 255}, {255, 255, 0}, {255, 255, 255},
		{51, 51, 51}, {51, 51, 255}, {255, 51, 51}, {51, 255, 51},
		{255, 51, 255}, {51, 255, 255}, {255, 255, 51}, {204, 204, 204},
	}
	for index, color := range defaults {
		decoder.palette[index] = [4]byte{color[2], color[1], color[0], 255}
	}
}

func (decoder *sixelDecoder) decode(data []byte) bool {
	for index := 0; index < len(data); {
		value := data[index]
		index++
		switch value {
		case '$':
			decoder.x = 0
		case '-':
			decoder.x, decoder.y = 0, decoder.y+6
			if decoder.y >= maxImageHeight {
				return false
			}
		case '!':
			repeat, next, ok := sixelNumber(data, index)
			if !ok || repeat < 1 || repeat > maxImageWidth || next >= len(data) || data[next] < '?' || data[next] > '~' {
				return false
			}
			index = next + 1
			if !decoder.paint(data[next]-'?', repeat) {
				return false
			}
		case '#':
			register, next, ok := sixelNumber(data, index)
			if !ok || register < 0 || register >= len(decoder.palette) {
				return false
			}
			decoder.color, index = register, next
			if index < len(data) && data[index] == ';' {
				values, count, end := sixelParameters(data, index+1)
				index = end
				if count == 4 && values[0] == 2 {
					red, green, blue := sixelPercent(values[1]), sixelPercent(values[2]), sixelPercent(values[3])
					decoder.palette[register] = [4]byte{blue, green, red, 255}
				}
			}
		case '"':
			values, count, end := sixelParameters(data, index)
			index = end
			if count >= 4 && values[2] > 0 && values[3] > 0 {
				if values[2] > maxImageWidth || values[3] > maxImageHeight || values[2] > maxImagePixels/values[3] || !decoder.grow(values[2], values[3]) {
					return false
				}
			}
		default:
			if value >= '?' && value <= '~' && !decoder.paint(value-'?', 1) {
				return false
			}
		}
	}
	return true
}

func (decoder *sixelDecoder) paint(pattern byte, repeat int) bool {
	if decoder.x > maxImageWidth-repeat || !decoder.grow(decoder.x+repeat, decoder.y+6) {
		return false
	}
	color := decoder.palette[decoder.color]
	for count := 0; count < repeat; count++ {
		for bit := 0; bit < 6; bit++ {
			if pattern&(1<<bit) == 0 {
				continue
			}
			offset := ((decoder.y+bit)*decoder.width + decoder.x) * 4
			copy(decoder.pixels[offset:offset+4], color[:])
			decoder.usedHeight = max(decoder.usedHeight, decoder.y+bit+1)
		}
		decoder.x++
	}
	decoder.usedWidth = max(decoder.usedWidth, decoder.x)
	return true
}

func (decoder *sixelDecoder) grow(width, height int) bool {
	if width < 1 || height < 1 || width > maxImageWidth || height > maxImageHeight || width > maxImagePixels/height {
		return false
	}
	if width <= decoder.width && height <= decoder.height {
		return true
	}
	nextWidth, nextHeight := max(decoder.width, 64), max(decoder.height, 6)
	for nextWidth < width {
		nextWidth = min(nextWidth*2, maxImageWidth)
	}
	for nextHeight < height {
		nextHeight = min(nextHeight*2, maxImageHeight)
	}
	if nextWidth > maxImagePixels/nextHeight {
		nextWidth = width
		nextHeight = height
		if nextWidth > maxImagePixels/nextHeight {
			return false
		}
	}
	next := make([]byte, nextWidth*nextHeight*4)
	for row := 0; row < decoder.height; row++ {
		copy(next[row*nextWidth*4:row*nextWidth*4+decoder.width*4], decoder.pixels[row*decoder.width*4:(row+1)*decoder.width*4])
	}
	decoder.pixels, decoder.width, decoder.height = next, nextWidth, nextHeight
	return true
}

func sixelNumber(data []byte, index int) (int, int, bool) {
	start, value := index, 0
	for index < len(data) && data[index] >= '0' && data[index] <= '9' {
		if value > maxImagePixels {
			return 0, index, false
		}
		value = value*10 + int(data[index]-'0')
		index++
	}
	return value, index, index > start
}

func sixelParameters(data []byte, index int) ([4]int, int, int) {
	var values [4]int
	count := 0
	for count < len(values) && index < len(data) {
		value, next, ok := sixelNumber(data, index)
		if !ok {
			break
		}
		values[count] = value
		count++
		index = next
		if index >= len(data) || data[index] != ';' {
			break
		}
		index++
	}
	return values, count, index
}

func sixelPercent(value int) byte {
	return byte(clampInt(value, 0, 100) * 255 / 100)
}
