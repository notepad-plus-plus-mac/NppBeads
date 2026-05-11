// BeadsAppDelegate — the standalone app's NSApplicationDelegate.
//
// Owns the menu bar and the lifecycle around opening / switching projects.
// Loads the last-bound project on launch from the same MRU NSUserDefaults
// key the plugin already maintains (`NppBeadsRecentProjectRoots`), so a
// user who launches the standalone after using the plugin sees their
// project list pre-populated.
//
// Multi-window: every "Open …" action spawns a new BeadsMainWindowController
// (one window per project). Opening the same project twice focuses the
// existing window instead of creating a duplicate. The last-closed window
// quits the app (applicationShouldTerminateAfterLastWindowClosed: returns
// YES below).

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BeadsMainWindowController;

@interface BeadsAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

/// Snapshot copy of the open project windows. Updated as windows are
/// opened / closed. The list order is creation order.
@property (nonatomic, readonly) NSArray<BeadsMainWindowController *> *windowControllers;

// Menu actions — also wired as targets for File menu items. Per-window
// actions (Reload, Reveal in Finder) operate on the currently key window.
- (IBAction)newWindow:(nullable id)sender;       // Dock menu + future File>New
- (IBAction)openProjectFolder:(nullable id)sender;
- (IBAction)reloadProjectData:(nullable id)sender;
- (IBAction)revealBeadsInFinder:(nullable id)sender;
- (IBAction)openRecentProject:(id)sender;       // tag = MRU index
- (IBAction)clearRecentProjects:(nullable id)sender;
- (IBAction)showBeadsHelp:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
