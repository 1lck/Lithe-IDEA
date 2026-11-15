package term

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
)

func tinyPNG(t testing.TB) []byte {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, 2, 1))
	picture.SetNRGBA(0, 0, color.NRGBA{R: 255, A: 255})
	picture.SetNRGBA(1, 0, color.NRGBA{G: 255, A: 128})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, picture); err != nil {
		t.Fatal(err)
	}
	return encoded.Bytes()
}

func TestKittyGraphicsChunksDecodePlaceAndDeleteRealPixels(t *testing.T) {
	terminal := New(10, 4, 10)
	raw := []byte{255, 0, 0, 255, 0, 255, 0, 128}
	encoded := base64.StdEncoding.EncodeToString(raw)
	cut := 8
	feed(terminal, "\x1b_Ga=T,f=32,s=2,v=1,i=7,p=3,c=4,r=2,m=1;"+encoded[:cut]+"\x1b\\")
	if terminal.images != nil || terminal.kitty == nil {
		t.Fatal("an incomplete transmission became visible")
	}
	feed(terminal, "\x1b_Gm=0;"+encoded[cut:]+"\x1b\\")
	terminal.WaitImages()
	placements := terminal.Images()
	if len(placements) != 1 || placements[0].Image.Width != 2 || placements[0].WidthCells != 4 || placements[0].HeightCells != 2 || placements[0].ProtocolID != 3 {
		t.Fatalf("placements = %+v", placements)
	}
	want := []byte{0, 0, 255, 255, 0, 128, 0, 128}
	if !bytes.Equal(placements[0].Image.Pix, want) {
		t.Fatalf("BGRA pixels = %v, want %v", placements[0].Image.Pix, want)
	}
	feed(terminal, "\x1b_Ga=d,d=I,i=7;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || len(terminal.images.images) != 0 {
		t.Fatal("Kitty image deletion retained storage or placement")
	}
}

func TestKittyLowercaseDeleteRetainsDataAndContinuationRejectsConflicts(t *testing.T) {
	terminal := New(10, 4, 10)
	raw := base64.StdEncoding.EncodeToString([]byte{255, 0, 0})
	feed(terminal, "\x1b_Ga=T,f=24,s=1,v=1,i=11,p=7;"+raw+"\x1b\\")
	terminal.WaitImages()
	feed(terminal, "\x1b_Ga=d,d=i,i=11;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || len(terminal.images.images) != 1 {
		t.Fatalf("lowercase image delete removed data: %d placements, %d images", len(terminal.Images()), len(terminal.images.images))
	}
	feed(terminal, "\x1b_Ga=p,i=11,p=8;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 1 || terminal.Images()[0].ProtocolID != 8 {
		t.Fatalf("retained image could not be placed again: %+v", terminal.Images())
	}
	feed(terminal, "\x1b_Ga=d,d=p,p=8;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || len(terminal.images.images) != 1 {
		t.Fatal("lowercase placement delete removed image data")
	}
	feed(terminal, "\x1b_Ga=p,i=11,p=9;\x1b\\\x1b_Ga=d,d=P,p=9;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || terminal.findKittyImage(11) != nil {
		t.Fatal("uppercase placement delete retained image data")
	}

	cut := len(raw) / 2
	feed(terminal, "\x1b_Ga=T,f=24,s=1,v=1,i=12,m=1;"+raw[:cut]+"\x1b\\")
	feed(terminal, "\x1b_Gs=2,m=0;"+raw[cut:]+"\x1b\\")
	terminal.WaitImages()
	if terminal.kitty != nil || terminal.findKittyImage(12) != nil {
		t.Fatal("conflicting continuation was retained or decoded")
	}
}

func TestKittyCompressedTransmissionAndQuietReplyPolicy(t *testing.T) {
	raw := []byte{10, 20, 30}
	var compressed bytes.Buffer
	writer := zlib.NewWriter(&compressed)
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	encoded := base64.StdEncoding.EncodeToString(compressed.Bytes())
	terminal := New(4, 2, 0)
	var replies bytes.Buffer
	terminal.SetReply(func(value []byte) { replies.Write(value) })
	feed(terminal, "\x1b_Ga=T,f=24,o=z,s=1,v=1,i=9;"+encoded+"\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 1 || !bytes.Equal(terminal.Images()[0].Image.Pix, []byte{30, 20, 10, 255}) {
		t.Fatalf("compressed image = %+v", terminal.Images())
	}
	if !bytes.Contains(replies.Bytes(), []byte("i=9;OK")) {
		t.Fatalf("reply = %q", replies.Bytes())
	}
	replies.Reset()
	feed(terminal, "\x1b_Ga=d,d=i,i=9,q=2;\x1b\\")
	terminal.WaitImages()
	if replies.Len() != 0 {
		t.Fatalf("quiet delete replied %q", replies.Bytes())
	}
}

