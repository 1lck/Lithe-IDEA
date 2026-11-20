package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
)

// BenchmarkOutputEncodingBridge compares the previous text request and the byte request
// through the actual C ABI, including Go JSON, base64, Rust decoding and response parsing.
// The same Core binary retains the text command, so the two paths share compiler settings.
// Mixed input has no text baseline: JSON would replace GBK before Core sees it.
func BenchmarkOutputEncodingBridge(b *testing.B) {
	for _, kind := range []string{"ascii", "utf8", "mixed-1pct-gbk", "gbk"} {
		for _, chunkSize := range []int{4096, 32768} {
			data, expected := outputEncodingBenchmarkData(kind)
			for _, mode := range []string{"text", "bytes"} {
				if mode == "text" && (kind == "mixed-1pct-gbk" || kind == "gbk") {
					continue
				}
				b.Run(fmt.Sprintf("%s/%d/%s", kind, chunkSize, mode), func(b *testing.B) {
					client := NewClient()
					ctx := context.Background()
					// Chunk once outside the timed loop. Split both paths on the same UTF-8
					// boundary: the old caller held incomplete characters before JSON.
					var chunks [][]byte
					for remaining := data; len(remaining) > 0; {
						end := min(len(remaining), chunkSize)
						if kind == "utf8" && end < len(remaining) {
							for end > 0 && remaining[end]&0xc0 == 0x80 {
								end--
							}
						}
						chunks = append(chunks, remaining[:end])
						remaining = remaining[end:]
					}
					run := func(check bool) {
						var state json.RawMessage
						line := 0
						for _, chunk := range chunks {
							var decoded OutputStyleDecoding
							var err error
							if mode == "bytes" {
								decoded, err = client.DecodeOutputStyle(ctx, chunk, OutputEncodingPolicy{Windows: true}, state)
							} else {
								err = client.Execute(ctx, "outputStyle.decode", struct {
									Text  string          `json:"text"`
									State json.RawMessage `json:"state,omitempty"`
								}{string(chunk), state}, &decoded)
							}
							if err != nil {
								b.Fatal(err)
							}
							if check {
								for _, got := range decoded.Lines {
									if line >= len(expected) || got.Text != expected[line] {
										b.Fatalf("line %d decoded incorrectly: %q", line, got.Text)
									}
									line++
								}
							}
							state = decoded.State
						}
						if check && line != len(expected) {
							b.Fatalf("decoded %d lines, want %d", line, len(expected))
						}
					}
					run(true)
					b.ReportAllocs()
					b.SetBytes(int64(len(data)))
					b.ResetTimer()
					for b.Loop() {
						run(false)
					}
				})
			}
		}
	}
}

// Each batch is about 256 KiB, with one GBK line in every hundred in the mixed case.
func outputEncodingBenchmarkData(kind string) ([]byte, []string) {
	ascii := []byte("[INFO] compile src/Example.java:42 finished successfully; module=example; duration=123ms\n")
	utf8 := []byte("[INFO] 编译 src/Example.java:42 构建成功；模块=example；耗时=123ms\n")
	gbk := []byte("[INFO] \xb1\xe0\xd2\xeb src/Example.java:42 \xb9\xb9\xbd\xa8\xb3\xc9\xb9\xa6; module=example; duration=123ms\n")
	gbkText := "[INFO] 编译 src/Example.java:42 构建成功; module=example; duration=123ms"
	var data []byte
	var expected []string
	for i := 0; len(data) < 256<<10; i++ {
		line, text := utf8, string(bytes.TrimSuffix(utf8, []byte{'\n'}))
		if kind == "ascii" {
			line, text = ascii, string(bytes.TrimSuffix(ascii, []byte{'\n'}))
		} else if kind == "gbk" || (kind == "mixed-1pct-gbk" && i%100 == 99) {
			line, text = gbk, gbkText
		}
		data = append(data, line...)
		expected = append(expected, text)
	}
	return data, expected
}
