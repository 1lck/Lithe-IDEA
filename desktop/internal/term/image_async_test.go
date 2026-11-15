package term

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// imageTestRaw is a 2x1 RGBA kitty payload; imageTestPixels is what the
// terminal stores for it, premultiplied BGRA.
var (
	imageTestRaw    = []byte{0, 0, 255, 255, 0, 255, 0, 255}
	imageTestPixels = []byte{255, 0, 0, 255, 0, 255, 0, 255}
)

func rawKittyImage(id uint32) string {
	return "\x1b_Ga=T,f=32,s=2,v=1,i=" + strconv.Itoa(int(id)) + ";" + base64.StdEncoding.EncodeToString(imageTestRaw) + "\x1b\\"
}

// TestImagesDecodeOffTheThreadAndApplyOnWait checks the basic asynchronous
// path: writing an image queues work, the pixels are not there until the
// terminal applies them, and they are correct afterwards.
func TestImagesDecodeOffTheThreadAndApplyOnWait(t *testing.T) {
	terminal := New(10, 4, 10)
	feed(terminal, rawKittyImage(1))
	if got := terminal.Images(); len(got) != 1 || got[0].Image != nil {
		t.Fatalf("the place was not reserved while the pixels decoded: %+v", got)
	}
	terminal.WaitImages()
	placements := terminal.Images()
	if len(placements) != 1 || placements[0].Image == nil {
		t.Fatalf("placements = %+v", placements)
	}
	if !bytes.Equal(placements[0].Image.Pix, imageTestPixels) {
		t.Fatalf("pixels = %v", placements[0].Image.Pix)
	}
}

// TestImageDecodeKeepsParseOrder proves a placement or delete that follows an
// image in the byte stream is applied after the image, not before it.
func TestImageDecodeKeepsParseOrder(t *testing.T) {
	terminal := New(10, 4, 10)
	var replies bytes.Buffer
	terminal.SetReply(func(value []byte) { replies.Write(value) })
	// Transmit without display, place by id, and delete that placement in one
	// stream. In order, the placement finds the decoded image and the delete
	// then removes it; applied out of order the placement would answer ENOENT.
	transmit := "\x1b_Ga=t,f=32,s=2,v=1,i=5;" + base64.StdEncoding.EncodeToString(imageTestRaw) + "\x1b\\"
	feed(terminal, transmit+"\x1b_Ga=p,i=5,p=9;\x1b\\"+"\x1b_Ga=d,d=p,p=9;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || terminal.findKittyImage(5) == nil {
		t.Fatalf("images = %+v, placements = %+v", terminal.Images(), terminal.images)
	}
	if !bytes.Contains(replies.Bytes(), []byte("i=5;OK")) || !bytes.Contains(replies.Bytes(), []byte("p=9;OK")) {
		t.Fatalf("replies = %q", replies.Bytes())
	}
	if bytes.Contains(replies.Bytes(), []byte("ENOENT")) {
		t.Fatalf("the placement ran before the image was decoded: %q", replies.Bytes())
	}
}

// TestImagePlacementReservedBeforeDecode checks the placement exists while the
// pixels are still decoding, so an erase that follows the image removes it.
func TestImagePlacementReservedBeforeDecode(t *testing.T) {
	terminal := New(10, 4, 10)
	feed(terminal, rawKittyImage(1)+"\x1b[2K")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 {
		t.Fatalf("erase did not see the reserved placement: %+v", terminal.Images())
	}
	if terminal.images == nil || len(terminal.images.images) != 1 {
		t.Fatalf("the erased image was not retained: %+v", terminal.images)
	}
}

// TestDeletingAPendingImageAppliesAfterTheDecode checks a kitty delete that
// names an image still decoding lands after it, not before it.
func TestDeletingAPendingImageAppliesAfterTheDecode(t *testing.T) {
	terminal := New(10, 4, 10)
	feed(terminal, rawKittyImage(6)+"\x1b_Ga=d,d=I,i=6;\x1b\\")
	terminal.WaitImages()
	if len(terminal.Images()) != 0 || terminal.findKittyImage(6) != nil {
		t.Fatalf("delete did not follow the decode: placements=%+v", terminal.Images())
	}
}

