package fileapps

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

// lithe_file_apps returns the applications Launch Services offers for the file at path, as
// Finder's Open With menu shows them: the default first, then the others by their display
// names in Finder's order. Each is three NUL-terminated strings: "1" for the default or "0",
// the bundle's path and its display name. *size is the length of the malloc'd result, which
// the caller frees; NULL is no application.
static char *lithe_file_apps(const char *path, size_t *size) {
	*size = 0;
	@autoreleasepool {
		NSString *file = [NSString stringWithUTF8String:path];
		if (file == nil) {
			return NULL;
		}
		NSURL *url = [NSURL fileURLWithPath:file];
		NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
		NSFileManager *files = [NSFileManager defaultManager];
		NSString *preferred = [[workspace URLForApplicationToOpenURL:url] path];
		NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
		NSMutableArray<NSString *> *others = [NSMutableArray array];
		if (preferred != nil) {
			names[preferred] = [files displayNameAtPath:preferred];
		}
		for (NSURL *app in [workspace URLsForApplicationsToOpenURL:url]) {
			NSString *bundle = [app path];
			if (bundle == nil || names[bundle] != nil) {
				continue;
			}
			names[bundle] = [files displayNameAtPath:bundle];
			[others addObject:bundle];
		}
		[others sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
			return [names[a] localizedStandardCompare:names[b]];
		}];
		NSMutableData *out = [NSMutableData data];
		void (^add)(NSString *, BOOL) = ^(NSString *bundle, BOOL isDefault) {
			const char *bundlePath = [bundle UTF8String];
			const char *name = [names[bundle] UTF8String];
			if (bundlePath == NULL || name == NULL) {
				return;
			}
			[out appendBytes:(isDefault ? "1" : "0") length:2];
			[out appendBytes:bundlePath length:strlen(bundlePath) + 1];
			[out appendBytes:name length:strlen(name) + 1];
		};
		if (preferred != nil) {
			add(preferred, YES);
		}
		for (NSString *bundle in others) {
			add(bundle, NO);
		}
		if (out.length == 0) {
			return NULL;
		}
		char *result = malloc(out.length);
		if (result == NULL) {
			return NULL;
		}
		memcpy(result, out.bytes, out.length);
		*size = out.length;
		return result;
	}
}
*/
import "C"

import (
	"strings"
	"unsafe"

	"github.com/vivaui/viva/app"
)

func list(path string) ([]App, error) {
	file := C.CString(path)
	defer C.free(unsafe.Pointer(file))
	var size C.size_t
	raw := C.lithe_file_apps(file, &size)
	if raw == nil {
		return nil, nil
	}
	defer C.free(unsafe.Pointer(raw))
	fields := strings.Split(C.GoStringN(raw, C.int(size)), "\x00")
	var apps []App
	for i := 0; i+2 < len(fields); i += 3 {
		apps = append(apps, App{Default: fields[i] == "1", ID: fields[i+1], Name: fields[i+2]})
	}
	return apps, nil
}

// open hands the file to the bundle through the system's open, as Finder's Open With does;
// Viva's call reports a failed handoff and records the request in driver-backed runs.
func open(path string, chosen App) error {
	return app.OpenWith(chosen.ID, path)
}