func TestItermInlineImageDecodesPNGAndHonorsDimensions(t *testing.T) {
	terminal := New(10, 4, 10)
	pngBytes := tinyPNG(t)
	encoded := base64.StdEncoding.EncodeToString(pngBytes)
	sequence := "\x1b]1337;File=inline=1;width=8px;size=" + itoa(len(pngBytes)) + ":" + encoded + "\x07"
	for index := range sequence {
		terminal.Write([]byte(sequence[index : index+1]))
	}
	terminal.WaitImages()
	placements := terminal.Images()
	if len(placements) != 1 || placements[0].WidthPixels != 8 || placements[0].HeightPixels != 4 {
		t.Fatalf("placements = %+v", placements)
	}
	if got := placements[0].Image.Pix; len(got) != 8 || got[2] != 255 || got[5] != 128 || got[7] != 128 {
		t.Fatalf("decoded pixels = %v", got)
	}
}

func TestSixelRasterizesPaletteRepeatAndRows(t *testing.T) {
	terminal := New(10, 4, 10)
	feed(terminal, "\x1bPq\"1;1;2;6#1;2;100;0;0!2~\x1b\\")
	terminal.WaitImages()
	placements := terminal.Images()
	if len(placements) != 1 || placements[0].Image.Width != 2 || placements[0].Image.Height != 6 {
		t.Fatalf("placements = %+v", placements)
	}
	for offset := 0; offset < len(placements[0].Image.Pix); offset += 4 {
		if pixel := placements[0].Image.Pix[offset : offset+4]; !bytes.Equal(pixel, []byte{0, 0, 255, 255}) {
			t.Fatalf("pixel %d = %v", offset/4, pixel)
		}
	}
}

func TestImagesFollowScrollbackResizeAlternateScreenAndErase(t *testing.T) {
	terminal := New(8, 3, 10)
	feed(terminal, "\x1bPq#1;2;100;0;0~\x1b\\")
	terminal.WaitImages()
	line := terminal.Images()[0].LineID
	feed(terminal, "\r\na\r\nb\r\nc\r\nd")
	if row, ok := terminal.ImageRow(line); !ok || row >= 0 {
		t.Fatalf("live-bottom image row = %d,%v, want above view", row, ok)
	}
	terminal.Scroll(10)
	if row, ok := terminal.ImageRow(line); !ok || row != 0 {
		t.Fatalf("scrolled image row = %d,%v, want 0", row, ok)
	}
	terminal.Resize(12, 5)
	if _, ok := terminal.ImageRow(line); !ok {
		t.Fatal("resize lost retained image anchor")
	}
	terminal.ScrollToBottom()
	feed(terminal, "\x1b[?1049h\x1bPq#2;2;0;100;0~\x1b\\")
	terminal.WaitImages()
	alt := terminal.Images()[len(terminal.Images())-1].LineID
	feed(terminal, "\x1b[?1049l")
	if _, ok := terminal.ImageRow(alt); ok {
		t.Fatal("alternate-screen image leaked onto main screen")
	}
	feed(terminal, "\x1b[?1049h")
	if _, ok := terminal.ImageRow(alt); ok {
		t.Fatal("clearing alternate screen retained its placement")
	}
	feed(terminal, "\x1b[?1049l\x1bPq#1~\x1b\\\x1b[2K")
	terminal.WaitImages()
	for _, placement := range terminal.Images() {
		if _, ok := terminal.ImageRow(placement.LineID); ok && placement.LineID == terminal.scr.lines[terminal.cy].id {
			t.Fatal("line erase retained an overlapping image")
		}
	}
}

func TestResizeDropsPlacementsForDiscardedRows(t *testing.T) {
	terminal := New(8, 4, 10)
	feed(terminal, "\x1b[4;1H\x1bPq#1~\x1b\\\x1b[1;1H")
	terminal.WaitImages()
	bottomLine := terminal.Images()[0].LineID
	terminal.Resize(8, 2)
	if len(terminal.Images()) != 0 {
		t.Fatalf("bottom-row placement survived resize: %+v", terminal.Images())
	}
	if _, ok := terminal.ImageRow(bottomLine); ok {
		t.Fatal("discarded bottom row remains addressable")
	}

	feed(terminal, "\x1b[?1049h\x1b[1;1H\x1bPq#2~\x1b\\\x1b[2;1H")
	terminal.WaitImages()
	altLine := terminal.Images()[0].LineID
	terminal.Resize(8, 1)
	if len(terminal.Images()) != 0 {
		t.Fatalf("discarded alternate-screen placement survived resize: %+v", terminal.Images())
	}
	if _, ok := terminal.ImageRow(altLine); ok {
		t.Fatal("discarded alternate-screen row remains addressable")
	}
}

