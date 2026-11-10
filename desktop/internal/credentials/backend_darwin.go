//go:build darwin

package credentials

/*
#cgo CFLAGS: -Wno-deprecated-declarations
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <stdlib.h>
#include <string.h>
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>

static CFMutableDictionaryRef lithe_query(const char *service, const char *account, int noUI) {
	CFMutableDictionaryRef query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFStringRef s = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
	CFStringRef a = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
	CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
	CFDictionarySetValue(query, kSecAttrService, s);
	CFDictionarySetValue(query, kSecAttrAccount, a);
	if (noUI) {
		// Reading an item another app wrote can show a password prompt. A
		// migration is not a user action, so it must fail closed instead.
		CFDictionarySetValue(query, kSecUseAuthenticationUI, kSecUseAuthenticationUIFail);
	}
	CFRelease(s);
	CFRelease(a);
	return query;
}

static CFDataRef lithe_data(const unsigned char *bytes, int length) {
	return CFDataCreate(NULL, bytes, length);
}

static int lithe_kc_get(const char *service, const char *account, int noUI, unsigned char **out, int *outLength) {
	CFMutableDictionaryRef query = lithe_query(service, account, noUI);
	CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
	CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
	CFTypeRef result = NULL;
	OSStatus status = SecItemCopyMatching(query, &result);
	CFRelease(query);
	if (status == errSecSuccess && result != NULL) {
		CFIndex length = CFDataGetLength((CFDataRef)result);
		*out = malloc(length > 0 ? length : 1);
		memcpy(*out, CFDataGetBytePtr((CFDataRef)result), length);
		*outLength = (int)length;
		CFRelease(result);
	}
	return (int)status;
}

static int lithe_kc_set(const char *service, const char *account, const unsigned char *bytes, int length) {
	CFMutableDictionaryRef query = lithe_query(service, account, 0);
	CFDataRef data = lithe_data(bytes, length);
	CFMutableDictionaryRef update = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(update, kSecValueData, data);
	OSStatus status = SecItemUpdate(query, update);
	CFRelease(update);
	if (status == errSecItemNotFound) {
		CFDictionarySetValue(query, kSecValueData, data);
		CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
		status = SecItemAdd(query, NULL);
	}
	CFRelease(data);
	CFRelease(query);
	return (int)status;
}

static int lithe_kc_delete(const char *service, const char *account, int noUI) {
	CFMutableDictionaryRef query = lithe_query(service, account, noUI);
	OSStatus status = SecItemDelete(query);
	CFRelease(query);
	return (int)status;
}
*/
import "C"

import (
	"fmt"
	"unsafe"
)

const (
	statusSuccess      = 0
	statusItemNotFound = -25300
)

// Older macOS clients stored plugin credentials under
// "<bundle id>.plugin-credentials.<plugin ID>" with the plugin's own key as the
// account (MacPluginCredentialStore). The stable and the development bundle ids
// are both read, in that order.
var legacyPrefixes = []string{
	"app.lithe.desktop.plugin-credentials",
	"app.lithe.desktop.dev.plugin-credentials",
}

type keychainBackend struct{ noUI bool }

func platformBackend() Backend { return keychainBackend{} }

func platformLegacy() Legacy { return keychainLegacy{} }

func (b keychainBackend) Get(service, account string) (string, error) {
	cs, ca := C.CString(service), C.CString(account)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))
	noUI := C.int(0)
	if b.noUI {
		noUI = 1
	}
	var out *C.uchar
	var length C.int
	status := int(C.lithe_kc_get(cs, ca, noUI, &out, &length))
	switch status {
	case statusSuccess:
		data := C.GoBytes(unsafe.Pointer(out), length)
		// Clear the C copy before it goes back to the allocator.
		C.memset(unsafe.Pointer(out), 0, C.size_t(length))
		C.free(unsafe.Pointer(out))
		return string(data), nil
	case statusItemNotFound:
		return "", ErrNotFound
	}
	return "", keychainError(status)
}

func (b keychainBackend) Set(service, account, secret string) error {
	cs, ca := C.CString(service), C.CString(account)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))
	bytes := []byte(secret)
	var pointer *C.uchar
	if len(bytes) > 0 {
		pointer = (*C.uchar)(unsafe.Pointer(&bytes[0]))
	}
	if status := int(C.lithe_kc_set(cs, ca, pointer, C.int(len(bytes)))); status != statusSuccess {
		return keychainError(status)
	}
	return nil
}

func (b keychainBackend) Delete(service, account string) error {
	cs, ca := C.CString(service), C.CString(account)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(ca))
	noUI := C.int(0)
	if b.noUI {
		noUI = 1
	}
	status := int(C.lithe_kc_delete(cs, ca, noUI))
	switch status {
	case statusSuccess:
		return nil
	case statusItemNotFound:
		return ErrNotFound
	}
	return keychainError(status)
}

// keychainError names only the status code, never the item.
func keychainError(status int) error {
	return fmt.Errorf("keychain error %d", status)
}

// keychainLegacy reads the older clients' items without ever prompting.
type keychainLegacy struct{}

func (keychainLegacy) Read(pluginID, key string) (string, bool) {
	backend := keychainBackend{noUI: true}
	for _, prefix := range legacyPrefixes {
		if secret, err := backend.Get(prefix+"."+pluginID, key); err == nil {
			return secret, true
		}
	}
	return "", false
}

func (keychainLegacy) Delete(pluginID, key string) {
	backend := keychainBackend{noUI: true}
	for _, prefix := range legacyPrefixes {
		// Best effort: a refusal leaves the old item for the old client.
		_ = backend.Delete(prefix+"."+pluginID, key)
	}
}
