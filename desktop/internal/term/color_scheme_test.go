package term

import (
	"strings"
	"testing"
)

// The color-scheme report answers light or dark from the default background: programs ask
// it once instead of reading the theme themselves.
func TestColorSchemeReportAnswersFromTheBackground(t *testing.T) {
	dark := newTerm(10, 3)
	var darkReplies []string
	dark.SetReply(func(b []byte) { darkReplies = append(darkReplies, string(b)) })
	dark.SetDefaultColors([3]uint8{0xdf, 0xe1, 0xe5}, [3]uint8{0x1e, 0x1f, 0x22})
	feed(dark, "\x1b[?997n")
	if want := []string{"\x1b[?997;1n"}; strings.Join(darkReplies, "|") != strings.Join(want, "|") {
		t.Fatalf("dark replies = %q, want %q", darkReplies, want)
	}

	light := newTerm(10, 3)
	var lightReplies []string
	light.SetReply(func(b []byte) { lightReplies = append(lightReplies, string(b)) })
	light.SetDefaultColors([3]uint8{0x1e, 0x1f, 0x22}, [3]uint8{0xff, 0xff, 0xff})
	feed(light, "\x1b[?997n")
	if want := []string{"\x1b[?997;2n"}; strings.Join(lightReplies, "|") != strings.Join(want, "|") {
		t.Fatalf("light replies = %q, want %q", lightReplies, want)
	}
}

// A program that subscribes with DECSET 2031 learns the current background at once and is
// told again whenever the theme changes the default background.
func TestBackgroundSubscriptionReportsTheThemeChange(t *testing.T) {
	term := newTerm(10, 3)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })
	term.SetDefaultColors([3]uint8{0x1e, 0x1f, 0x22}, [3]uint8{0xff, 0xff, 0xff})

	feed(term, "\x1b[?2031h")
	want := []string{
		"\x1b]11;rgb:ffff/ffff/ffff\x1b\\",
		"\x1b[?997;2n",
	}
	if strings.Join(replies, "|") != strings.Join(want, "|") {
		t.Fatalf("subscription replies = %q, want %q", replies, want)
	}

	replies = nil
	term.SetDefaultColors([3]uint8{0xdf, 0xe1, 0xe5}, [3]uint8{0x1e, 0x1f, 0x22})
	want = []string{
		"\x1b]11;rgb:1e1e/1f1f/2222\x1b\\",
		"\x1b[?997;1n",
	}
	if strings.Join(replies, "|") != strings.Join(want, "|") {
		t.Fatalf("change replies = %q, want %q", replies, want)
	}

	// Unsubscribing stops the reports.
	feed(term, "\x1b[?2031l")
	replies = nil
	term.SetDefaultColors([3]uint8{0xdf, 0xe1, 0xe5}, [3]uint8{0xff, 0xff, 0xff})
	if len(replies) != 0 {
		t.Fatalf("reports after DECRST 2031 = %q", replies)
	}
}

// Without a subscription a theme change tells no program anything.
func TestBackgroundChangeWithoutSubscriptionIsSilent(t *testing.T) {
	term := newTerm(10, 3)
	term.SetReply(func(b []byte) { t.Fatalf("unexpected reply %q", b) })
	term.SetDefaultColors([3]uint8{0x1e, 0x1f, 0x22}, [3]uint8{0xff, 0xff, 0xff})
	term.SetDefaultColors([3]uint8{0xdf, 0xe1, 0xe5}, [3]uint8{0x1e, 0x1f, 0x22})
}

// The mode query reports whether the program is subscribed, so a program can fall back to
// asking for the scheme itself.
func TestModeQueryReportsTheBackgroundSubscription(t *testing.T) {
	term := newTerm(10, 3)
	var replies []string
	term.SetReply(func(b []byte) { replies = append(replies, string(b)) })
	feed(term, "\x1b[?2031$p")
	feed(term, "\x1b[?2031h")
	feed(term, "\x1b[?2031$p")
	feed(term, "\x1b[?2031l")
	feed(term, "\x1b[?2031$p")
	joined := strings.Join(replies, "|")
	// The set answer also carries the subscription's own two reports between the queries.
	if !strings.Contains(joined, "\x1b[?2031;2$y") || !strings.Contains(joined, "\x1b[?2031;1$y") {
		t.Fatalf("replies = %q, want a reset and a set answer", joined)
	}
	if strings.Count(joined, "\x1b[?2031;2$y") != 2 {
		t.Fatalf("replies = %q, want two reset answers", joined)
	}
}
