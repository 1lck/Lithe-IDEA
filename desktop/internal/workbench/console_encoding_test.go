package workbench

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// TestConsoleEncodingPipeHelper writes bytes through the same native pipes as a run.
// Waiting for stdin prevents the OS from combining both halves of the GBK character.
func TestConsoleEncodingPipeHelper(t *testing.T) {
	stream := os.Getenv("LITHE_TEST_ENCODING_PIPE")
	if stream == "" {
		return
	}
	output := os.Stdout
	if stream == "stderr" {
		output = os.Stderr
	}
	if _, err := output.WriteString("编译\n\x1b[32m\xb9\xb9\xbd"); err != nil {
		os.Exit(2)
	}
	var ack [1]byte
	if _, err := io.ReadFull(os.Stdin, ack[:]); err != nil {
		os.Exit(3)
	}
	if _, err := output.WriteString("\xa8\xb3\xc9\xb9\xa6\x1b[m\r\n"); err != nil {
		os.Exit(4)
	}
	os.Exit(0)
}

func TestConsoleEncodingThroughNativeProcessPipes(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, stream := range []string{"stdout", "stderr"} {
		t.Run(stream, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			input, ack, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			defer input.Close()
			defer ack.Close()
			d := newOutputDecoder(core.NewClient(), core.OutputEncodingPolicy{Windows: true})
			buffer := newOutputBuffer(100, 1<<20)
			first := make(chan struct{}, 1)
			var raw string
			var decodeError error
			process, err := buildprocess.Start(ctx, buildprocess.Spec{
				Executable: executable, Arguments: []string{"-test.run=^TestConsoleEncodingPipeHelper$"},
				WorkingDirectory: t.TempDir(), Stdin: input,
				Environment: map[string]string{"LITHE_TEST_ENCODING_PIPE": stream},
			}, func(kind buildprocess.Stream, text string) {
				if string(kind) != stream {
					return
				}
				raw += text
				d.deliver(text, func(chunk outputChunk, err error) {
					if err != nil {
						decodeError = err
					}
					buffer.apply(chunk)
				})
				if strings.HasSuffix(raw, "\xb9\xb9\xbd") {
					first <- struct{}{}
				}
			})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { process.Kill(); _ = process.Wait() })
			select {
			case <-first:
			case <-ctx.Done():
				t.Fatal("the process did not write the first half of the GBK character")
			}
			if _, err := fmt.Fprint(ack, "x"); err != nil {
				t.Fatal(err)
			}
			if err := process.Wait(); err != nil {
				t.Fatal(err)
			}
			if decodeError != nil || buffer.all() != "编译\n构建成功\n" {
				t.Fatalf("pipe output = %q, decode error = %v", buffer.all(), decodeError)
			}
			if spans := buffer.lines[1].spans; len(spans) != 1 || spans[0].Length != 4 {
				t.Fatalf("GBK style ranges = %+v", spans)
			}
		})
	}
}

// TestConsoleDecoderPreservesRawBytesAndStyles checks the boundary that previously let
// JSON replace GBK bytes before Core could see them, including a split inside a character.
func TestConsoleDecoderPreservesRawBytesAndStyles(t *testing.T) {
	d := newOutputDecoder(core.NewClient(), core.OutputEncodingPolicy{Windows: true})
	b := newOutputBuffer(100, 1<<20)
	for _, raw := range []string{"编译\n\x1b[32m\xb9\xb9\xbd", "\xa8\xb3\xc9\xb9\xa6\x1b[m\r\n"} {
		d.deliver(raw, func(chunk outputChunk, err error) {
			if err != nil {
				t.Fatal(err)
			}
			b.apply(chunk)
		})
	}
	if b.all() != "编译\n构建成功\n" {
		t.Fatalf("decoded text = %q", b.all())
	}
	if spans := b.lines[1].spans; len(spans) != 1 || spans[0].Start != 0 || spans[0].Length != 4 || spans[0].Style.Foreground == nil || spans[0].Style.Foreground.Index == nil || *spans[0].Style.Foreground.Index != 2 {
		t.Fatalf("GBK colour ranges = %+v", spans)
	}
}

func TestConsoleEncodingSettingIsCapturedForEachNewDecoder(t *testing.T) {
	h := newHarness(t, core.NewClient())
	h.app.setConsoleEncoding("gbk")
	before := newOutputDecoder(h.app.kernel, h.app.outputEncodingPolicy())
	h.app.setConsoleEncoding("utf-8")
	after := newOutputDecoder(h.app.kernel, h.app.outputEncodingPolicy())
	for _, scenario := range []struct {
		decoder *outputDecoder
		want    string
	}{{before, "茅"}, {after, "é"}} {
		chunk, err := scenario.decoder.decode("é\n")
		if err != nil || len(chunk.lines) != 1 || chunk.lines[0].text != scenario.want {
			t.Fatalf("decoded = %+v, err = %v, want %q", chunk, err, scenario.want)
		}
	}
	h.settle()
	var stored settings
	if _, err := h.store.Load(settingsFile, &stored); err != nil || stored.ConsoleEncoding != "utf-8" {
		t.Fatalf("saved encoding = %q, err = %v", stored.ConsoleEncoding, err)
	}
}

func TestConsoleDecoderCarriesCharactersAcrossItsOwnPieces(t *testing.T) {
	d := newOutputDecoder(core.NewClient(), core.OutputEncodingPolicy{Setting: "gbk"})
	// Bound the unfinished line below Core's line limit, with a GBK lead byte at the
	// desktop's 256 KiB piece boundary.
	prefix := strings.Repeat("x\n", outputDecodePiece/2-1) + "x"
	chunk, err := d.decode(prefix + "\xb9\xb9\n")
	if err != nil || len(chunk.lines) == 0 || chunk.lines[len(chunk.lines)-1].text != "x构" {
		t.Fatalf("last decoded line was corrupted, err = %v", err)
	}
}
