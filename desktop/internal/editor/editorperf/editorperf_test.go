package editorperf

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// lineEnd is the line end the document of a kind uses.
func lineEnd(kind Kind) string {
	if kind == Mixed {
		return "\r\n"
	}
	return "\n"
}

// recoverMessage runs f and returns the message of the panic it raised, or "" when it did not
// panic.
func recoverMessage(f func()) (message string) {
	defer func() {
		if r := recover(); r != nil {
			message = fmt.Sprint(r)
		}
	}()
	f()
	return ""
}

func TestTextShape(t *testing.T) {
	for _, kind := range Kinds() {
		t.Run(string(kind), func(t *testing.T) {
			text := Text(kind, SmallBytes)
			if again := Text(kind, SmallBytes); !bytes.Equal(text, again) {
				t.Fatal("two calls returned different text")
			}
			if len(text) < SmallBytes || len(text) >= SmallBytes+8192 {
				t.Fatalf("len = %d, want at least %d and less than %d", len(text), SmallBytes, SmallBytes+8192)
			}
			if !utf8.Valid(text) {
				t.Fatal("text is not valid UTF-8")
			}
			if !bytes.HasSuffix(text, []byte(lineEnd(kind))) {
				t.Fatalf("text does not end with %q", lineEnd(kind))
			}
			lines := bytes.Count(text, []byte("\n"))

			switch kind {
			case JSON:
				if lines != 1 || text[len(text)-1] != '\n' {
					t.Errorf("JSON has %d line ends, want exactly the last byte", lines)
				}
				if !bytes.HasPrefix(text, []byte(`{"items":[`)) {
					t.Errorf("JSON starts with %q", text[:20])
				}
				if !json.Valid(text) {
					t.Error("JSON is not valid")
				}
				return
			case Mixed:
				for i, c := range text {
					if c == '\n' && (i == 0 || text[i-1] != '\r') {
						t.Fatalf("bare LF at offset %d", i)
					}
				}
				if crlf := bytes.Count(text, []byte("\r\n")); crlf != lines {
					t.Errorf("%d CRLF line ends for %d LF", crlf, lines)
				}
			default:
				if bytes.IndexByte(text, '\r') >= 0 {
					t.Error("text contains a carriage return")
				}
			}
			if lines <= 200 {
				t.Errorf("%d lines, want more than 200", lines)
			}
			for _, line := range bytes.Split(text, []byte("\n")) {
				if len(line) > 1024 {
					t.Fatalf("line of %d bytes, want lines of at most 1 KiB", len(line))
				}
			}

			switch kind {
			case Go, Java:
				if !bytes.HasPrefix(text, []byte("package ")) {
					t.Errorf("text starts with %q, want a package clause", text[:20])
				}
			case Markdown:
				han := func(r rune) bool { return unicode.Is(unicode.Han, r) }
				if !strings.ContainsFunc(string(text), han) {
					t.Error("Markdown has no Chinese text")
				}
				if !bytes.Contains(text, []byte("```")) {
					t.Error("Markdown has no code fence")
				}
			}
		})
	}
}

func TestTextIsPrefixOfLarger(t *testing.T) {
	for _, kind := range Kinds() {
		if kind == JSON {
			continue
		}
		t.Run(string(kind), func(t *testing.T) {
			small, large := Text(kind, 8192), Text(kind, 65536)
			if !bytes.HasPrefix(large, small) {
				t.Fatal("the smaller document is not a prefix of the larger one")
			}
		})
	}
}

func TestGenerationIsIndependentOfTheCache(t *testing.T) {
	const n = 50_000
	want := generate(Java, n)
	if got := Text(Java, n); !bytes.Equal(got, want) {
		t.Fatal("the cached document differs from a fresh generation")
	}
	if again := generate(Java, n); !bytes.Equal(again, want) {
		t.Fatal("two fresh generations differ")
	}
}

func TestTextRejectsBadArguments(t *testing.T) {
	calls := map[string]func(){
		"unknown kind":  func() { Text("nope", 100) },
		"zero size":     func() { Text(Go, 0) },
		"negative size": func() { Text(Go, -1) },
	}
	for name, call := range calls {
		if recoverMessage(call) == "" {
			t.Errorf("%s: Text did not panic", name)
		}
	}
}

func TestLogTimestampsStrictlyIncrease(t *testing.T) {
	const stampLen = len("2026-11-09T08:15:42.123Z")
	previous, stamped := "", 0
	for _, line := range strings.Split(string(Text(Log, SmallBytes)), "\n") {
		// Stack trace lines start with a tab or a letter, never with a year.
		if len(line) < stampLen || line[0] != '2' {
			continue
		}
		stamp := line[:stampLen]
		if stamp <= previous {
			t.Fatalf("timestamp %s does not come after %s", stamp, previous)
		}
		previous = stamp
		stamped++
	}
	if stamped < 200 {
		t.Errorf("%d timestamped lines, want at least 200", stamped)
	}
}

