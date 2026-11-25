package fileassociations

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit -framework CoreServices -framework UniformTypeIdentifiers
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>

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

static UTType *lithe_association_type(const char *extension) {
	NSString *suffix = [[NSString stringWithUTF8String:extension] substringFromIndex:1];
	return [UTType typeWithFilenameExtension:suffix];
}

static char *lithe_association_type_id(const char *extension) {
	@autoreleasepool {
		UTType *type = lithe_association_type(extension);
		return type == nil ? NULL : strdup(type.identifier.UTF8String);
	}
}

// Each field is NUL-terminated: default bundle ID, display name, offered flag.
// The caller frees the buffer.
static char *lithe_association_read(const char *extension, const char *identity, size_t *size) {
	@autoreleasepool {
		UTType *type = lithe_association_type(extension);
		NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
		NSURL *preferredURL = type == nil ? nil : [workspace URLForApplicationToOpenContentType:type];
		NSString *preferred = preferredURL == nil ? nil : [NSBundle bundleWithURL:preferredURL].bundleIdentifier;
		NSArray<NSURL *> *handlers = type == nil ? @[] : [workspace URLsForApplicationsToOpenContentType:type];
		NSString *ours = [NSString stringWithUTF8String:identity];
		NSString *name = preferredURL == nil ? @"" :
			[[NSFileManager defaultManager] displayNameAtPath:preferredURL.path];
		BOOL offered = NO;
		for (NSURL *handler in handlers) {
			NSString *bundleID = [NSBundle bundleWithURL:handler].bundleIdentifier;
			if (bundleID != nil && [bundleID caseInsensitiveCompare:ours] == NSOrderedSame) offered = YES;
		}
		NSMutableData *data = [NSMutableData data];
		for (NSString *field in @[preferred ?: @"", name ?: @"", offered ? @"1" : @"0"]) {
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

// The caller and completion block each own a reference. Cancellation releases
// the caller without freeing memory a later system-consent callback still uses.
typedef struct {
	atomic_int references;
	atomic_bool done;
	atomic_bool cancelled;
	bool failed;
	long code;
	char domain[256];
} lithe_association_request;

// NSWorkspace cannot revoke consent already presented by the OS. Keep at most
// one such request, including after the Go caller's deadline has expired.
static atomic_bool lithe_association_pending = false;

static void lithe_association_release(lithe_association_request *request) {
	if (atomic_fetch_sub(&request->references, 1) == 1) {
		free(request);
	}
}

static lithe_association_request *lithe_association_default(const char *path, const char *identifier, int *pending) {
	@autoreleasepool {
		*pending = atomic_exchange(&lithe_association_pending, true);
		if (*pending) return NULL;
		lithe_association_request *request = calloc(1, sizeof(*request));
		if (request == NULL) {
			atomic_store(&lithe_association_pending, false);
			return NULL;
		}
		atomic_init(&request->references, 2);
		atomic_init(&request->done, false);
		atomic_init(&request->cancelled, false);
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
		UTType *type = [UTType typeWithIdentifier:[NSString stringWithUTF8String:identifier]];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (atomic_load(&request->cancelled)) {
				atomic_store(&lithe_association_pending, false);
				lithe_association_release(request);
				return;
			}
			[[NSWorkspace sharedWorkspace] setDefaultApplicationAtURL:url toOpenContentType:type completionHandler:^(NSError *error) {
				if (error != nil) {
					request->failed = true;
					request->code = error.code;
					snprintf(request->domain, sizeof(request->domain), "%s", error.domain.UTF8String);
				}
				atomic_store(&lithe_association_pending, false);
				atomic_store(&request->done, true);
				lithe_association_release(request);
			}];
		});
		return request;
	}
}

static int lithe_association_done(lithe_association_request *request) {
	return atomic_load(&request->done);
}

static void lithe_association_cancel(lithe_association_request *request) {
	atomic_store(&request->cancelled, true);
}

static int lithe_association_matches(const char *path, const char *identifier) {
	@autoreleasepool {
		UTType *type = [UTType typeWithIdentifier:[NSString stringWithUTF8String:identifier]];
		NSURL *preferred = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenContentType:type];
		NSString *actual = preferred == nil ? nil : [NSBundle bundleWithURL:preferred].bundleIdentifier;
		NSString *ours = lithe_association_identity(path);
		return actual != nil && ours != nil && [actual caseInsensitiveCompare:ours] == NSOrderedSame;
	}
}
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
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
		if len(fields) != 4 {
			return State{}, fmt.Errorf("file associations: invalid native handler response")
		}
		// Launch Services chooses an application URL heuristically when several
		// copies share a bundle ID. That lookup is not a registration revision.
		revision := sha256.Sum256([]byte(fields[2]))
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
	path := C.CString(state.bundle)
	defer C.free(unsafe.Pointer(path))
	if status := C.lithe_association_register(path); status != 0 {
		return fmt.Errorf("file associations: LSRegisterURL status %d", int(status))
	}
	var failures []error
	var failed []string
	seen := make(map[string]error, len(extensions))
	for _, extension := range extensions {
		if err := ctx.Err(); err != nil {
			if len(failures) == 0 {
				return err
			}
			return errors.Join(&FormatError{Extensions: failed, Err: errors.Join(failures...)}, err)
		}
		identifier, err := contentType(extension)
		if err == nil {
			var submitted bool
			err, submitted = seen[identifier]
			if !submitted {
				err = setDefaultContentType(ctx, state.bundle, identifier)
				seen[identifier] = err
			}
		}
		if err != nil {
			if errors.Is(err, ErrConfirmationPending) || (ctx.Err() != nil && errors.Is(err, ctx.Err())) {
				if len(failures) == 0 {
					return err
				}
				return errors.Join(&FormatError{Extensions: failed, Err: errors.Join(failures...)}, err)
			}
			failed = append(failed, extension)
			failures = append(failures, fmt.Errorf("%s: %w", extension, err))
		}
	}
	if len(failures) != 0 {
		return &FormatError{Extensions: failed, Err: errors.Join(failures...)}
	}
	return nil
}

