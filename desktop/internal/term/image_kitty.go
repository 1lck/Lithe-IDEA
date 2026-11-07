package term

import (
	"bytes"
	"fmt"
	"strconv"
)

type kittyParams struct {
	action       byte
	medium       byte
	compression  byte
	format       int
	width        int
	height       int
	imageID      uint32
	placementID  uint32
	columns      int
	rows         int
	sourceX      int
	sourceY      int
	sourceWidth  int
	sourceHeight int
	z            int32
	more         bool
	quiet        int
	delete       byte
	present      uint32
}

const (
	kittyAction uint32 = 1 << iota
	kittyMedium
	kittyCompression
	kittyFormat
	kittyWidth
	kittyHeight
	kittyImageID
	kittyPlacementID
	kittyColumns
	kittyRows
	kittySourceX
	kittySourceY
	kittySourceWidth
	kittySourceHeight
	kittyZ
	kittyMore
	kittyQuiet
	kittyDelete
)

type kittyTransfer struct {
	params kittyParams
	data   []byte
}

func (t *Terminal) kittyGraphics(payload []byte) {
	if len(payload) < 2 || payload[0] != 'G' {
		return
	}
	separator := bytes.IndexByte(payload, ';')
	control, encoded := payload[1:], []byte(nil)
	if separator >= 0 {
		control, encoded = payload[1:separator], payload[separator+1:]
	}
	params, ok := parseKittyParams(control)
	if !ok {
		t.replyKitty(params, "EINVAL:invalid control data")
		t.kitty = nil
		return
	}
	if t.kitty != nil {
		transfer := t.kitty
		if !kittyContinuationMatches(transfer.params, params) {
			t.replyKitty(transfer.params, "EINVAL:conflicting continuation control")
			t.kitty = nil
			return
		}
	} else {
		// A delete or a placement of an earlier image is applied in turn with
		// the decodes before it: the image it names may still be decoding.
		lineID, column, placed := t.imageAnchor()
		if params.action == 'd' {
			t.queueImageJob(&imageJob{wake: t.imageWake, apply: func(t *Terminal, _ imageResult) {
				t.deleteKitty(params)
				t.replyKitty(params, "OK")
			}})
			return
		}
		if params.action == 'p' {
			var placement uint64
			if placed {
				placement, placed = t.reserveKittyPlacement(params, lineID, column)
			}
			t.queueImageJob(&imageJob{wake: t.imageWake, apply: func(t *Terminal, _ imageResult) {
				image := t.findKittyImage(params.imageID)
				if image == nil {
					if placed {
						t.dropImagePlacement(placement)
					}
					t.replyKitty(params, "ENOENT:image not found")
					return
				}
				if placed {
					t.attachImagePlacement(placement, image, nil)
				}
				t.replyKitty(params, "OK")
			}})
			return
		}
		if params.action == 'q' {
			// The reply goes out with the earlier images so the answers stay in
			// the order the commands arrived.
			status := "EINVAL:unsupported format"
			if params.format == 0 || params.format == 24 || params.format == 32 || params.format == 100 {
				status = "OK"
			}
			t.queueImageJob(&imageJob{wake: t.imageWake, apply: func(t *Terminal, _ imageResult) {
				t.replyKitty(params, status)
			}})
			return
		}
	}
	if params.medium != 0 && params.medium != 'd' {
		t.replyKitty(params, "EINVAL:only direct transmission is accepted")
		return
	}
	chunk, err := decodeBase64Image(encoded)
	if err != nil {
		t.replyKitty(params, "EINVAL:invalid base64")
		t.kitty = nil
		return
	}
	if t.kitty != nil {
		transfer := t.kitty
		if len(transfer.data)+len(chunk) > maxImageBytes {
			t.replyKitty(transfer.params, "EFBIG:image payload exceeds limit")
			t.kitty = nil
			return
		}
		transfer.data = append(transfer.data, chunk...)
		if params.more {
			return
		}
		params = transfer.params
		chunk = transfer.data
		t.kitty = nil
	} else if params.more {
		t.kitty = &kittyTransfer{params: params, data: append([]byte(nil), chunk...)}
		return
	}
	lineID, column, anchored := t.imageAnchor()
	var placement uint64
	placed := false
	if anchored && params.action == 'T' {
		placement, placed = t.reserveKittyPlacement(params, lineID, column)
	}
	transfer := params
	job := &imageJob{wake: t.imageWake, size: len(chunk), decode: func() imageResult {
		data := chunk
		if transfer.compression == 'z' {
			inflated, err := inflateImage(data)
			if err != nil {
				return imageResult{err: err, status: "EINVAL:invalid compressed payload"}
			}
			data = inflated
		} else if transfer.compression != 0 {
			return imageResult{err: errKittyCompression, status: "EINVAL:unsupported compression"}
		}
		pixels, width, height, err := decodeKittyPayload(data, transfer)
		if err != nil {
			return imageResult{err: err, status: "EINVAL:" + err.Error()}
		}
		return imageResult{pixels: pixels, width: width, height: height}
	}}
	job.apply = func(t *Terminal, result imageResult) {
		if result.err != nil {
			if placed {
				t.dropImagePlacement(placement)
			}
			t.replyKitty(transfer, result.status)
			return
		}
		image := t.acceptImage(result.pixels, result.width, result.height, transfer.imageID)
		if image == nil {
			if placed {
				t.dropImagePlacement(placement)
			}
			t.replyKitty(transfer, "ENOMEM:image limits exceeded")
			return
		}
		image.kitty = true
		if placed {
			t.attachImagePlacement(placement, image, nil)
		}
		t.replyKitty(transfer, "OK")
	}
	t.queueImageJob(job)
}

