package fileapps

import (
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The shell's association handlers are what Explorer's Open With submenu lists. Each is a COM
// object (IAssocHandler) that names its application and opens a file with it the way the
// association says, which is also how a packaged app such as Photos is started. x/sys/windows
// declares none of these interfaces, so their methods are called through their vtables, in
// the order shobjidl.h declares them.
var (
	shell32                         = windows.NewLazySystemDLL("shell32.dll")
	shlwapi                         = windows.NewLazySystemDLL("shlwapi.dll")
	procSHAssocEnumHandlers         = shell32.NewProc("SHAssocEnumHandlers")
	procSHCreateItemFromParsingName = shell32.NewProc("SHCreateItemFromParsingName")
	procAssocQueryStringW           = shlwapi.NewProc("AssocQueryStringW")
)

const (
	// assocFilterRecommended is ASSOC_FILTER_RECOMMENDED: the handlers Explorer's submenu
	// lists, not every program that once registered for the extension.
	assocFilterRecommended = 1
	// assocStrExecutable and assocStrFriendlyAppName are ASSOCSTR values, and
	// assocNoTruncate the ASSOCF flag that fails rather than cut a long answer.
	assocStrExecutable      = 2
	assocStrFriendlyAppName = 4
	assocNoTruncate         = 0x20
	// rpcEChangedMode is RPC_E_CHANGED_MODE: the thread's COM apartment was set before.
	rpcEChangedMode = 0x80010106
	// maxHandlers bounds how many handlers are read, far more than an extension has.
	maxHandlers = 64
)

// Vtable slots: IUnknown's Release, IEnumAssocHandlers.Next, IAssocHandler's GetName,
// GetUIName and Invoke, and IShellItem.BindToHandler.
const (
	slotRelease       = 2
	slotNext          = 3
	slotGetName       = 3
	slotGetUIName     = 4
	slotInvoke        = 8
	slotBindToHandler = 3
)

var (
	iidIShellItem  = windows.GUID{Data1: 0x43826d1e, Data2: 0xe718, Data3: 0x42ee, Data4: [8]byte{0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe}}
	iidIDataObject = windows.GUID{Data1: 0x0000010e, Data2: 0x0000, Data3: 0x0000, Data4: [8]byte{0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
	bhidDataObject = windows.GUID{Data1: 0xb8c0bd9f, Data2: 0xed24, Data3: 0x455c, Data4: [8]byte{0x83, 0xe6, 0xd5, 0x39, 0x0c, 0x4f, 0xe8, 0xc4}}
)

// comObject is a COM interface pointer: its first word points to the vtable.
type comObject struct {
	vtable unsafe.Pointer
}

// call calls method slot of the interface with args after the object itself.
//
//go:uintptrescapes
func (o *comObject) call(slot int, args ...uintptr) uintptr {
	method := *(*uintptr)(unsafe.Add(o.vtable, uintptr(slot)*unsafe.Sizeof(uintptr(0))))
	r, _, _ := syscall.SyscallN(method, append([]uintptr{uintptr(unsafe.Pointer(o))}, args...)...)
	return r
}

func (o *comObject) release() { o.call(slotRelease) }

// text calls a method that returns a string the caller frees with CoTaskMemFree.
func (o *comObject) text(slot int) (string, error) {
	var value *uint16
	if hr := o.call(slot, uintptr(unsafe.Pointer(&value))); failed(hr) {
		return "", hresultError("IAssocHandler", hr)
	}
	defer windows.CoTaskMemFree(unsafe.Pointer(value))
	return windows.UTF16PtrToString(value), nil
}

func failed(hr uintptr) bool { return int32(uint32(hr)) < 0 }

func hresultError(call string, hr uintptr) error {
	return fmt.Errorf("fileapps: %s: %w", call, syscall.Errno(uint32(hr)))
}

func list(path string) ([]App, error) {
	extension := filepath.Ext(path)
	if extension == "" {
		return nil, nil
	}
	var apps []App
	err := withCOM(func() error {
		return eachHandler(extension, func(handler *comObject) (bool, error) {
			name, err := handler.text(slotGetName)
			if err != nil {
				return false, err
			}
			label, err := handler.text(slotGetUIName)
			if err != nil {
				return false, err
			}
			apps = append(apps, App{ID: name, Name: label})
			return true, nil
		})
	})
	if err != nil {
		return nil, err
	}
	markDefault(apps, assocQuery(assocStrExecutable, extension), assocQuery(assocStrFriendlyAppName, extension))
	return apps, nil
}

// markDefault marks the handler a double click starts and moves it to the front, keeping the
// others in the order Explorer lists them. The handler is found by its executable, or by its
// name for a packaged app, whose executable the association does not name.
func markDefault(apps []App, executable, name string) {
	at := -1
	for i := range apps {
		if executable != "" && strings.EqualFold(apps[i].ID, executable) {
			at = i
			break
		}
	}
	if at < 0 && name != "" {
		for i := range apps {
			if apps[i].Name == name {
				at = i
				break
			}
		}
	}
	if at < 0 {
		return
	}
	chosen := apps[at]
	chosen.Default = true
	copy(apps[1:at+1], apps[:at])
	apps[0] = chosen
}

// assocQuery is what the association of extension says for its default verb, or empty.
func assocQuery(what uint32, extension string) string {
	ext, err := windows.UTF16PtrFromString(extension)
	if err != nil {
		return ""
	}
	buffer := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(buffer))
	hr, _, _ := procAssocQueryStringW.Call(assocNoTruncate, uintptr(what), uintptr(unsafe.Pointer(ext)), 0, uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if failed(hr) {
		// log-exempt: 预期的缺失：没有默认关联的扩展名只是没有“默认”标记，列表照常显示。
		return ""
	}
	return windows.UTF16ToString(buffer)
}

func open(path string, app App) error {
	return withCOM(func() error {
		data, err := dataObject(path)
		if err != nil {
			return err
		}
		defer data.release()
		offered := false
		var invoked error
		err = eachHandler(filepath.Ext(path), func(handler *comObject) (bool, error) {
			name, err := handler.text(slotGetName)
			if err != nil {
				return false, err
			}
			if !strings.EqualFold(name, app.ID) {
				return true, nil
			}
			offered = true
			if hr := handler.call(slotInvoke, uintptr(unsafe.Pointer(data))); failed(hr) {
				invoked = hresultError("IAssocHandler::Invoke", hr)
			}
			return false, nil
		})
		switch {
		case err != nil:
			return err
		case !offered:
			return ErrNotOffered
		}
		return invoked
	})
}

// dataObject is the shell's data object of the file at path, which a handler opens.
func dataObject(path string) (*comObject, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	var item *comObject
	hr, _, _ := procSHCreateItemFromParsingName.Call(uintptr(unsafe.Pointer(name)), 0, uintptr(unsafe.Pointer(&iidIShellItem)), uintptr(unsafe.Pointer(&item)))
	if failed(hr) {
		return nil, hresultError("SHCreateItemFromParsingName", hr)
	}
	defer item.release()
	var data *comObject
	if hr := item.call(slotBindToHandler, 0, uintptr(unsafe.Pointer(&bhidDataObject)), uintptr(unsafe.Pointer(&iidIDataObject)), uintptr(unsafe.Pointer(&data))); failed(hr) {
		return nil, hresultError("IShellItem::BindToHandler", hr)
	}
	return data, nil
}

// eachHandler calls visit with each recommended handler of extension, in the order the shell
// gives them, until visit returns false or fails. The handler is released after visit.
func eachHandler(extension string, visit func(*comObject) (bool, error)) error {
	ext, err := windows.UTF16PtrFromString(extension)
	if err != nil {
		return err
	}
	var handlers *comObject
	hr, _, _ := procSHAssocEnumHandlers.Call(uintptr(unsafe.Pointer(ext)), assocFilterRecommended, uintptr(unsafe.Pointer(&handlers)))
	if failed(hr) {
		return hresultError("SHAssocEnumHandlers", hr)
	}
	defer handlers.release()
	for range maxHandlers {
		var handler *comObject
		var fetched uint32
		hr := handlers.call(slotNext, 1, uintptr(unsafe.Pointer(&handler)), uintptr(unsafe.Pointer(&fetched)))
		if failed(hr) {
			return hresultError("IEnumAssocHandlers::Next", hr)
		}
		if fetched == 0 || handler == nil {
			return nil
		}
		more, err := visit(handler)
		handler.release()
		if err != nil || !more {
			return err
		}
	}
	return nil
}

// withCOM runs work on one OS thread with a COM apartment, which the shell's objects need.
// A thread whose apartment another call set keeps it.
func withCOM(work func() error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	var errno syscall.Errno
	switch err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED); {
	case err == nil, errors.As(err, &errno) && errno == 1:
		// S_FALSE: the apartment was open already, and is closed as many times as opened.
		defer windows.CoUninitialize()
	case errors.As(err, &errno) && uint32(errno) == rpcEChangedMode:
	default:
		return fmt.Errorf("fileapps: CoInitializeEx: %w", err)
	}
	return work()
}
