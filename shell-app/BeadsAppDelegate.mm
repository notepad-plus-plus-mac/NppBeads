#import "BeadsAppDelegate.h"
#import "BeadsMainWindowController.h"
#import "BeadsMenuBuilder.h"
#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"

// Same key the plugin uses, so the standalone and plugin share a project list.
static NSString * const kBeadsRecentProjectsKey = @"NppBeadsRecentProjectRoots";
// First-launch hint flag.
static NSString * const kBeadsHasLaunchedKey    = @"BeadsHasLaunched";

@implementation BeadsAppDelegate {
    // Lazy-built each time File menu opens so the latest MRU shows.
    NSMenu *_recentProjectsMenu;
}

- (instancetype)init {
    if ((self = [super init])) {
        _windowController = [[BeadsMainWindowController alloc] init];
    }
    return self;
}

#pragma mark - NSApplicationDelegate lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)note {
    // Build menu bar BEFORE finishLaunching so the system has it ready
    // when it's about to display the main window.
    NSMenu *mainMenu = [BeadsMenuBuilder buildMainMenuForDelegate:self];
    [NSApp setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self.windowController showWindow:self];

    // Try to bind the last-used project. Strategy:
    //   1. First MRU entry from NppBeadsRecentProjectRoots (shared with plugin).
    //   2. If MRU is empty or top entry no longer resolves, leave the panel
    //      unbound — user opens via File → Open Project Folder.
    NSString *firstMRU = [self _firstResolvableMRUProjectRoot];
    if (firstMRU.length) {
        BeadsProject *proj = [BeadsProjectScanner projectFromRoot:firstMRU];
        if (proj) {
            [self.windowController bindProject:proj];
        }
    }

    // First-launch nudge: if no MRU at all, prompt with the open dialog.
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    if (![def boolForKey:kBeadsHasLaunchedKey]) {
        [def setBool:YES forKey:kBeadsHasLaunchedKey];
        NSArray *mru = [def arrayForKey:kBeadsRecentProjectsKey];
        if (mru.count == 0) {
            // Defer one runloop turn so the window paints first; otherwise
            // the modal sheet stacks on top of an empty white square.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self openProjectFolder:nil];
            });
        }
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    // Single-window app — closing the only window quits. Same convention
    // as Calculator, Stickies, Activity Monitor.
    return YES;
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    // Reopen-on-dock-click reuses the existing window if hidden.
    if (!self.windowController.window.isVisible) {
        [self.windowController showWindow:self];
    }
    return YES;
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    // Drag-folder-onto-app + double-click-folder. Take the first URL,
    // walk up to find .beads/.
    for (NSURL *url in urls) {
        if (!url.isFileURL) continue;
        BeadsProject *proj = [BeadsProjectScanner findProjectFromPath:url.path];
        if (proj) {
            [self.windowController bindProject:proj];
            return;
        }
    }
    // None of the dropped paths resolved — alert.
    [self _showAlertNoBeadsFound:urls.firstObject.path ?: @""];
}

#pragma mark - File menu actions

- (IBAction)openProjectFolder:(id)sender {
    NSOpenPanel *op = [NSOpenPanel openPanel];
    op.canChooseFiles          = NO;
    op.canChooseDirectories    = YES;
    op.allowsMultipleSelection = NO;
    op.prompt                  = @"Open";
    op.message                 = @"Select a project folder (the one containing .beads/), "
                                 @"or the .beads/ directory itself.";
    op.directoryURL            = [self _bestStartingDirectoryForOpen];

    [op beginSheetModalForWindow:self.windowController.window
               completionHandler:^(NSModalResponse rc) {
        if (rc != NSModalResponseOK) return;
        NSURL *url = op.URL;
        if (!url) return;

        // Walk up to find a .beads/. Handles all three cases:
        //   - User picked the project root directly.
        //   - User picked the .beads/ folder itself.
        //   - User picked some random file/folder under the project.
        BeadsProject *proj = [BeadsProjectScanner findProjectFromPath:url.path];
        if (proj) {
            [self.windowController bindProject:proj];
        } else {
            [self _showAlertNoBeadsFound:url.path];
        }
    }];
}

- (IBAction)reloadProjectData:(id)sender {
    [self.windowController.beadsPanel reloadData];
}

