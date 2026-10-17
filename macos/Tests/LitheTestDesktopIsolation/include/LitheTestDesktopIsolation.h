#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether this test process suppresses desktop presentation.
BOOL LitheTestDesktopIsolationEnabled(void);

/// The opacity requested by the product, before the test compositor override.
/// Use this only for opacity assertions; alphaValue reports the actual isolation opacity.
CGFloat LitheTestRequestedWindowAlpha(NSWindow *window);

NS_ASSUME_NONNULL_END
