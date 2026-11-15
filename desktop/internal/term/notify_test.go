package term

import (
	"encoding/base64"
	"strings"
	"testing"
)

func notifications(t *testing.T, writes ...string) []Notification {
	t.Helper()
	screen := New(40, 5, 10)
	var got []Notification
	screen.SetNotify(func(n Notification) { got = append(got, n) })
	for _, write := range writes {
		screen.Write([]byte(write))
	}
	return got
}

func TestOSC9IsAMessageButConEmuCommandsAreNot(t *testing.T) {
	got := notifications(t,
		"\x1b]9;Build finished\x07",
		"\x1b]9;4;1;50\x07",       // ConEmu progress
		"\x1b]9;9;/home/me\x1b\\", // ConEmu working directory
		"\x1b]9;3\x07",            // a single digit
		"\x1b]9;1 file copied\x1b\\",
	)
	if len(got) != 2 || got[0] != (Notification{Body: "Build finished"}) || got[1] != (Notification{Body: "1 file copied"}) {
		t.Fatalf("got %+v", got)
	}
}

func TestOSC777NotifyHasATitleAndABody(t *testing.T) {
	got := notifications(t, "\x1b]777;notify;Backup;done in 4s; really\x07", "\x1b]777;notify;Only title\x07", "\x1b]777;precmd\x07")
	want := []Notification{{Title: "Backup", Body: "done in 4s; really"}, {Title: "Only title"}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %+v", got)
	}
}

func TestOSC99ChunksComeTogetherAndASingleBodyIsTheMessage(t *testing.T) {
	got := notifications(t,
		"\x1b]99;i=1:d=0;Hel\x1b\\",
		"\x1b]99;i=1:d=0:p=body;It is \x1b\\",
		"\x1b]99;i=1:d=0;lo\x1b\\",
		"\x1b]99;i=1:p=body;done\x1b\\",
		"\x1b]99;;just text\x1b\\",
		"\x1b]99;i=2:p=body;lone body\x1b\\",
		"\x1b]99;i=3:e=1;"+base64.StdEncoding.EncodeToString([]byte("Héllo"))+"\x1b\\",
		"\x1b]99;i=4:p=icon;PNGDATA\x1b\\", // an icon is not text
	)
	want := []Notification{{Title: "Hello", Body: "It is done"}, {Title: "just text"}, {Title: "lone body"}, {Title: "Héllo"}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Errorf("notification %d = %+v, want %+v", index, got[index], want[index])
		}
	}
}

func TestNotificationsSurviveBeingSplitAcrossWrites(t *testing.T) {
	want := Notification{Title: "✳ АМНП 😀", Body: "中文 АМНП 😀"}
	for _, end := range []string{"\x07", "\x1b\\"} {
		sequence := "a\x1b]777;notify;" + want.Title + ";" + want.Body + end + "b"
		for cut := 0; cut <= len(sequence); cut++ {
			screen := newTerm(40, 3)
			var got []Notification
			screen.SetNotify(func(n Notification) { got = append(got, n) })
			feed(screen, sequence[:cut])
			feed(screen, sequence[cut:])
			if len(got) != 1 || got[0] != want {
				t.Fatalf("end %x cut %d: got %+v, want %+v", end, cut, got, want)
			}
			expectText(t, screen, "ab")
			expectCursor(t, screen, 2, 0)
		}
	}
}

func TestNotificationTextIsCleanedAndBounded(t *testing.T) {
	// The parser drops control bytes inside a string; what it lets through is cleaned again.
	got := notifications(t, "\x1b]777;notify;Tit\x00le;a\tb\x9bc\x07")
	if len(got) != 1 || got[0].Title != "Title" || got[0].Body != "abc" {
		t.Fatalf("got %+v", got)
	}
	long := strings.Repeat("é", 900)
	got = notifications(t, "\x1b]9;"+long[:1500]+"\x07")
	if len(got) != 1 || len(got[0].Body) > maxNotifyBody || strings.ContainsRune(got[0].Body, '�') {
		t.Fatalf("body %d bytes: %q", len(got[0].Body), got[0].Body[len(got[0].Body)-4:])
	}
	if got := notifications(t, "\x1b]9;\x07", "\x1b]777;notify;;\x07"); len(got) != 0 {
		t.Fatalf("empty notifications were reported: %+v", got)
	}
}

func TestUnfinishedOSC99NotificationsAreBounded(t *testing.T) {
	screen := New(40, 5, 10)
	count := 0
	screen.SetNotify(func(Notification) { count++ })
	for index := 0; index < 100; index++ {
		screen.Write([]byte("\x1b]99;i=" + strings.Repeat("x", index%7+1) + string(rune('a'+index%26)) + ":d=0;chunk\x1b\\"))
	}
	if len(screen.kittyNotes) > maxKittyPending || count != 0 {
		t.Fatalf("%d pending, %d shown", len(screen.kittyNotes), count)
	}
}

func FuzzNotifications(f *testing.F) {
	f.Add("\x1b]9;hello\x07")
	f.Add("\x1b]777;notify;a;b\x1b\\")
	f.Add("\x1b]99;i=1:d=0:p=body:e=1;aGk=\x1b\\")
	f.Fuzz(func(t *testing.T, input string) {
		screen := New(20, 4, 5)
		screen.SetNotify(func(n Notification) {
			if len(n.Title) > maxNotifyTitle || len(n.Body) > maxNotifyBody || strings.ContainsAny(n.Title+n.Body, "\x00\x1b\n\r") {
				t.Fatalf("unsafe notification %+v", n)
			}
		})
		screen.Write([]byte(input))
		if len(screen.kittyNotes) > maxKittyPending {
			t.Fatalf("%d pending", len(screen.kittyNotes))
		}
	})
}
