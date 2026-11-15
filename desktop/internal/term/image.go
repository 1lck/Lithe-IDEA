package term

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"fmt"
	stdimage "image"
	"image/color"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"sync/atomic"
)

const (
	maxImageSequence   = 24 << 20
	maxSixelSequence   = 8 << 20
	maxImageWidth      = 4096
	maxImageHeight     = 4096
	maxImagePixels     = 4 << 20
	maxImageBytes      = maxImagePixels * 4
	maxImageMemory     = 64 << 20
	maxImages          = 64
	maxImagePlacements = 256
)

// TerminalImage is one immutable decoded image. Pix is premultiplied BGRA,
// top row first, and remains valid until the image is deleted or evicted.
type TerminalImage struct {
	Pix           []byte
	Width, Height int
	Stride        int
	ID            uint64
}

// ImagePlacement anchors one decoded image to a retained terminal line. A
// renderer finds LineID among visible Row IDs, then places the image at Column.
// Width/HeightCells take priority over Width/HeightPixels when positive.
type ImagePlacement struct {
	ID           uint64
	Image        *TerminalImage
	LineID       uint64
	Column       int
	WidthCells   int
	HeightCells  int
	WidthPixels  int
	HeightPixels int
	SourceX      int
	SourceY      int
	SourceWidth  int
	SourceHeight int
	ProtocolID   uint32
	Z            int32
}

type storedImage struct {
	image      TerminalImage
	protocolID uint32
	kitty      bool
}

type imageStore struct {
	images     []*storedImage
	placements []ImagePlacement
	bytes      int
	nextPlace  uint64
}

var nextTerminalImageID atomic.Uint64

// Images returns retained placements without allocating. The slice is invalid
// after the next Write, Reset, or Resize.
func (t *Terminal) Images() []ImagePlacement {
	if t.images == nil {
		return nil
	}
	return t.images.placements
}

// ImageRow returns the placement row of a retained line relative to the
// current view. The row may be negative or below the viewport when an image
// anchored off-screen still overlaps it.
func (t *Terminal) ImageRow(lineID uint64) (int, bool) {
	if lineID == 0 {
		return 0, false
	}
	if t.onAlt {
		for row, line := range t.alt.lines {
			if line.id == lineID {
				return row, true
			}
		}
		return 0, false
	}
	top := t.histCount - t.view
	for index := 0; index < t.histCount; index++ {
		if t.histAt(index).id == lineID {
			return index - top, true
		}
	}
	for row, line := range t.main.lines {
		if line.id == lineID {
			return t.histCount + row - top, true
		}
	}
	return 0, false
}

func (t *Terminal) acceptImage(pixels []byte, width, height int, protocolID uint32) *storedImage {
	if !validDecodedImage(pixels, width, height) {
		return nil
	}
	if t.images == nil {
		t.images = &imageStore{}
	}
	store := t.images
	if protocolID != 0 {
		store.deleteProtocol(protocolID)
	}
	for len(store.images) >= maxImages || store.bytes+len(pixels) > maxImageMemory {
		if len(store.images) == 0 {
			return nil
		}
		store.deleteAt(0)
	}
	image := &storedImage{
		image:      TerminalImage{Pix: pixels, Width: width, Height: height, Stride: width * 4, ID: nextTerminalImageID.Add(1)},
		protocolID: protocolID,
	}
	store.images = append(store.images, image)
	store.bytes += len(pixels)
	return image
}

func validDecodedImage(pixels []byte, width, height int) bool {
	if width < 1 || height < 1 || width > maxImageWidth || height > maxImageHeight || width > maxImagePixels/height {
		return false
	}
	bytes := width * height * 4
	return bytes <= maxImageBytes && len(pixels) == bytes
}

func (t *Terminal) placeImage(image *storedImage, widthCells, heightCells, widthPixels, heightPixels int, z int32) {
	if image == nil {
		return
	}
	t.placeImageRegion(image, 0, 0, image.image.Width, image.image.Height, widthCells, heightCells, widthPixels, heightPixels, 0, z)
}

