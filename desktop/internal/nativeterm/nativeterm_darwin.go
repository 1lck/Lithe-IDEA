package nativeterm

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AppKit
#import <AppKit/AppKit.h>

// The keys of Terminal.app's profile, in ANSI order: the eight colors, then their bright forms.
static NSString *const lithe_ansi_keys[16] = {
	@"ANSIBlackColor", @"ANSIRedColor", @"ANSIGreenColor", @"ANSIYellowColor",
	@"ANSIBlueColor", @"ANSIMagentaColor", @"ANSICyanColor", @"ANSIWhiteColor",
	@"ANSIBrightBlackColor", @"ANSIBrightRedColor", @"ANSIBrightGreenColor", @"ANSIBrightYellowColor",
	@"ANSIBrightBlueColor", @"ANSIBrightMagentaColor", @"ANSIBrightCyanColor", @"ANSIBrightWhiteColor",
};

// lithe_terminal_ansi fills rgb (16 × 3 bytes) and set (16 flags) from the default profile of
// Terminal.app. It returns 0 when the preferences hold no default profile.
static int lithe_terminal_ansi(unsigned char *rgb, unsigned char *set) {
	@autoreleasepool {
		CFStringRef domain = CFSTR("com.apple.Terminal");
		id name = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Default Window Settings"), domain));
		id profiles = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Window Settings"), domain));
		if (![name isKindOfClass:[NSString class]] || ![profiles isKindOfClass:[NSDictionary class]]) {
			return 0;
		}
		id profile = ((NSDictionary *)profiles)[name];
		if (![profile isKindOfClass:[NSDictionary class]]) {
			return 0;
		}
		NSColorSpace *srgb = [NSColorSpace sRGBColorSpace];
		for (int i = 0; i < 16; i++) {
			set[i] = 0;
			id data = ((NSDictionary *)profile)[lithe_ansi_keys[i]];
			if (![data isKindOfClass:[NSData class]]) {
				continue;
			}
			NSError *error = nil;
			NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
			if (unarchiver == nil) {
				continue;
			}
			// Terminal.app archived these colors before secure coding; they are plain NSColors.
			unarchiver.requiresSecureCoding = NO;
			id color = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
			[unarchiver finishDecoding];
			if (![color isKindOfClass:[NSColor class]]) {
				continue;
			}
			NSColor *converted = [(NSColor *)color colorUsingColorSpace:srgb];
			if (converted == nil) {
				continue;
			}
			CGFloat channels[3] = {converted.redComponent, converted.greenComponent, converted.blueComponent};
			for (int c = 0; c < 3; c++) {
				CGFloat value = channels[c] < 0 ? 0 : (channels[c] > 1 ? 1 : channels[c]);
				rgb[i * 3 + c] = (unsigned char)(value * 255.0 + 0.5);
			}
			set[i] = 1;
		}
		return 1;
	}
}
*/
import "C"

import "unsafe"

func read() (Colors, bool) {
	var rgb [48]byte
	var set [16]byte
	if C.lithe_terminal_ansi((*C.uchar)(unsafe.Pointer(&rgb[0])), (*C.uchar)(unsafe.Pointer(&set[0]))) == 0 {
		return Colors{}, false
	}
	var colors Colors
	for i := range 16 {
		colors.ANSI[i] = [3]uint8{rgb[i*3], rgb[i*3+1], rgb[i*3+2]}
		colors.Set[i] = set[i] != 0
	}
	return colors, true
}
