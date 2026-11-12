//go:build windows

package pluginservice

import (
	"errors"
	"fmt"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	kernel32                = windows.NewLazySystemDLL("kernel32.dll")
	procGetACP              = kernel32.NewProc("GetACP")
	procWideCharToMultiByte = kernel32.NewProc("WideCharToMultiByte")
)

const (
	codePageUTF8       = 65001
	wcNoBestFitChars   = 0x00000400
	argfileBackslash   = '\\'
	maxCodePageBytes   = 8
	errUnrepresentable = "the path character %q cannot be written in the system code page %d; move the project or its libraries to a path without it"
)

// encodeArgumentFile is the argument file as the Windows JDK launcher reads it: in the
// system (ANSI) code page, whatever the JDK version, since the launcher's arguments are not
// UTF-8. A character the code page cannot hold is an error, never a substitute. The
// launcher parses the file by bytes, so a backslash byte that is the trail byte of a
// double-byte character is doubled; Core quotes every value, so each is inside quotes.
func encodeArgumentFile(text string) ([]byte, error) {
	acp, _, _ := procGetACP.Call()
	if acp == codePageUTF8 {
		return []byte(text), nil
	}
	out := make([]byte, 0, len(text))
	var buffer [maxCodePageBytes]byte
	for _, r := range text {
		if r < 0x80 {
			out = append(out, byte(r))
			continue
		}
		units := utf16.Encode([]rune{r})
		var usedDefault int32
		n, _, err := procWideCharToMultiByte.Call(acp, wcNoBestFitChars,
			uintptr(unsafe.Pointer(&units[0])), uintptr(len(units)),
			uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)),
			0, uintptr(unsafe.Pointer(&usedDefault)))
		if n == 0 {
			if err == nil {
				err = errors.New("WideCharToMultiByte failed")
			}
			return nil, err
		}
		if usedDefault != 0 {
			return nil, fmt.Errorf(errUnrepresentable, r, acp)
		}
		for _, b := range buffer[:n] {
			if b == argfileBackslash {
				out = append(out, argfileBackslash)
			}
			out = append(out, b)
		}
	}
	return out, nil
}