func parseKittyParams(control []byte) (kittyParams, bool) {
	params := kittyParams{action: 't', medium: 'd', format: 32}
	if len(control) == 0 {
		return params, true
	}
	for len(control) > 0 {
		field := control
		if comma := bytes.IndexByte(control, ','); comma >= 0 {
			field, control = control[:comma], control[comma+1:]
		} else {
			control = nil
		}
		if len(field) < 3 || field[1] != '=' {
			return params, false
		}
		key, value := field[0], field[2:]
		number := func() (int, bool) {
			if len(value) == 0 || len(value) > 11 {
				return 0, false
			}
			parsed, err := strconv.ParseInt(string(value), 10, 32)
			return int(parsed), err == nil
		}
		switch key {
		case 'a':
			if len(value) != 1 || !bytes.ContainsRune([]byte("tTpqd"), rune(value[0])) {
				return params, false
			}
			params.action = value[0]
			params.present |= kittyAction
		case 't':
			if len(value) != 1 {
				return params, false
			}
			params.medium = value[0]
			params.present |= kittyMedium
		case 'o':
			if len(value) != 1 {
				return params, false
			}
			params.compression = value[0]
			params.present |= kittyCompression
		case 'd':
			if len(value) != 1 {
				return params, false
			}
			params.delete = value[0]
			params.present |= kittyDelete
		case 'f', 's', 'v', 'i', 'p', 'c', 'r', 'X', 'Y', 'w', 'h', 'z', 'm', 'q':
			n, valid := number()
			if !valid || key != 'z' && n < 0 {
				return params, false
			}
			switch key {
			case 'f':
				params.format = n
				params.present |= kittyFormat
			case 's':
				params.width = n
				params.present |= kittyWidth
			case 'v':
				params.height = n
				params.present |= kittyHeight
			case 'i':
				params.imageID = uint32(n)
				params.present |= kittyImageID
			case 'p':
				params.placementID = uint32(n)
				params.present |= kittyPlacementID
			case 'c':
				params.columns = n
				params.present |= kittyColumns
			case 'r':
				params.rows = n
				params.present |= kittyRows
			case 'X':
				params.sourceX = n
				params.present |= kittySourceX
			case 'Y':
				params.sourceY = n
				params.present |= kittySourceY
			case 'w':
				params.sourceWidth = n
				params.present |= kittySourceWidth
			case 'h':
				params.sourceHeight = n
				params.present |= kittySourceHeight
			case 'z':
				params.z = int32(n)
				params.present |= kittyZ
			case 'm':
				if n != 0 && n != 1 {
					return params, false
				}
				params.more = n == 1
				params.present |= kittyMore
			case 'q':
				if n < 0 || n > 2 {
					return params, false
				}
				params.quiet = n
				params.present |= kittyQuiet
			}
		default:
			// Unknown keys are ignored as the Kitty protocol requires.
		}
	}
	return params, true
}

func kittyContinuationMatches(first, next kittyParams) bool {
	if next.present&kittyAction != 0 && next.action != first.action ||
		next.present&kittyMedium != 0 && next.medium != first.medium ||
		next.present&kittyCompression != 0 && next.compression != first.compression ||
		next.present&kittyFormat != 0 && next.format != first.format ||
		next.present&kittyWidth != 0 && next.width != first.width ||
		next.present&kittyHeight != 0 && next.height != first.height ||
		next.present&kittyImageID != 0 && next.imageID != first.imageID ||
		next.present&kittyPlacementID != 0 && next.placementID != first.placementID ||
		next.present&kittyColumns != 0 && next.columns != first.columns ||
		next.present&kittyRows != 0 && next.rows != first.rows ||
		next.present&kittySourceX != 0 && next.sourceX != first.sourceX ||
		next.present&kittySourceY != 0 && next.sourceY != first.sourceY ||
		next.present&kittySourceWidth != 0 && next.sourceWidth != first.sourceWidth ||
		next.present&kittySourceHeight != 0 && next.sourceHeight != first.sourceHeight ||
		next.present&kittyZ != 0 && next.z != first.z {
		return false
	}
	return true
}

