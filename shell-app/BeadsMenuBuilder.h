// BeadsMenuBuilder — builds the standalone app's NSMainMenu programmatically.
//
// AppKit doesn't auto-build a menu bar from Info.plist; you either ship a
// MainMenu.xib or build it in code. We build in code so there's no
// Interface Builder file to keep in sync with code changes.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BeadsAppDelegate;

@interface BeadsMenuBuilder : NSObject

// Returns a fully-built NSMainMenu wired to the delegate's IBActions.
// The "Open Recent" submenu is given the delegate as its menuDelegate so
// it can rebuild on demand from the persisted MRU.
+ (NSMenu *)buildMainMenuForDelegate:(BeadsAppDelegate *)delegate;

@end

NS_ASSUME_NONNULL_END