func (t *Terminal) placeImageRegion(image *storedImage, sourceX, sourceY, sourceWidth, sourceHeight, widthCells, heightCells, widthPixels, heightPixels int, protocolPlacement uint32, z int32) {
	lineID, column, ok := t.imageAnchor()
	if !ok {
		return
	}
	t.placeImageRegionAt(image, lineID, column, sourceX, sourceY, sourceWidth, sourceHeight, widthCells, heightCells, widthPixels, heightPixels, protocolPlacement, z)
}

// placeImageRegionAt places an image on a line identity captured when its bytes
// were parsed. An image decoded away from the window thread is applied after
// the cursor moved on, so it keeps the place it arrived in; a line that scrolled
// out and was recycled is dropped instead of pinning the image to another line.
func (t *Terminal) placeImageRegionAt(image *storedImage, lineID uint64, column int, sourceX, sourceY, sourceWidth, sourceHeight, widthCells, heightCells, widthPixels, heightPixels int, protocolPlacement uint32, z int32) {
	if image == nil {
		return
	}
	id, ok := t.reserveImagePlacement(lineID, column, sourceX, sourceY, sourceWidth, sourceHeight, widthCells, heightCells, widthPixels, heightPixels, protocolPlacement, z)
	if !ok {
		return
	}
	t.attachImagePlacement(id, image, nil)
}

// reserveImagePlacement records where an image will go before its pixels are
// ready. Terminal operations between the bytes and the decode (an erase, a
// resize, a scrollback eviction, a kitty delete) then see the placement and act
// on it, exactly as they did when decoding was synchronous. The placement shows
// nothing until attachImagePlacement gives it pixels.
func (t *Terminal) reserveImagePlacement(lineID uint64, column int, sourceX, sourceY, sourceWidth, sourceHeight, widthCells, heightCells, widthPixels, heightPixels int, protocolPlacement uint32, z int32) (uint64, bool) {
	if lineID == 0 || !t.hasLine(lineID) {
		return 0, false
	}
	if t.images == nil {
		t.images = &imageStore{}
	}
	store := t.images
	if len(store.placements) >= maxImagePlacements {
		copy(store.placements, store.placements[1:])
		store.placements = store.placements[:len(store.placements)-1]
	}
	store.nextPlace++
	id := store.nextPlace
	store.placements = append(store.placements, ImagePlacement{
		ID: id, LineID: lineID, Column: column,
		WidthCells: clampInt(widthCells, 0, maxCols), HeightCells: clampInt(heightCells, 0, maxRows),
		WidthPixels: clampInt(widthPixels, 0, maxImageWidth), HeightPixels: clampInt(heightPixels, 0, maxImageHeight),
		SourceX: sourceX, SourceY: sourceY, SourceWidth: sourceWidth, SourceHeight: sourceHeight,
		ProtocolID: protocolPlacement, Z: z,
	})
	return id, true
}

// attachImagePlacement gives a reserved placement its pixels and clamps the
// source rectangle to the image. adjust, when not nil, finalizes the display
// size, which may depend on the decoded dimensions. A placement that terminal
// operations removed in the meantime is left absent; the image itself stays.
func (t *Terminal) attachImagePlacement(id uint64, image *storedImage, adjust func(*ImagePlacement)) bool {
	if t.images == nil || id == 0 || image == nil {
		return false
	}
	width, height := image.image.Width, image.image.Height
	for index := range t.images.placements {
		placement := &t.images.placements[index]
		if placement.ID != id || placement.Image != nil {
			continue
		}
		placement.Image = &image.image
		placement.SourceX = clampInt(placement.SourceX, 0, width-1)
		placement.SourceY = clampInt(placement.SourceY, 0, height-1)
		if placement.SourceWidth <= 0 {
			placement.SourceWidth = width - placement.SourceX
		}
		if placement.SourceHeight <= 0 {
			placement.SourceHeight = height - placement.SourceY
		}
		placement.SourceWidth = clampInt(placement.SourceWidth, 1, width-placement.SourceX)
		placement.SourceHeight = clampInt(placement.SourceHeight, 1, height-placement.SourceY)
		if adjust != nil {
			adjust(placement)
		}
		return true
	}
	return false
}

// dropImagePlacement removes a reservation whose image never decoded, and an
// image store that this reservation kept alive for nothing.
func (t *Terminal) dropImagePlacement(id uint64) {
	if t.images == nil || id == 0 {
		return
	}
	kept := t.images.placements[:0]
	for _, placement := range t.images.placements {
		if placement.ID != id || placement.Image != nil {
			kept = append(kept, placement)
		}
	}
	t.images.retainPlacements(kept)
	if len(t.images.images) == 0 && len(t.images.placements) == 0 {
		t.images = nil
	}
}

