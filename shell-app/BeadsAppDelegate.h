// BeadsAppDelegate — the standalone app's NSApplicationDelegate.
//
// Owns the menu bar, the main window, and the lifecycle around opening /
// switching projects. Loads the last-bound project on launch from the same
// MRU NSUserDefaults key the plugin already maintains
// (`NppBeadsRecentProjectRoots`), so a user who launches the standalone
// after using the plugin sees their project list pre-populated.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BeadsMainWindowController;

@interface BeadsAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

@property (nonatomic, strong, readonly) BeadsMainWindowController *windowController;

// Menu actions — also wired as targets for File menu items.
- (IBAction)openProjectFolder:(nullable id)sender;
- (IBAction)reloadProjectData:(nullable id)sender;
- (IBAction)revealBeadsInFinder:(nullable id)sender;
- (IBAction)openRecentProject:(id)sender;       // tag = MRU index
- (IBAction)clearRecentProjects:(nullable id)sender;
- (IBAction)showBeadsHelp:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