func decodeKittyPayload(data []byte, params kittyParams) ([]byte, int, int, error) {
	switch params.format {
	case 100:
		return decodeImage(data)
	case 24, 32:
		if params.width < 1 || params.height < 1 || params.width > maxImageWidth || params.height > maxImageHeight || params.width > maxImagePixels/params.height {
			return nil, 0, 0, fmt.Errorf("invalid raw dimensions")
		}
		channels := params.format / 8
		expected := params.width * params.height * channels
		if len(data) != expected {
			return nil, 0, 0, fmt.Errorf("raw payload length mismatch")
		}
		pixels := make([]byte, params.width*params.height*4)
		for source, target := 0, 0; source < len(data); source, target = source+channels, target+4 {
			red, green, blue, alpha := data[source], data[source+1], data[source+2], byte(255)
			if channels == 4 {
				alpha = data[source+3]
				red = byte(uint16(red) * uint16(alpha) / 255)
				green = byte(uint16(green) * uint16(alpha) / 255)
				blue = byte(uint16(blue) * uint16(alpha) / 255)
			}
			pixels[target], pixels[target+1], pixels[target+2], pixels[target+3] = blue, green, red, alpha
		}
		return pixels, params.width, params.height, nil
	default:
		return nil, 0, 0, fmt.Errorf("unsupported format")
	}
}

// reserveKittyPlacement records where a kitty image will go before its pixels
// are ready; the source rectangle is clamped when the pixels arrive.
func (t *Terminal) reserveKittyPlacement(params kittyParams, lineID uint64, column int) (uint64, bool) {
	return t.reserveImagePlacement(lineID, column, params.sourceX, params.sourceY, params.sourceWidth, params.sourceHeight,
		params.columns, params.rows, 0, 0, params.placementID, params.z)
}

func (t *Terminal) deleteKitty(params kittyParams) {
	if t.images == nil {
		return
	}
	switch params.delete {
	case 'i':
		image := t.findKittyImage(params.imageID)
		if image == nil {
			return
		}
		kept := t.images.placements[:0]
		for _, placement := range t.images.placements {
			if placement.Image != &image.image {
				kept = append(kept, placement)
			}
		}
		t.images.retainPlacements(kept)
	case 'I':
		image := t.findKittyImage(params.imageID)
		if image != nil {
			for index := range t.images.images {
				if t.images.images[index] == image {
					t.images.deleteAt(index)
					break
				}
			}
		}
	case 'p':
		if params.placementID == 0 {
			return
		}
		kept := t.images.placements[:0]
		for _, placement := range t.images.placements {
			if placement.ProtocolID != params.placementID || !t.isKittyImage(placement.Image) {
				kept = append(kept, placement)
			}
		}
		t.images.retainPlacements(kept)
	case 'P':
		if params.placementID == 0 {
			return
		}
		for index := len(t.images.images) - 1; index >= 0; index-- {
			if !t.images.images[index].kitty {
				continue
			}
			candidate := &t.images.images[index].image
			for _, placement := range t.images.placements {
				if placement.ProtocolID == params.placementID && placement.Image == candidate {
					t.images.deleteAt(index)
					break
				}
			}
		}
	case 'A':
		for index := len(t.images.images) - 1; index >= 0; index-- {
			if t.images.images[index].kitty {
				t.images.deleteAt(index)
			}
		}
	case 0, 'a':
		kept := t.images.placements[:0]
		for _, placement := range t.images.placements {
			if !t.isKittyImage(placement.Image) {
				kept = append(kept, placement)
			}
		}
		t.images.retainPlacements(kept)
	}
}

func (t *Terminal) findKittyImage(id uint32) *storedImage {
	if t.images == nil || id == 0 {
		return nil
	}
	for _, image := range t.images.images {
		if image.kitty && image.protocolID == id {
			return image
		}
	}
	return nil
}

func (t *Terminal) isKittyImage(image *TerminalImage) bool {
	if t.images == nil || image == nil {
		return false
	}
	for _, candidate := range t.images.images {
		if &candidate.image == image {
			return candidate.kitty
		}
	}
	return false
}

func (t *Terminal) replyKitty(params kittyParams, status string) {
	if params.quiet == 2 || params.quiet == 1 && status == "OK" || t.replyFn == nil {
		return
	}
	reply := append(t.scratch[:0], "\x1b_G"...)
	if params.imageID != 0 {
		reply = append(reply, 'i', '=')
		reply = strconv.AppendUint(reply, uint64(params.imageID), 10)
	}
	if params.placementID != 0 {
		if params.imageID != 0 {
			reply = append(reply, ',')
		}
		reply = append(reply, 'p', '=')
		reply = strconv.AppendUint(reply, uint64(params.placementID), 10)
	}
	reply = append(reply, ';')
	reply = append(reply, status...)
	reply = append(reply, '\x1b', '\\')
	t.send(reply)
}
