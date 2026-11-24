package fileassociations

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
	"github.com/vivaui/viva/app"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const applicationID = "app.lithe.viva"
const capabilitiesKey = `Software\` + applicationID + `\Capabilities`
const registeredApplicationsKey = `Software\RegisteredApplications`

var assocQuery = windows.NewLazySystemDLL("shlwapi.dll").NewProc("AssocQueryStringW")
var associationChanged = windows.NewLazySystemDLL("shell32.dll").NewProc("SHChangeNotify")

type nativeState struct{ executable string }

type registryValue struct{ path, name, text string }

func progID(extension string) string { return applicationID + extension }

// The owned verb lives under our per-format ProgID, which Viva's installer removes
// on uninstall. Before choosing Lithe as default, Explorer offers Open With through
// OpenWithProgids. No global catch-all or orphaned SystemFileAssociations key is needed.
func registrationValues(executable, extension, menuLabel string) []registryValue {
	application := `Software\Classes\Applications\` + filepath.Base(executable)
	class := `Software\Classes\` + progID(extension)
	command := `"` + executable + `" -- "%1"`
	icon := `"` + executable + `",0`
	return []registryValue{
		{registeredApplicationsKey, applicationID, capabilitiesKey},
		{capabilitiesKey, "ApplicationName", "Lithe Desktop"},
		{capabilitiesKey, "ApplicationDescription", "Lithe Desktop"},
		{capabilitiesKey, "ApplicationIcon", icon},
		{application, "FriendlyAppName", "Lithe Desktop"},
		{application + `\DefaultIcon`, "", icon},
		{application + `\shell\open\command`, "", command},
		{application + `\SupportedTypes`, extension, ""},
		{class, "", "Lithe Desktop " + extension},
		{class + `\DefaultIcon`, "", icon},
		{class + `\shell\open\command`, "", command},
		{`Software\Classes\` + extension + `\OpenWithProgids`, progID(extension), ""},
		{capabilitiesKey + `\FileAssociations`, extension, progID(extension)},
		{class + `\shell\Lithe`, "", menuLabel},
		{class + `\shell\Lithe`, "Icon", icon},
		{class + `\shell\Lithe\command`, "", command},
	}
}

func readRegistryValue(path, name string) (text string, exists bool, kind uint32, err error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		// log-exempt: 预期的缺失：尚未注册的格式没有 Lithe 注册表项。
		return "", false, 0, nil
	}
	if err != nil {
		return "", false, 0, err
	}
	defer func() { err = errors.Join(err, key.Close()) }()
	value, kind, err := key.GetValue(name, nil)
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
		// log-exempt: 预期的缺失：已存在的键可以尚未包含 Lithe 的值。
		return "", false, 0, nil
	}
	if err != nil {
		return "", false, 0, err
	}
	if value > 65536 {
		return "", false, 0, fmt.Errorf("file associations: registry value exceeds bounds")
	}
	data := make([]byte, value)
	_, kind, err = key.GetValue(name, data)
	if err != nil {
		return "", false, 0, err
	}
	// The hash observes even a changed value type; it never overwrites UserChoice.
	return string(data), true, kind, nil
}

func queryDefault(extension string, what uintptr) (string, error) {
	value, err := windows.UTF16PtrFromString(extension)
	if err != nil {
		return "", err
	}
	buffer := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(buffer))
	hr, _, _ := assocQuery.Call(0x20, what, uintptr(unsafe.Pointer(value)), 0,
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if int32(uint32(hr)) < 0 {
		// HRESULT_FROM_WIN32(ERROR_NO_ASSOCIATION), ERROR_FILE_NOT_FOUND, E_FAIL:
		// AssocQueryString returns these when no effective default is installed.
		if uint32(hr) == 0x80070483 || uint32(hr) == 0x80070002 || uint32(hr) == 0x80004005 {
			// log-exempt: 预期的缺失：系统尚未为该扩展名选择默认应用。
			return "", nil
		}
		return "", fmt.Errorf("file associations: AssocQueryString: %w", syscall.Errno(uint32(hr)))
	}
	return windows.UTF16ToString(buffer), nil
}

func readNative(ctx context.Context, formats []core.FileAssociationFormat) (State, error) {
	executable, err := installedpackage.Executable()
	if err != nil {
		return State{}, err
	}
	info, err := os.Stat(executable)
	if err != nil {
		return State{}, err
	}
	state := State{Formats: formats, Available: info.Mode().IsRegular() && strings.EqualFold(filepath.Base(executable), "lithe.exe"), native: nativeState{executable: executable}}
	for _, format := range formats {
		if err := ctx.Err(); err != nil {
			return State{}, err
		}
		// ASSOCSTR_PROGID observes the actual UserChoice result without opening it for write.
		identity, err := queryDefault(format.Extension, 20)
		if err != nil {
			return State{}, err
		}
		name, err := queryDefault(format.Extension, 4)
		if err != nil {
			return State{}, err
		}
		values := registrationValues(executable, format.Extension, "")
		hash := sha256.New()
		registered := false
		for _, value := range values {
			text, exists, kind, err := readRegistryValue(value.path, value.name)
			if err != nil {
				return State{}, err
			}
			fmt.Fprintf(hash, "%s\x00%s\x00%t:%d:%d:%s\x00", value.path, value.name, exists, kind, len(text), text)
			if value.path == capabilitiesKey+`\FileAssociations` && exists && kind == registry.SZ {
				// The capability value is UTF-16LE; read its string through the native API.
				key, err := registry.OpenKey(registry.CURRENT_USER, value.path, registry.QUERY_VALUE)
				if err != nil {
					return State{}, err
				}
				actual, _, readErr := key.GetStringValue(value.name)
				if err := errors.Join(readErr, key.Close()); err != nil {
					return State{}, err
				}
				registered = actual == progID(format.Extension)
			}
		}
		state.Handlers = append(state.Handlers, Handler{
			Extension: format.Extension, DefaultID: identity, DefaultName: name,
			IsDefault:  strings.EqualFold(identity, progID(format.Extension)),
			Registered: registered, registration: hex.EncodeToString(hash.Sum(nil)),
		})
	}
	return state, nil
}

func writeRegistryValue(value registryValue) (err error) {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, value.path, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, key.Close()) }()
	return key.SetStringValue(value.name, value.text)
}

func applyNative(ctx context.Context, state nativeState, extensions []string, menuLabel string) error {
	var failures []error
	var failed []string
	registered := false
	for _, extension := range extensions {
		complete := true
		for _, value := range registrationValues(state.executable, extension, menuLabel) {
			if err := ctx.Err(); err != nil {
				if len(failures) == 0 {
					return err
				}
				return errors.Join(&FormatError{Extensions: failed, Err: errors.Join(failures...)}, err)
			}
			if err := writeRegistryValue(value); err != nil {
				failed = append(failed, extension)
				failures = append(failures, fmt.Errorf("%s registry %s: %w", extension, value.path, err))
				complete = false
				break
			}
		}
		registered = registered || complete
	}
	// SHCNE_ASSOCCHANGED + SHCNF_IDLIST refreshes Explorer after all selected formats.
	associationChanged.Call(0x08000000, 0, 0, 0)
	var err error
	if len(failures) != 0 {
		err = &FormatError{Extensions: failed, Err: errors.Join(failures...)}
	}
	if cancel := ctx.Err(); cancel != nil {
		return errors.Join(err, cancel)
	}
	if !registered {
		return err
	}
	// UserChoice is protected by Windows. Its own UI owns the final consent.
	return errors.Join(err, app.OpenURL("ms-settings:defaultapps?registeredAppUser="+url.QueryEscape(applicationID)))
}
