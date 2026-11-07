package term

import (
	"strconv"

	"github.com/vivaui/viva/ui"
)

// EncodeWin32Key turns a key event into one win32-input-mode packet:
//
//	CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _
//
// Vk and Sc are the Windows virtual-key and scan codes, Uc the UTF-16 code
// unit (zero for a key that types nothing), Kd 1 for a press and 0 for a
// release, Cs the console control-key bitset and Rc the repeat count. It
// returns nil when the event carries no console identity, which is every key
// on a platform without one.
func EncodeWin32Key(event ui.KeyEvent) []byte {
	key := event.Win32
	if key.VirtualKey == 0 && key.Unicode == 0 {
		return nil
	}
	down := 1
	if event.Release {
		down = 0
	}
	repeat := key.Repeat
	if repeat == 0 {
		repeat = 1
	}
	b := make([]byte, 0, 32)
	b = append(b, "\x1b["...)
	b = strconv.AppendUint(b, uint64(key.VirtualKey), 10)
	b = append(b, ';')
	b = strconv.AppendUint(b, uint64(key.ScanCode), 10)
	b = append(b, ';')
	b = strconv.AppendUint(b, uint64(key.Unicode), 10)
	b = append(b, ';')
	b = strconv.AppendInt(b, int64(down), 10)
	b = append(b, ';')
	b = strconv.AppendUint(b, uint64(key.ControlState), 10)
	b = append(b, ';')
	b = strconv.AppendUint(b, uint64(repeat), 10)
	return append(b, '_')
}