func TestMalformedImagesAndDecompressionBombsAreRejected(t *testing.T) {
	terminal := New(10, 4, 0)
	feed(terminal, "\x1b_Ga=T,f=100,i=1;%%%\x1b\\")
	feed(terminal, "\x1b]1337;File=inline=1:not-base64\x07")
	feed(terminal, "\x1bPq!999999999~\x1b\\")
	terminal.WaitImages()
	if terminal.images != nil {
		t.Fatal("malformed image input allocated retained storage")
	}
	oversized := image.NewNRGBA(image.Rect(0, 0, maxImageWidth+1, 1))
	var pngData bytes.Buffer
	if err := png.Encode(&pngData, oversized); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := decodeImage(pngData.Bytes()); err == nil {
		t.Fatal("oversized PNG dimensions were accepted")
	}
	var compressed bytes.Buffer
	writer := zlib.NewWriter(&compressed)
	chunk := bytes.Repeat([]byte{'x'}, 1<<20)
	for written := 0; written <= maxImageBytes; written += len(chunk) {
		if _, err := writer.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := inflateImage(compressed.Bytes()); err == nil {
		t.Fatal("decompression bomb was accepted")
	}
}

func TestImageStoreCountAndMemoryStayBounded(t *testing.T) {
	terminal := New(2, 2, 0)
	for index := 0; index < maxImages+20; index++ {
		image := terminal.acceptImage([]byte{0, 0, byte(index), 255}, 1, 1, uint32(index+1))
		terminal.placeImage(image, 1, 1, 0, 0, 0)
	}
	if len(terminal.images.images) != maxImages || len(terminal.images.placements) > maxImagePlacements || terminal.images.bytes > maxImageMemory {
		t.Fatalf("store = %d images, %d placements, %d bytes", len(terminal.images.images), len(terminal.images.placements), terminal.images.bytes)
	}
}

func TestImageStoreEvictsBeforeTotalPixelMemoryLimit(t *testing.T) {
	pixels := make([]byte, maxImageBytes)
	terminal := New(2, 2, 0)
	for index := 0; index < maxImageMemory/maxImageBytes+1; index++ {
		if terminal.acceptImage(pixels, 2048, 2048, uint32(index+1)) == nil {
			t.Fatalf("image %d was rejected instead of evicting", index)
		}
	}
	if terminal.images.bytes > maxImageMemory || len(terminal.images.images) != maxImageMemory/maxImageBytes {
		t.Fatalf("store = %d images, %d bytes", len(terminal.images.images), terminal.images.bytes)
	}
}

func TestImageContentIDsAreUniqueAcrossTerminals(t *testing.T) {
	first := New(2, 2, 0).acceptImage([]byte{0, 0, 0, 255}, 1, 1, 0)
	second := New(2, 2, 0).acceptImage([]byte{0, 0, 0, 255}, 1, 1, 0)
	if first.image.ID == 0 || second.image.ID == 0 || first.image.ID == second.image.ID {
		t.Fatalf("image IDs = %d and %d", first.image.ID, second.image.ID)
	}
}

func FuzzTerminalImages(f *testing.F) {
	for _, seed := range []string{
		"\x1b_Ga=T,f=32,s=1,v=1;/////w==\x1b\\",
		"\x1b]1337;File=inline=1:AAAA\x07",
		"\x1bPq#1;2;100;0;0!2~\x1b\\",
	} {
		f.Add([]byte(seed))
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 1<<16 {
			t.Skip()
		}
		terminal := New(20, 8, 20)
		for len(data) > 0 {
			count := min(len(data), 7)
			terminal.Write(data[:count])
			data = data[count:]
		}
		terminal.WaitImages()
		checkInvariants(t, terminal)
		if terminal.images != nil && (len(terminal.images.images) > maxImages || len(terminal.images.placements) > maxImagePlacements || terminal.images.bytes > maxImageMemory) {
			t.Fatal("image store exceeded limits")
		}
	})
}

func BenchmarkImagesUnused(b *testing.B) {
	terminal := New(120, 40, DefaultScrollback)
	b.ReportAllocs()
	for b.Loop() {
		if len(terminal.Images()) != 0 {
			b.Fatal(strings.Repeat("unexpected image", 1))
		}
	}
}