func (store *imageStore) deleteProtocol(id uint32) {
	if store == nil || id == 0 {
		return
	}
	for index := len(store.images) - 1; index >= 0; index-- {
		if store.images[index].protocolID == id {
			store.deleteAt(index)
		}
	}
}

func (store *imageStore) deleteAt(index int) {
	if index < 0 || index >= len(store.images) {
		return
	}
	image := store.images[index]
	store.bytes -= len(image.image.Pix)
	kept := store.placements[:0]
	for _, placement := range store.placements {
		if placement.Image != &image.image {
			kept = append(kept, placement)
		}
	}
	store.retainPlacements(kept)
	copy(store.images[index:], store.images[index+1:])
	store.images[len(store.images)-1] = nil
	store.images = store.images[:len(store.images)-1]
}

func (store *imageStore) deleteAll() {
	if store == nil {
		return
	}
	clear(store.images)
	clear(store.placements)
	store.images = store.images[:0]
	store.placements = store.placements[:0]
	store.bytes = 0
}

func (store *imageStore) retainPlacements(kept []ImagePlacement) {
	clear(store.placements[len(kept):])
	store.placements = kept
}

func (store *imageStore) dropLine(lineID uint64) {
	if store == nil || lineID == 0 {
		return
	}
	kept := store.placements[:0]
	for _, placement := range store.placements {
		if placement.LineID != lineID {
			kept = append(kept, placement)
		}
	}
	store.retainPlacements(kept)
}

func (store *imageStore) erase(lineID uint64, from, to int) {
	if store == nil || lineID == 0 || from >= to {
		return
	}
	kept := store.placements[:0]
	for _, placement := range store.placements {
		width := max(placement.WidthCells, 1)
		if placement.LineID != lineID || placement.Column+width <= from || placement.Column >= to {
			kept = append(kept, placement)
		}
	}
	store.retainPlacements(kept)
}

func (store *imageStore) insert(lineID uint64, column, count, columns int) {
	if store == nil {
		return
	}
	kept := store.placements[:0]
	for _, placement := range store.placements {
		if placement.LineID == lineID && placement.Column >= column {
			placement.Column += count
			if placement.Column >= columns {
				continue
			}
		}
		kept = append(kept, placement)
	}
	store.retainPlacements(kept)
}

func (store *imageStore) deleteCells(lineID uint64, column, count int) {
	if store == nil {
		return
	}
	kept := store.placements[:0]
	for _, placement := range store.placements {
		if placement.LineID != lineID {
			kept = append(kept, placement)
			continue
		}
		if placement.Column >= column+count {
			placement.Column -= count
			kept = append(kept, placement)
		} else if placement.Column < column {
			kept = append(kept, placement)
		}
	}
	store.retainPlacements(kept)
}

func decodeBase64Image(encoded []byte) ([]byte, error) {
	if len(encoded) == 0 || len(encoded) > maxImageSequence {
		return nil, fmt.Errorf("image payload exceeds encoded limit")
	}
	length := base64.StdEncoding.DecodedLen(len(encoded))
	if length > maxImageBytes {
		return nil, fmt.Errorf("image payload exceeds decoded limit")
	}
	decoded := make([]byte, length)
	n, err := base64.StdEncoding.Strict().Decode(decoded, encoded)
	if err != nil {
		length = base64.RawStdEncoding.DecodedLen(len(encoded))
		if length > maxImageBytes {
			return nil, fmt.Errorf("image payload exceeds decoded limit")
		}
		decoded = make([]byte, length)
		n, err = base64.RawStdEncoding.Strict().Decode(decoded, encoded)
	}
	if err != nil {
		return nil, err
	}
	return decoded[:n], nil
}

func inflateImage(data []byte) ([]byte, error) {
	reader, err := zlib.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	decoded, err := io.ReadAll(io.LimitReader(reader, maxImageBytes+1))
	if err != nil {
		return nil, err
	}
	if len(decoded) > maxImageBytes {
		return nil, fmt.Errorf("image decompression exceeds limit")
	}
	return decoded, nil
}

