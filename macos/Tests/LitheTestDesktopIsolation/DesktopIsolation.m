#import "LitheTestDesktopIsolation.h"
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Note: .agents/notes/implemented/testing/2026-10-09-macos-test-desktop-isolation.md
// Linked only by test targets. No product code or installed bundle is changed.
static BOOL isolationEnabled = NO;
static char requestedAlphaKey;

BOOL LitheTestDesktopIsolationEnabled(void) { return isolationEnabled; }

CGFloat LitheTestRequestedWindowAlpha(NSWindow *window) {
    NSNumber *requested = objc_getAssociatedObject(window, &requestedAlphaKey);
    return requested ? requested.doubleValue : window.alphaValue;
}

static void exchangeMethod(Class type, SEL original, SEL replacement) {
    Method first = class_getInstanceMethod(type, original);
    Method second = class_getInstanceMethod(type, replacement);
    if (!first || !second) {
        fprintf(stderr, "Test desktop isolation cannot install %s\n", sel_getName(original));
        exit(2);
    }
    method_exchangeImplementations(first, second);
}

@interface NSWindow (LitheTestDesktopIsolation)
- (instancetype)lithe_test_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style
    backing:(NSBackingStoreType)backing defer:(BOOL)deferred __attribute__((objc_method_family(init)));
- (void)lithe_test_suppressDesktopPresentation;
@end

@implementation NSWindow (LitheTestDesktopIsolation)
- (instancetype)lithe_test_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style
    backing:(NSBackingStoreType)backing defer:(BOOL)deferred {
    // Preserve init's retained-result and consumed-self ARC contract after exchanging methods.
    self = [self lithe_test_initWithContentRect:rect styleMask:style backing:backing defer:deferred];
    [self lithe_test_suppressDesktopPresentation];
    return self;
}

- (void)lithe_test_suppressDesktopPresentation {
    if (!objc_getAssociatedObject(self, &requestedAlphaKey)) {
        objc_setAssociatedObject(self, &requestedAlphaKey, @(self.alphaValue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Calling the exchanged selector reaches AppKit's original implementation.
    [self lithe_test_setAlphaValue:0];
}

- (void)lithe_test_setAlphaValue:(CGFloat)value {
    objc_setAssociatedObject(self, &requestedAlphaKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self lithe_test_setAlphaValue:0];
}

- (void)lithe_test_orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)number {
    if (mode != NSWindowOut) [self lithe_test_suppressDesktopPresentation];
    // Preserve the actual window list, geometry, responder chain and dismissal.
    [self lithe_test_orderWindow:mode relativeTo:number];
}
@end

@implementation NSApplication (LitheTestDesktopIsolation)
- (void)lithe_test_activateIgnoringOtherApps:(BOOL)ignore { }
- (void)lithe_test_activate { }
@end

@interface LitheTestDesktopIsolationBootstrap : NSObject
@end

@implementation LitheTestDesktopIsolationBootstrap
+ (void)load {
    @autoreleasepool {
        const char *mode = getenv("LITHE_TEST_WINDOW_MODE");
        const char *compositor = getenv("LITHE_RUN_GIT_COMPOSITOR_TESTS");
        BOOL realCompositor = compositor && strcmp(compositor, "1") == 0;
        if (mode && strcmp(mode, "visible") != 0 && strcmp(mode, "isolated") != 0) {
            fprintf(stderr, "LITHE_TEST_WINDOW_MODE must be isolated or visible\n");
            exit(2);
        }
        if (realCompositor && mode && strcmp(mode, "isolated") == 0) {
            fprintf(stderr, "Real compositor tests require LITHE_TEST_WINDOW_MODE=visible\n");
            exit(2);
        }
        if ((mode && strcmp(mode, "visible") == 0) || realCompositor) return;

        isolationEnabled = YES;
        exchangeMethod(NSWindow.class, @selector(initWithContentRect:styleMask:backing:defer:),
            @selector(lithe_test_initWithContentRect:styleMask:backing:defer:));
        exchangeMethod(NSWindow.class, @selector(setAlphaValue:), @selector(lithe_test_setAlphaValue:));
        exchangeMethod(NSWindow.class, @selector(orderWindow:relativeTo:), @selector(lithe_test_orderWindow:relativeTo:));
        exchangeMethod(NSApplication.class, @selector(activateIgnoringOtherApps:),
            @selector(lithe_test_activateIgnoringOtherApps:));
        // activate is available from macOS 14; older supported hosts use the previous selector.
        if (class_getInstanceMethod(NSApplication.class, NSSelectorFromString(@"activate"))) {
            exchangeMethod(NSApplication.class, NSSelectorFromString(@"activate"), @selector(lithe_test_activate));
        }
    }
}
@end
