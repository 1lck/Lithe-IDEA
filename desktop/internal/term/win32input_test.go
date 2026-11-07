package term

import (
	"testing"

	"github.com/vivaui/viva/ui"
)

func TestEncodeWin32KeyPacket(t *testing.T) {
	event := ui.KeyEvent{Win32: ui.Win32Key{VirtualKey: 'A', ScanCode: 0x1e, Unicode: 'a', Repeat: 2}}
	if got, want := string(EncodeWin32Key(event)), "\x1b[65;30;97;1;0;2_"; got != want {
		t.Fatalf("press = %q, want %q", got, want)
	}
	event.Release = true
	if got, want := string(EncodeWin32Key(event)), "\x1b[65;30;97;0;0;2_"; got != want {
		t.Fatalf("release = %q, want %q", got, want)
	}
	if got := EncodeWin32Key(ui.KeyEvent{Text: "a"}); got != nil {
		t.Fatalf("an event without a console record encoded as %q", got)
	}
}

func TestWin32InputModeIsAcceptedOnlyWhereThePlatformHasIt(t *testing.T) {
	term := newTerm(20, 3)
	feed(term, "\x1b[?9001h")
	if win32InputSupported {
		if !term.Modes().Win32Input || term.modeState(9001, true) != 1 {
			t.Fatalf("9001 was not set: modes=%+v state=%d", term.Modes(), term.modeState(9001, true))
		}
	} else {
		if term.Modes().Win32Input || term.modeState(9001, true) != 0 {
			t.Fatalf("9001 was accepted without console key records: modes=%+v state=%d", term.Modes(), term.modeState(9001, true))
		}
	}
}