- (IBAction)revealBeadsInFinder:(id)sender {
    [self.windowController.beadsPanel openBeadsDirInFinder:sender];
}

- (IBAction)openRecentProject:(id)sender {
    // Tag carries the MRU index. We always rebuild the menu before it
    // opens (menuNeedsUpdate:), so tag indices are stable for the click.
    NSMenuItem *item = (NSMenuItem *)sender;
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    NSInteger idx = item.tag;
    if (idx < 0 || (NSUInteger)idx >= mru.count) return;
    NSString *root = mru[idx];
    BeadsProject *proj = [BeadsProjectScanner projectFromRoot:root];
    if (proj) {
        [self.windowController bindProject:proj];
    } else {
        [self _showAlertNoBeadsFound:root];
        // Stale entry — strip it from the MRU so it stops appearing.
        NSMutableArray *m = [mru mutableCopy];
        [m removeObjectAtIndex:(NSUInteger)idx];
        [[NSUserDefaults standardUserDefaults] setObject:m forKey:kBeadsRecentProjectsKey];
    }
}

- (IBAction)clearRecentProjects:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kBeadsRecentProjectsKey];
}

- (IBAction)showBeadsHelp:(id)sender {
    NSURL *url = [NSURL URLWithString:@"https://github.com/notepad-plus-plus-mac/NppBeads"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - NSMenuDelegate (Open Recent submenu)

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (![menu.title isEqualToString:@"Open Recent"]) return;
    [self _rebuildRecentProjectsMenu:menu];
}

- (void)_rebuildRecentProjectsMenu:(NSMenu *)menu {
    [menu removeAllItems];
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];

    if (mru.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc]
                                initWithTitle:@"(no recent projects)"
                                       action:nil
                                keyEquivalent:@""];
        empty.enabled = NO;
        [menu addItem:empty];
        return;
    }

    for (NSUInteger i = 0; i < mru.count; i++) {
        NSString *root = mru[i];
        if (![root isKindOfClass:[NSString class]]) continue;
        // Display lastPathComponent prominently with the parent dir as
        // a subtitle-ish trailing fragment, since multiple projects can
        // share a basename (~/work/foo and ~/personal/foo).
        NSString *base   = root.lastPathComponent;
        NSString *parent = root.stringByDeletingLastPathComponent.lastPathComponent;
        NSString *title  = (parent.length
                            ? [NSString stringWithFormat:@"%@ — %@", base, parent]
                            : base);
        NSMenuItem *it = [[NSMenuItem alloc]
                            initWithTitle:title
                                   action:@selector(openRecentProject:)
                            keyEquivalent:@""];
        it.target = self;
        it.tag    = (NSInteger)i;
        it.toolTip = root;
        [menu addItem:it];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [[NSMenuItem alloc]
                            initWithTitle:@"Clear Menu"
                                   action:@selector(clearRecentProjects:)
                            keyEquivalent:@""];
    clear.target = self;
    [menu addItem:clear];
}

#pragma mark - Helpers

- (NSString *)_firstResolvableMRUProjectRoot {
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    for (id entry in mru) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *root = (NSString *)entry;
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] && isDir) {
            // Validate by attempting to load it. The scanner returns nil
            // if the .beads/ dir doesn't have anything we can read.
            if ([BeadsProjectScanner projectFromRoot:root]) return root;
        }
    }
    return nil;
}

- (NSURL *)_bestStartingDirectoryForOpen {
    // Prefer the parent of the most-recently-used project — likely where
    // the user keeps related projects. Fall back to ~.
    NSArray *mru = [[NSUserDefaults standardUserDefaults]
                        arrayForKey:kBeadsRecentProjectsKey] ?: @[];
    if (mru.count > 0 && [mru[0] isKindOfClass:[NSString class]]) {
        NSString *parent = [(NSString *)mru[0] stringByDeletingLastPathComponent];
        if (parent.length) return [NSURL fileURLWithPath:parent isDirectory:YES];
    }
    return [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
}

- (void)_showAlertNoBeadsFound:(NSString *)path {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText     = @"No .beads/ folder found";
    a.informativeText = [NSString stringWithFormat:
        @"Couldn't find a usable .beads/ directory at or above:\n\n%@\n\n"
        @"To create one, run `bd init` from your project's root in a "
        @"terminal, then retry.",
        path];
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

@end