// TestResizeDropsAPendingPlacement checks a resize that discards the anchored
// row removes the reservation before the pixels arrive.
func TestResizeDropsAPendingPlacement(t *testing.T) {
	terminal := New(8, 4, 10)
	feed(terminal, "\x1b[4;1H"+rawKittyImage(1)+"\x1b[1;1H")
	terminal.Resize(8, 2)
	terminal.WaitImages()
	if len(terminal.Images()) != 0 {
		t.Fatalf("a placement for a discarded row survived: %+v", terminal.Images())
	}
}

// TestImageAnchoredToAnEvictedLineIsDropped checks that a decode landing after
// its line left the scrollback does not pin a placement to a recycled row, and
// that the empty image store is released.
func TestImageAnchoredToAnEvictedLineIsDropped(t *testing.T) {
	terminal := New(8, 2, 1)
	feed(terminal, rawKittyImage(1))
	for index := 0; index < 20; index++ {
		feed(terminal, "line\r\n")
	}
	terminal.WaitImages()
	if len(terminal.Images()) != 0 {
		t.Fatalf("evicted anchor kept a placement: %+v", terminal.Images())
	}
}

// TestImageQueueDropsPastItsBudget checks a program that writes more images
// than the terminal will hold gets an error instead of unbounded memory.
func TestImageQueueDropsPastItsBudget(t *testing.T) {
	terminal := New(10, 4, 0)
	release := make(chan struct{})
	for index := 0; index < imageQueueDepth; index++ {
		terminal.queueImageJob(&imageJob{decode: func() imageResult {
			<-release
			return imageResult{pixels: []byte{0, 0, 0, 255}, width: 1, height: 1}
		}})
	}
	var dropped error
	terminal.queueImageJob(&imageJob{
		decode: func() imageResult {
			t.Error("an over-budget image was decoded")
			return imageResult{}
		},
		apply: func(_ *Terminal, result imageResult) { dropped = result.err },
	})
	close(release)
	terminal.WaitImages()
	if dropped != errImageQueueFull {
		t.Fatalf("over-budget image result = %v", dropped)
	}
}

// TestResetDiscardsPendingImageWork checks that a reset terminal does not apply
// an image decoded for the screen it used to show.
func TestResetDiscardsPendingImageWork(t *testing.T) {
	terminal := New(10, 4, 0)
	release := make(chan struct{})
	applied := false
	terminal.queueImageJob(&imageJob{
		decode: func() imageResult { <-release; return imageResult{pixels: []byte{0, 0, 0, 255}, width: 1, height: 1} },
		apply:  func(*Terminal, imageResult) { applied = true },
	})
	terminal.Reset()
	close(release)
	terminal.WaitImages()
	if applied {
		t.Fatal("an image queued before Reset was applied after it")
	}
}

// TestPendingDecodeAsksForAFrame checks the wake callback fires once the pixels
// are ready, so the owner draws the frame that shows them.
func TestPendingDecodeAsksForAFrame(t *testing.T) {
	terminal := New(10, 4, 0)
	woke := make(chan struct{}, 4)
	terminal.SetImageWake(func() {
		select {
		case woke <- struct{}{}:
		default:
		}
	})
	feed(terminal, rawKittyImage(3))
	select {
	case <-woke:
	case <-time.After(5 * time.Second):
		t.Fatal("a finished decode did not ask for a frame")
	}
	terminal.WaitImages()
	if len(terminal.Images()) != 1 {
		t.Fatalf("placements = %+v", terminal.Images())
	}
}

// TestImagePayloadBuffersAreDetached checks the parser hands its buffers to
// the decoder instead of reusing them for the next sequence under it.
func TestImagePayloadBuffersAreDetached(t *testing.T) {
	terminal := New(20, 4, 0)
	feed(terminal, "\x1b]1337;File=inline=1:"+base64.StdEncoding.EncodeToString(tinyPNG(t))+"\x07")
	if terminal.osc != nil {
		t.Fatal("the OSC buffer was not detached for the decoder")
	}
	feed(terminal, "\x1bPq#1;2;100;0;0~\x1b\\")
	if terminal.dcs != nil {
		t.Fatal("the DCS buffer was not detached for the decoder")
	}
	// A sequence that is not an image keeps reusing its buffer.
	feed(terminal, "\x1b]0;a title\x07")
	if terminal.osc == nil {
		t.Fatal("a plain OSC title stopped reusing its buffer")
	}
	terminal.WaitImages()
}

