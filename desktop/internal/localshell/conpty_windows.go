//go:build windows

package localshell

import (
	"errors"
	"fmt"
	"sync"
	"syscall"
	"unsafe"

	"github.com/1lck/Lithe-IDEA/desktop/internal/localshell/conpty"
	"golang.org/x/sys/windows"
)

// pseudoConsole is one ConPTY implementation: the inbox one exported by kernel32, or the
// bundled modern one from conpty.dll. A console is resized and closed with the
// implementation that created it.
type pseudoConsole struct {
	create func(size windows.Coord, in, out windows.Handle, flags uint32, console *windows.Handle) error
	resize func(console windows.Handle, size windows.Coord) error
	close  func(console windows.Handle)
}

func systemPseudoConsole() pseudoConsole {
	return pseudoConsole{
		create: func(size windows.Coord, in, out windows.Handle, flags uint32, console *windows.Handle) error {
			return windows.CreatePseudoConsole(size, in, out, flags, console)
		},
		resize: func(console windows.Handle, size windows.Coord) error {
			return windows.ResizePseudoConsole(console, size)
		},
		close: windows.ClosePseudoConsole,
	}
}

var (
	bundledOnce sync.Once
	bundled     *pseudoConsole
	// bundledErr is why bundled is nil: conpty.ErrUnavailable for a build that carries no
	// ConPTY, else the failure to install or load it.
	bundledErr error
	// conptyRootOverride is where a test installs the ConPTY; in the application it is
	// empty and the ConPTY is installed in the user's cache directory (conpty.DefaultRoot).
	conptyRootOverride string
)

// bundledConPTY installs the ConPTY this build carries and loads its conpty.dll, once per
// process. A ConPTY that cannot be installed or loaded is not fatal: the caller falls back
// to the inbox ConPTY, which works everywhere but re-renders the program's output.
func bundledConPTY() (*pseudoConsole, error) {
	bundledOnce.Do(func() {
		root := conptyRootOverride
		if root == "" {
			var err error
			if root, err = conpty.DefaultRoot(); err != nil {
				bundledErr = err
				return
			}
		}
		path, err := conpty.Install(root)
		if err != nil {
			bundledErr = err
			return
		}
		console, err := loadPseudoConsole(path)
		if err != nil {
			bundledErr = err
			return
		}
		bundled = &console
	})
	return bundled, bundledErr
}

// loadPseudoConsole loads the modern ConPTY and returns its entry points. The module stays
// loaded for the life of the process; unloading it is not a meaningful saving and would
// invalidate consoles still using it. The DLL's own folder and System32 are the only
// places its dependencies are looked for, so nothing planted on the PATH or in the working
// directory is loaded with it.
func loadPseudoConsole(path string) (pseudoConsole, error) {
	dll, err := windows.LoadLibraryEx(path, 0, windows.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|windows.LOAD_LIBRARY_SEARCH_SYSTEM32)
	if err != nil {
		return pseudoConsole{}, fmt.Errorf("localshell: load conpty.dll: %w", err)
	}
	procedure := func(name string) (uintptr, error) {
		address, err := windows.GetProcAddress(dll, name)
		if err != nil {
			return 0, fmt.Errorf("localshell: conpty.dll %s: %w", name, err)
		}
		return address, nil
	}
	create, err := procedure("CreatePseudoConsole")
	if err != nil {
		return pseudoConsole{}, err
	}
	resize, err := procedure("ResizePseudoConsole")
	if err != nil {
		return pseudoConsole{}, err
	}
	closeConsole, err := procedure("ClosePseudoConsole")
	if err != nil {
		return pseudoConsole{}, err
	}
	return pseudoConsole{
		create: func(size windows.Coord, in, out windows.Handle, flags uint32, console *windows.Handle) error {
			r, _, _ := syscall.SyscallN(create, packedCoord(size), uintptr(in), uintptr(out), uintptr(flags), uintptr(unsafe.Pointer(console)))
			if int32(uint32(r)) < 0 {
				return fmt.Errorf("conpty.dll: CreatePseudoConsole: HRESULT 0x%08x", uint32(r))
			}
			return nil
		},
		resize: func(console windows.Handle, size windows.Coord) error {
			r, _, _ := syscall.SyscallN(resize, uintptr(console), packedCoord(size))
			if int32(uint32(r)) < 0 {
				return fmt.Errorf("conpty.dll: ResizePseudoConsole: HRESULT 0x%08x", uint32(r))
			}
			return nil
		},
		close: func(console windows.Handle) {
			syscall.SyscallN(closeConsole, uintptr(console))
		},
	}, nil
}

// createPseudoConsole uses the bundled ConPTY and falls back to the inbox one when the
// bundled one cannot be installed, loaded or create a console, so a broken install still
// opens a terminal (without the modern forwarding). degraded, when not nil, is told why a
// console the inbox ConPTY hosts is not on the bundled one; a build that carries no ConPTY
// is not degraded.
func createPseudoConsole(size windows.Coord, in, out windows.Handle, degraded func(error)) (windows.Handle, pseudoConsole, error) {
	var console windows.Handle
	modern, bundledErr := bundledConPTY()
	if modern != nil {
		err := modern.create(size, in, out, 0, &console)
		if err == nil {
			return console, *modern, nil
		}
		bundledErr = err
	}
	if errors.Is(bundledErr, conpty.ErrUnavailable) {
		bundledErr = nil
	}
	system := systemPseudoConsole()
	if err := system.create(size, in, out, 0, &console); err != nil {
		if bundledErr != nil {
			return 0, pseudoConsole{}, errors.Join(bundledErr, err)
		}
		return 0, pseudoConsole{}, err
	}
	if bundledErr != nil && degraded != nil {
		degraded(bundledErr)
	}
	return console, system, nil
}

func packedCoord(size windows.Coord) uintptr {
	return uintptr(uint32(uint16(size.X)) | uint32(uint16(size.Y))<<16)
}
