#import "BeadsMainWindowController.h"
#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"

// Window-frame autosave name. Different from the plugin's panel-frame
// autosave so the two coexist without overwriting each other.
static NSString * const kBeadsWindowFrameAutosave = @"Beads.MainWindow";

// Sensible default size when there's no autosaved frame yet.
static const CGFloat kDefaultWindowW = 980.0;
static const CGFloat kDefaultWindowH = 720.0;
static const CGFloat kMinWindowW     = 520.0;
static const CGFloat kMinWindowH     = 400.0;

@implementation BeadsMainWindowController

- (instancetype)init {
    NSRect contentRect = NSMakeRect(0, 0, kDefaultWindowW, kDefaultWindowH);
    NSUInteger styleMask = NSWindowStyleMaskTitled
                         | NSWindowStyleMaskClosable
                         | NSWindowStyleMaskMiniaturizable
                         | NSWindowStyleMaskResizable
                         | NSWindowStyleMaskFullSizeContentView;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title           = @"Beads";
    window.releasedWhenClosed = NO;
    window.minSize         = NSMakeSize(kMinWindowW, kMinWindowH);
    window.titlebarAppearsTransparent = NO;

    if ((self = [super initWithWindow:window])) {
        // Autosave AFTER we've called super's designated initializer so the
        // restoration applies to a window that's tied to the controller.
        [window setFrameAutosaveName:kBeadsWindowFrameAutosave];
        [window center];                         // first-launch fallback
        [window setFrameUsingName:kBeadsWindowFrameAutosave];

        [self _installBeadsPanel];
    }
    return self;
}

- (void)_installBeadsPanel {
    NSString *res = [self _resolveResourcesDir];

    // initWithFrame:0,0,w,h — the panel uses its own internal layout, we
    // just need it sized to fill the window's content view via autoresizing.
    NSRect b = self.window.contentView.bounds;
    _beadsPanel = [[BeadsPanel alloc] initWithFrame:b
                                       resourcesDir:res];
    _beadsPanel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = _beadsPanel;

    // The plugin uses hideHandler to fold the side panel back into NPP.
    // In the standalone, the natural mapping is "close the window" — but
    // closing the only window quits the app (per our
    // applicationShouldTerminateAfterLastWindowClosed: = YES). User can
    // still hide the app via Cmd-H without quitting. Wire up close so the
    // panel's "Hide panel" context-menu item is meaningful.
    __weak NSWindow *w = self.window;
    _beadsPanel.hideHandler = ^{
        [w performClose:nil];
    };
}

- (void)bindProject:(nullable BeadsProject *)project {
    [self.beadsPanel bindProject:project];

    // Reflect the project name in the window title for at-a-glance
    // identification when running multiple Beads-class apps.
    if (project) {
        [self _setWindowTitleFromProjectRoot:project.projectRoot];
    } else {
        self.window.title = @"Beads";
    }
}

- (void)_setWindowTitleFromProjectRoot:(NSString *)projectRoot {
    if (!projectRoot.length) {
        self.window.title = @"Beads";
        return;
    }
    NSString *base = projectRoot.lastPathComponent ?: @"";
    self.window.title = base.length
        ? [NSString stringWithFormat:@"Beads — %@", base]
        : @"Beads";
}

- (NSString *)_resolveResourcesDir {
    // Bundle's Resources directory; viewer/ lives directly inside it.
    NSURL *res = [[NSBundle mainBundle] resourceURL];
    if (res) return res.path;
    // Should not happen for a properly-built .app — fall back to the
    // executable's containing directory just in case (e.g. unit-test
    // contexts that don't have a real bundle).
    NSString *exec = [[NSBundle mainBundle] executablePath];
    return exec.stringByDeletingLastPathComponent ?: @"";
}

@end