func contentType(extension string) (string, error) {
	value := C.CString(extension)
	defer C.free(unsafe.Pointer(value))
	identifier := C.lithe_association_type_id(value)
	if identifier == nil {
		return "", fmt.Errorf("file associations: no macOS content type for %s", extension)
	}
	defer C.free(unsafe.Pointer(identifier))
	return C.GoString(identifier), nil
}

func setDefaultContentType(ctx context.Context, bundle, identifier string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	path, kind := C.CString(bundle), C.CString(identifier)
	defer C.free(unsafe.Pointer(path))
	defer C.free(unsafe.Pointer(kind))
	if C.lithe_association_matches(path, kind) != 0 {
		return nil
	}
	var pending C.int
	request := C.lithe_association_default(path, kind, &pending)
	if request == nil {
		if pending != 0 {
			return ErrConfirmationPending
		}
		return fmt.Errorf("file associations: native request allocation failed")
	}
	defer C.lithe_association_release(request)
	// NSWorkspace owns the asynchronous consent UI and exposes no cancellation
	// handle. Only the active request can finish after cancellation; no further
	// content types are submitted. The bounded wait never blocks the UI thread.
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		if C.lithe_association_done(request) != 0 {
			if request.failed {
				return fmt.Errorf("file associations: NSWorkspace.setDefaultApplication type %s: %s code %d", identifier, C.GoString(&request.domain[0]), int(request.code))
			}
			if C.lithe_association_matches(path, kind) == 0 {
				return fmt.Errorf("file associations: macOS did not confirm the requested default for type %s", identifier)
			}
			return nil
		}
		select {
		case <-ctx.Done():
			C.lithe_association_cancel(request)
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
