#ifndef LITHE_MACOS13_SDK_COMPATIBILITY_H
#define LITHE_MACOS13_SDK_COMPATIBILITY_H

#ifdef __OBJC__

// SwiftTerm guards this property at runtime, but the macOS 13 SDK does not
// declare it. Supplying the declaration lets Ventura build hosts compile the
// dependency without affecting builds that use the macOS 14 or newer SDK.
#include <Availability.h>
#if __MAC_OS_X_VERSION_MAX_ALLOWED < 140000
#import <AppKit/AppKit.h>
@interface NSView (LitheMacOS13SDKCompatibility)
@property(nonatomic) BOOL clipsToBounds;
@end
#endif

#endif

#endif