func decodeImage(data []byte) ([]byte, int, int, error) {
	if len(data) == 0 || len(data) > maxImageBytes {
		return nil, 0, 0, fmt.Errorf("encoded image exceeds limit")
	}
	config, _, err := stdimage.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, err
	}
	if config.Width < 1 || config.Height < 1 || config.Width > maxImageWidth || config.Height > maxImageHeight || config.Width > maxImagePixels/config.Height {
		return nil, 0, 0, fmt.Errorf("decoded image dimensions exceed limit")
	}
	source, _, err := stdimage.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, 0, 0, err
	}
	bounds := source.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	if width != config.Width || height != config.Height || width > maxImagePixels/height {
		return nil, 0, 0, fmt.Errorf("decoded image changed dimensions")
	}
	return imagePixels(source, width, height), width, height, nil
}

// imagePixels copies a decoded image into the premultiplied BGRA bytes the
// terminal stores. The formats the standard decoders produce get a direct
// switch: reading every pixel through image.Image.At boxes a color in an
// interface, which allocates once per pixel and dominates a large image. The
// arithmetic below is the same one color.RGBA, color.NRGBA, color.YCbCr and
// color.Gray do in their RGBA methods, so the bytes match the generic path.
func imagePixels(source stdimage.Image, width, height int) []byte {
	pixels := make([]byte, width*height*4)
	bounds := source.Bounds()
	switch src := source.(type) {
	case *stdimage.RGBA:
		for y := 0; y < height; y++ {
			row := src.Pix[src.PixOffset(bounds.Min.X, bounds.Min.Y+y):]
			out := pixels[y*width*4:]
			for x := 0; x < width; x++ {
				offset := x * 4
				out[offset], out[offset+1], out[offset+2], out[offset+3] =
					row[offset+2], row[offset+1], row[offset], row[offset+3]
			}
		}
	case *stdimage.NRGBA:
		for y := 0; y < height; y++ {
			row := src.Pix[src.PixOffset(bounds.Min.X, bounds.Min.Y+y):]
			out := pixels[y*width*4:]
			for x := 0; x < width; x++ {
				offset := x * 4
				red, green, blue, alpha := row[offset], row[offset+1], row[offset+2], row[offset+3]
				// color.NRGBA.RGBA multiplies the 16-bit color by the alpha and
				// divides by 0xff; taking the high byte is its >>8.
				out[offset] = byte(uint32(blue) * 0x101 * uint32(alpha) / 0xff >> 8)
				out[offset+1] = byte(uint32(green) * 0x101 * uint32(alpha) / 0xff >> 8)
				out[offset+2] = byte(uint32(red) * 0x101 * uint32(alpha) / 0xff >> 8)
				out[offset+3] = alpha
			}
		}
	case *stdimage.YCbCr:
		for y := 0; y < height; y++ {
			out := pixels[y*width*4:]
			for x := 0; x < width; x++ {
				red, green, blue := color.YCbCrToRGB(
					src.Y[src.YOffset(bounds.Min.X+x, bounds.Min.Y+y)],
					src.Cb[src.COffset(bounds.Min.X+x, bounds.Min.Y+y)],
					src.Cr[src.COffset(bounds.Min.X+x, bounds.Min.Y+y)])
				offset := x * 4
				out[offset], out[offset+1], out[offset+2], out[offset+3] = blue, green, red, 0xff
			}
		}
	case *stdimage.Gray:
		for y := 0; y < height; y++ {
			row := src.Pix[src.PixOffset(bounds.Min.X, bounds.Min.Y+y):]
			out := pixels[y*width*4:]
			for x := 0; x < width; x++ {
				offset := x * 4
				out[offset], out[offset+1], out[offset+2], out[offset+3] = row[x], row[x], row[x], 0xff
			}
		}
	default:
		for y := 0; y < height; y++ {
			for x := 0; x < width; x++ {
				red, green, blue, alpha := source.At(bounds.Min.X+x, bounds.Min.Y+y).RGBA()
				offset := (y*width + x) * 4
				pixels[offset], pixels[offset+1], pixels[offset+2], pixels[offset+3] =
					byte(blue>>8), byte(green>>8), byte(red>>8), byte(alpha>>8)
			}
		}
	}
	return pixels
}