func TestKindsAndLanguages(t *testing.T) {
	want := []Kind{Go, Java, JSON, Markdown, Log, Mixed}
	if got := Kinds(); !slices.Equal(got, want) {
		t.Fatalf("Kinds() = %v, want %v", got, want)
	}
	languages := map[Kind]string{Go: "go", Java: "java", JSON: "json", Markdown: "markdown", Log: "", Mixed: ""}
	for kind, language := range languages {
		if got := kind.Language(); got != language {
			t.Errorf("%s.Language() = %q, want %q", kind, got, language)
		}
	}
}

func TestParseBytes(t *testing.T) {
	valid := []struct {
		in   string
		want int
	}{
		{"10MiB", 10 << 20},
		{"10m", 10 << 20},
		{"2mib", 2 << 20},
		{"512KiB", 512 << 10},
		{"64KB", 64 << 10},
		{"4k", 4096},
		{"1.5MiB", 3 << 19},
		{"4.5KiB", 4608},
		{"4096", 4096},
		{"5000B", 5000},
		{" 2MiB ", 2 << 20},
		{"1G", 1 << 30},
		{"1GiB", 1 << 30},
	}
	for _, tc := range valid {
		got, err := ParseBytes(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("ParseBytes(%q) = %d, %v; want %d", tc.in, got, err, tc.want)
		}
	}

	invalid := []string{
		"", "  ", "0", "-1", "abc", "MiB", "1B", "4095", "2GiB", "1.3B", "4097.5B", "10XB", "1.2.3KiB",
	}
	for _, in := range invalid {
		got, err := ParseBytes(in)
		if err == nil {
			t.Errorf("ParseBytes(%q) = %d, want an error", in, got)
			continue
		}
		if !strings.Contains(err.Error(), strconv.Quote(in)) {
			t.Errorf("ParseBytes(%q) error %q does not name the input", in, err)
		}
	}
}

func TestSizeName(t *testing.T) {
	tests := []struct {
		n    int
		want string
	}{
		{100 << 10, "100KiB"},
		{10 << 20, "10MiB"},
		{1 << 30, "1GiB"},
		{4096, "4KiB"},
		{1536, "1536B"},
		{5000, "5000B"},
		{1536 << 10, "1536KiB"},
	}
	for _, tc := range tests {
		if got := SizeName(tc.n); got != tc.want {
			t.Errorf("SizeName(%d) = %q, want %q", tc.n, got, tc.want)
		}
	}
}

func TestLargeHonorsTheEnvironment(t *testing.T) {
	t.Setenv(LargeBytesEnv, "2MiB")
	if got, want := Large(), (Size{Name: "2MiB", Bytes: 2 << 20}); got != want {
		t.Errorf("Large() = %+v, want %+v", got, want)
	}

	t.Setenv(LargeBytesEnv, "")
	if got, want := Large(), (Size{Name: "10MiB", Bytes: DefaultLargeBytes}); got != want {
		t.Errorf("Large() with an empty variable = %+v, want %+v", got, want)
	}

	t.Setenv(LargeBytesEnv, "lots")
	message := recoverMessage(func() { Large() })
	if message == "" {
		t.Fatal("Large() did not panic for an invalid value")
	}
	if !strings.Contains(message, LargeBytesEnv) {
		t.Errorf("panic message %q does not name %s", message, LargeBytesEnv)
	}
}

func TestSizes(t *testing.T) {
	// t.Setenv restores the original value when the test ends; the unset makes the variable
	// absent and not merely empty.
	t.Setenv(LargeBytesEnv, "")
	if err := os.Unsetenv(LargeBytesEnv); err != nil {
		t.Fatal(err)
	}
	want := []Size{Small(), {Name: "10MiB", Bytes: DefaultLargeBytes}}
	if got := Sizes(); !slices.Equal(got, want) {
		t.Errorf("Sizes() = %+v, want %+v", got, want)
	}
	if small := Small(); small.Name != "100KiB" || small.Bytes != SmallBytes {
		t.Errorf("Small() = %+v", small)
	}

	t.Setenv(LargeBytesEnv, "100KiB")
	if got := Sizes(); len(got) != 1 || got[0] != Small() {
		t.Errorf("Sizes() with the large size equal to the small one = %+v, want only %+v", got, Small())
	}
}
