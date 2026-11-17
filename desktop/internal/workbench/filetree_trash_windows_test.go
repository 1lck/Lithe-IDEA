//go:build windows

package workbench

import (
	"context"
	"testing"

	"golang.org/x/sys/windows"
)

// The trash helper is a console program started by a GUI program: without CREATE_NO_WINDOW every
// deletion opened a terminal window. HideWindow stays off so the error dialog the helper shows for
// a file in use is not hidden from the user.
func TestTrashCommandStartsWithoutAConsoleAndKeepsItsDialogsVisible(t *testing.T) {
	cmd := trashCommand(context.Background(), `C:\Users\Test User\sample project\notes.txt`)
	attr := cmd.SysProcAttr
	if attr == nil || attr.CreationFlags&windows.CREATE_NO_WINDOW == 0 {
		t.Fatalf("trash command process attributes = %+v; want CREATE_NO_WINDOW", attr)
	}
	if attr.HideWindow {
		t.Fatal("trash command hides its first window, which can be the error dialog it waits on")
	}
}
