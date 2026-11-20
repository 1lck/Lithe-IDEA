package cli

import (
	"context"
	"errors"
	"syscall"
	"unsafe"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const launcherName = "lithe.cmd"

type nativeSource struct {
	shell, target, text string
	kind                uint32
	exists              bool
}

func readNativeSource(ctx context.Context) (source nativeSource, err error) {
	if err := ctx.Err(); err != nil {
		return source, err
	}
	source = nativeSource{shell: "windows", target: `HKEY_CURRENT_USER\Environment\Path`, kind: registry.EXPAND_SZ}
	key, err := registry.OpenKey(registry.CURRENT_USER, `Environment`, registry.QUERY_VALUE)
	// log-exempt: 预期的缺失：首次注册前用户环境变量或 PATH 可以不存在。
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return source, nil
	}
	if err != nil {
		return source, err
	}
	defer func() { err = errors.Join(err, key.Close()) }()
	text, kind, err := key.GetStringValue("Path")
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		return source, nil
	}
	if err != nil {
		return source, err
	}
	if len(text) > maximumSourceBytes {
		return source, configfile.ErrTooLarge
	}
	source.text, source.kind, source.exists = text, kind, true
	return source, nil
}

func (s nativeSource) verify(ctx context.Context) error {
	current, err := readNativeSource(ctx)
	if err != nil {
		return err
	}
	if current.text != s.text || current.kind != s.kind || current.exists != s.exists {
		return configfile.ErrConflict
	}
	return nil
}

func (s nativeSource) replace(ctx context.Context, text string) (err error) {
	if err := s.verify(ctx); err != nil {
		return err
	}
	if text == s.text {
		return nil
	}
	key, _, err := registry.CreateKey(registry.CURRENT_USER, `Environment`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, key.Close()) }()
	if s.kind == registry.SZ {
		err = key.SetStringValue("Path", text)
	} else {
		err = key.SetExpandStringValue("Path", text)
	}
	if err != nil {
		return err
	}
	// Existing processes retain their environment. Explorer and new terminals learn
	// the user PATH through the standard bounded WM_SETTINGCHANGE broadcast.
	name, err := windows.UTF16PtrFromString("Environment")
	if err != nil {
		return err
	}
	var result uintptr
	call := windows.NewLazySystemDLL("user32.dll").NewProc("SendMessageTimeoutW")
	ok, _, callErr := call.Call(0xffff, 0x001a, 0, uintptr(unsafe.Pointer(name)), 2, 2000, uintptr(unsafe.Pointer(&result)))
	if ok == 0 {
		if callErr == syscall.Errno(0) {
			return errors.New("environment change broadcast timed out")
		}
		return callErr
	}
	return nil
}

func makeLauncherExecutable(string) error { return nil }
func launcherExecutable(string) bool      { return true }