// TestImagePayloadSurvivesLaterOutput decodes a real picture after a long
// message follows it, which would overwrite the payload if it were not owned by
// the decoder.
func TestImagePayloadSurvivesLaterOutput(t *testing.T) {
	picture := image.NewNRGBA(image.Rect(0, 0, 48, 48))
	for y := 0; y < 48; y++ {
		for x := 0; x < 48; x++ {
			picture.SetNRGBA(x, y, color.NRGBA{uint8(x * 5), uint8(y * 5), uint8(x ^ y), 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, picture); err != nil {
		t.Fatal(err)
	}
	payload := encoded.Bytes()
	want := referencePixels(picture)
	terminal := New(80, 8, 10)
	feed(terminal, "\x1b]1337;File=inline=1:"+base64.StdEncoding.EncodeToString(payload)+"\x07")
	feed(terminal, "\x1b]0;"+strings.Repeat("t", 1024)+"\x07")
	terminal.WaitImages()
	placements := terminal.Images()
	if len(placements) != 1 || placements[0].Image == nil {
		t.Fatalf("placements = %+v", placements)
	}
	if !bytes.Equal(placements[0].Image.Pix, want) {
		t.Fatal("the picture changed after later output")
	}
}

// TestFailedDecodeRepliesAndLeavesNoPlacement checks a broken picture reports
// the kitty error and does not keep the reservation or the image store.
func TestFailedDecodeRepliesAndLeavesNoPlacement(t *testing.T) {
	terminal := New(10, 4, 0)
	var replies bytes.Buffer
	terminal.SetReply(func(value []byte) { replies.Write(value) })
	feed(terminal, "\x1b_Ga=T,f=100,i=4;bm90IGEgcGljdHVyZQ==\x1b\\")
	terminal.WaitImages()
	if !bytes.Contains(replies.Bytes(), []byte("i=4;EINVAL")) {
		t.Fatalf("replies = %q", replies.Bytes())
	}
	if len(terminal.Images()) != 0 || terminal.images != nil {
		t.Fatalf("failed decode kept state: %+v", terminal.images)
	}
}

// TestEarlierImageDecodeBlocksLaterApplication checks ApplyImages stops at the
// first unfinished decode instead of applying a later job out of order.
func TestEarlierImageDecodeBlocksLaterApplication(t *testing.T) {
	terminal := New(10, 4, 0)
	release := make(chan struct{})
	var order []string
	terminal.queueImageJob(&imageJob{
		decode: func() imageResult { <-release; return imageResult{} },
		apply:  func(*Terminal, imageResult) { order = append(order, "first") },
	})
	terminal.queueImageJob(&imageJob{
		decode: func() imageResult { return imageResult{} },
		apply:  func(*Terminal, imageResult) { order = append(order, "second") },
	})
	terminal.ApplyImages()
	if len(order) != 0 {
		t.Fatalf("a later job overtook a pending decode: %v", order)
	}
	close(release)
	terminal.WaitImages()
	if len(order) != 2 || order[0] != "first" || order[1] != "second" {
		t.Fatalf("apply order = %v", order)
	}
}

// TestAReadyKittyOperationAsksForAFrame checks a placement or delete, which has
// no decode to wake the window, still requests the frame that applies it.
func TestAReadyKittyOperationAsksForAFrame(t *testing.T) {
	terminal := New(10, 4, 0)
	woke := make(chan struct{}, 4)
	terminal.SetImageWake(func() {
		select {
		case woke <- struct{}{}:
		default:
		}
	})
	feed(terminal, "\x1b_Ga=d,d=a;\x1b\\")
	select {
	case <-woke:
	case <-time.After(5 * time.Second):
		t.Fatal("a delete that needs no decode did not ask for a frame")
	}
	terminal.ApplyImages()
}

// TestImagesDoNotBlockTheWriter checks Write returns before a slow decode does.
func TestImagesDoNotBlockTheWriter(t *testing.T) {
	terminal := New(10, 4, 0)
	release := make(chan struct{})
	var decoded atomic.Bool
	// Occupy the queue with a decode that will not finish until released.
	terminal.queueImageJob(&imageJob{decode: func() imageResult {
		<-release
		decoded.Store(true)
		return imageResult{}
	}})
	done := make(chan struct{})
	go func() {
		feed(terminal, rawKittyImage(1))
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Write waited for an image decode")
	}
	if decoded.Load() {
		t.Fatal("the decode finished before it was released")
	}
	close(release)
	terminal.WaitImages()
}
