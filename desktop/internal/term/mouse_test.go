package term

import (
	"bytes"
	"strconv"
	"testing"
)

func TestAppendMouse(t *testing.T) {
	for _, test := range []struct {
		name  string
		modes Modes
		event MouseEvent
		want  []byte
		ok    bool
	}{
		{
			name:  "x10 press",
			modes: Modes{Mouse: MouseX10},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonLeft, Column: 4, Row: 2},
			want:  []byte{'\x1b', '[', 'M', 32, 37, 35}, ok: true,
		},
		{
			name:  "x10 clamps coordinates",
			modes: Modes{Mouse: MouseButton},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonRight, Column: 999, Row: 500},
			want:  []byte{'\x1b', '[', 'M', 34, 255, 255}, ok: true,
		},
		{
			name:  "utf8 extended coordinates",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingUTF8},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonMiddle, Column: 222, Row: 2014},
			want:  []byte("\x1b[M!\xc3\xbf\xdf\xbf"), ok: true,
		},
		{
			name:  "sgr modified drag",
			modes: Modes{Mouse: MouseDrag, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseMotion, Button: MouseButtonLeft, Modifiers: MouseModifierShift | MouseModifierMeta | MouseModifierControl, Column: 11, Row: 7},
			want:  []byte("\x1b[<60;12;8M"), ok: true,
		},
		{
			name:  "sgr release keeps button",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseRelease, Button: MouseButtonRight, Column: 0, Row: 0},
			want:  []byte("\x1b[<2;1;1m"), ok: true,
		},
		{
			name:  "classic release uses button three",
			modes: Modes{Mouse: MouseButton},
			event: MouseEvent{Kind: MouseRelease, Button: MouseButtonRight, Modifiers: MouseModifierControl, Column: 0, Row: 0},
			want:  []byte{'\x1b', '[', 'M', 51, 33, 33}, ok: true,
		},
		{
			name:  "urxvt release uses button three",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingURXVT},
			event: MouseEvent{Kind: MouseRelease, Button: MouseButtonMiddle, Column: 0, Row: 0},
			want:  []byte("\x1b[35;1;1M"), ok: true,
		},
		{
			name:  "sgr any motion without button",
			modes: Modes{Mouse: MouseAny, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseMotion, Button: MouseButtonNone, Column: 3, Row: 9},
			want:  []byte("\x1b[<35;4;10M"), ok: true,
		},
		{
			name:  "urxvt wheel down",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingURXVT},
			event: MouseEvent{Kind: MouseWheel, Button: MouseWheelDown, Modifiers: MouseModifierControl, Column: 39, Row: 12},
			want:  []byte("\x1b[113;40;13M"), ok: true,
		},
		{
			name:  "off",
			modes: Modes{Mouse: MouseOff, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonLeft},
		},
		{
			name:  "x10 release",
			modes: Modes{Mouse: MouseX10, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseRelease, Button: MouseButtonLeft},
		},
		{
			name:  "button mode motion",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseMotion, Button: MouseButtonLeft},
		},
		{
			name:  "drag without button",
			modes: Modes{Mouse: MouseDrag, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MouseMotion, Button: MouseButtonNone},
		},
		{
			name:  "negative cell",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonLeft, Column: -1},
		},
		{
			name:  "sgr maximum coordinate does not overflow",
			modes: Modes{Mouse: MouseButton, MouseEncoding: MouseEncodingSGR},
			event: MouseEvent{Kind: MousePress, Button: MouseButtonLeft, Column: int(^uint(0) >> 1), Row: 0},
			want:  []byte("\x1b[<0;" + strconv.Itoa(int(^uint(0)>>1)) + ";1M"), ok: true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			prefix := []byte("prefix")
			got, ok := AppendMouse(prefix, test.modes, test.event)
			if ok != test.ok || !bytes.Equal(got, append([]byte("prefix"), test.want...)) {
				t.Fatalf("AppendMouse() = %v, %t; want %v, %t", got, ok, append([]byte("prefix"), test.want...), test.ok)
			}
		})
	}
}

func FuzzAppendMouse(f *testing.F) {
	f.Add(uint8(MouseAny), uint8(MouseEncodingSGR), uint8(MouseMotion), uint8(MouseButtonNone), uint8(7), 10, 20)
	f.Add(uint8(MouseButton), uint8(MouseEncodingUTF8), uint8(MousePress), uint8(MouseButtonLeft), uint8(0), 222, 2014)
	f.Fuzz(func(t *testing.T, mode, encoding, kind, button, modifiers uint8, column, row int) {
		modes := Modes{Mouse: MouseMode(mode % 5), MouseEncoding: MouseEncoding(encoding % 4)}
		event := MouseEvent{
			Kind: MouseEventKind(kind % 6), Button: MouseEventButton(button % 10),
			Modifiers: MouseModifiers(modifiers), Column: column, Row: row,
		}
		prefix := []byte("keep")
		got, ok := AppendMouse(prefix, modes, event)
		if !bytes.HasPrefix(got, prefix) {
			t.Fatalf("prefix changed: %v", got)
		}
		if !ok && len(got) != len(prefix) {
			t.Fatalf("rejected event appended %d bytes", len(got)-len(prefix))
		}
		if ok && len(got)-len(prefix) > 80 {
			t.Fatalf("report is %d bytes", len(got)-len(prefix))
		}
	})
}

func BenchmarkAppendMouse(b *testing.B) {
	modes := Modes{Mouse: MouseDrag, MouseEncoding: MouseEncodingSGR}
	event := MouseEvent{Kind: MouseMotion, Button: MouseButtonLeft, Modifiers: MouseModifierControl, Column: 119, Row: 39}
	buffer := make([]byte, 0, 32)
	b.ReportAllocs()
	for b.Loop() {
		var ok bool
		buffer, ok = AppendMouse(buffer[:0], modes, event)
		if !ok {
			b.Fatal("mouse event was rejected")
		}
	}
}
