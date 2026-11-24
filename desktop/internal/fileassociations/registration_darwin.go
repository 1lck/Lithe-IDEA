package fileassociations

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit -framework CoreServices -framework UniformTypeIdentifiers
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>

static NSString *lithe_association_identity(const char *path) {
	NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:path]];
	return bundle.bundleIdentifier;
}

static char *lithe_association_bundle_id(const char *path) {
	@autoreleasepool {
		NSString *identity = lithe_association_identity(path);
		return identity == nil ? NULL : strdup(identity.UTF8String);
	}
}

static CFStringRef lithe_association_type(const char *extension) {
	NSString *suffix = [[NSString stringWithUTF8String:extension] substringFromIndex:1];
	UTType *type = [UTType typeWithFilenameExtension:suffix];
	return type == nil ? NULL : (CFStringRef)CFRetain((__bridge CFTypeRef)type.identifier);
}

// Each field is NUL-terminated: default bundle ID, display name, offered flag,
// and the registered path for our bundle ID. The caller frees the buffer.
static char *lithe_association_read(const char *extension, const char *identity, size_t *size) {
	@autoreleasepool {
		CFStringRef type = lithe_association_type(extension);
		NSString *preferred = type == NULL ? nil : CFBridgingRelease(
			LSCopyDefaultRoleHandlerForContentType(type, kLSRolesAll));
		NSArray *handlers = type == NULL ? @[] : CFBridgingRelease(
			LSCopyAllRoleHandlersForContentType(type, kLSRolesAll));
		if (type != NULL) CFRelease(type);
		NSString *ours = [NSString stringWithUTF8String:identity];
		NSURL *preferredURL = preferred.length == 0 ? nil :
			[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:preferred];
		NSString *name = preferredURL == nil ? @"" :
			[[NSFileManager defaultManager] displayNameAtPath:preferredURL.path];
		NSURL *ourURL = ours.length == 0 ? nil :
			[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:ours];
		BOOL offered = NO;
		for (NSString *handler in handlers) {
			if ([handler caseInsensitiveCompare:ours] == NSOrderedSame) offered = YES;
		}
		NSMutableData *data = [NSMutableData data];
		for (NSString *field in @[preferred ?: @"", name ?: @"", offered ? @"1" : @"0", ourURL.path ?: @""]) {
			const char *value = field.UTF8String;
			[data appendBytes:value length:strlen(value)+1];
		}
		*size = data.length;
		void *result = malloc(data.length);
		if (result != NULL) memcpy(result, data.bytes, data.length);
		return result;
	}
}

static int lithe_association_register(const char *path) {
	@autoreleasepool {
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		return (int)LSRegisterURL((__bridge CFURLRef)url, true);
	}
}

static int lithe_association_default(const char *extension, const char *identity) {
	@autoreleasepool {
		CFStringRef type = lithe_association_type(extension);
		if (type == NULL) return (int)kLSUnknownTypeErr;
		NSString *bundleID = [NSString stringWithUTF8String:identity];
		OSStatus result = LSSetDefaultRoleHandlerForContentType(type, kLSRolesAll,
			(__bridge CFStringRef)bundleID);
		if (result == noErr) {
			NSString *actual = CFBridgingRelease(LSCopyDefaultRoleHandlerForContentType(type, kLSRolesAll));
			if (actual == nil || [actual caseInsensitiveCompare:bundleID] != NSOrderedSame) {
				result = kLSApplicationNotFoundErr;
			}
		}
		CFRelease(type);
		return (int)result;
	}
}
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"unsafe"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
)

type nativeState struct{ bundle, identity string }

func readNative(ctx context.Context, formats []core.FileAssociationFormat) (State, error) {
	bundle, err := installedpackage.Root()
	if err != nil {
		return State{}, err
	}
	path := C.CString(bundle)
	defer C.free(unsafe.Pointer(path))
	identity := C.lithe_association_bundle_id(path)
	state := State{Formats: formats, native: nativeState{bundle: bundle}}
	if identity != nil {
		defer C.free(unsafe.Pointer(identity))
		state.native.identity, state.Available = C.GoString(identity), true
	} else {
		// Development executables can read real defaults, but cannot register a bundle.
		identity = C.CString("")
		defer C.free(unsafe.Pointer(identity))
	}
	for _, format := range formats {
		if err := ctx.Err(); err != nil {
			return State{}, err
		}
		extension := C.CString(format.Extension)
		var size C.size_t
		raw := C.lithe_association_read(extension, identity, &size)
		C.free(unsafe.Pointer(extension))
		if raw == nil {
			return State{}, fmt.Errorf("file associations: native handler allocation failed")
		}
		data := C.GoStringN(raw, C.int(size))
		C.free(unsafe.Pointer(raw))
		fields := strings.Split(data, "\x00")
		if len(fields) != 5 {
			return State{}, fmt.Errorf("file associations: invalid native handler response")
		}
		revision := sha256.Sum256([]byte(fields[2] + "\x00" + fields[3]))
		state.Handlers = append(state.Handlers, Handler{
			Extension: format.Extension, DefaultID: fields[0], DefaultName: fields[1],
			IsDefault:  state.Available && strings.EqualFold(fields[0], state.native.identity),
			Registered: fields[2] == "1", registration: hex.EncodeToString(revision[:]),
		})
	}
	return state, nil
}

func applyNative(ctx context.Context, state nativeState, extensions []string, _ string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, identity := C.CString(state.bundle), C.CString(state.identity)
	defer C.free(unsafe.Pointer(path))
	defer C.free(unsafe.Pointer(identity))
	if status := C.lithe_association_register(path); status != 0 {
		return fmt.Errorf("file associations: LSRegisterURL status %d", int(status))
	}
	for _, extension := range extensions {
		if err := ctx.Err(); err != nil {
			return err
		}
		value := C.CString(extension)
		status := C.lithe_association_default(value, identity)
		C.free(unsafe.Pointer(value))
		if status != 0 {
			return fmt.Errorf("file associations: LSSetDefaultRoleHandlerForContentType status %d", int(status))
		}
	}
	return nil
}
