#import "BeadsMainWindowController.h"
#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"  // declares both BeadsProject and BeadsProjectScanner

// Window-frame autosave name prefix. The full name is per-project: keying
// off the bound project's root path means two windows on two projects
// don't fight over the same saved frame, and each project remembers its
// own size + position across launches.
//
// Empty windows (no project bound) all share a single fallback key —
// they're rare (only first launch with no MRU) and one is enough.
static NSString * const kBeadsWindowAutosaveBase  = @"Beads.MainWindow";
static NSString * const kBeadsWindowAutosaveEmpty = @"Beads.MainWindow.Empty";

// Sensible default size when there's no autosaved frame yet.
static const CGFloat kDefaultWindowW = 980.0;
static const CGFloat kDefaultWindowH = 720.0;
static const CGFloat kMinWindowW     = 520.0;
static const CGFloat kMinWindowH     = 400.0;

@implementation BeadsMainWindowController

- (instancetype)initWithProject:(nullable BeadsProject *)project {
    NSRect contentRect = NSMakeRect(0, 0, kDefaultWindowW, kDefaultWindowH);
    // Standard title bar style. We deliberately do NOT use
    // NSWindowStyleMaskFullSizeContentView here: the BeadsPanel's
    // own 28pt toolbar (project chip / view popup / search /
    // theme / refresh / finder / overflow) lives at the TOP of its
    // content view and is exactly the same height as the macOS
    // title bar. With FullSizeContentView the macOS title bar
    // floats over the panel toolbar and hides it — leading to the
    // appearance that the standalone "lacks" the toolbar. Without
    // it, the macOS title bar sits at the top with traffic lights
    // and the project name, and the panel toolbar appears
    // immediately below it. Two distinct bars, both fully visible.
    NSUInteger styleMask = NSWindowStyleMaskTitled
                         | NSWindowStyleMaskClosable
                         | NSWindowStyleMaskMiniaturizable
                         | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:contentRect
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title              = @"BeadsViewer";
    window.releasedWhenClosed = NO;
    window.minSize            = NSMakeSize(kMinWindowW, kMinWindowH);

    if ((self = [super initWithWindow:window])) {
        _boundProjectRoot = [project.projectRoot.stringByStandardizingPath copy];

        NSString *autosave = [[self class] _autosaveNameForProjectRoot:_boundProjectRoot];
        [window setFrameAutosaveName:autosave];
        // center: first-launch fallback when no autosaved frame exists.
        // setFrameUsingName: applies the persisted frame if it does.
        // Multi-window note: AppKit's NSWindow cascading kicks in only
        // when two windows share an autosave name and one is already open
        // — with per-project keys, two distinct projects open at their
        // own saved positions instead of cascading. Acceptable.
        [window center];
        [window setFrameUsingName:autosave];

        [self _installBeadsPanel];

        if (project) [self bindProject:project];
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

    // The standalone IS the window's only content. "Hide panel" doesn't
    // make sense here — there's nothing to dock back into. Suppress the
    // ⋯ menu item; users dismiss via ⌘W / red traffic light, which is
    // the natural Mac convention. (We also intentionally don't set
    // hideHandler since no caller in the standalone path will fire it.)
    _beadsPanel.showsHidePanelMenuItem = NO;

    // Update the window title (and our tracked boundProjectRoot) whenever
    // the panel's bound project changes — including via the in-app
    // project switcher, which doesn't route through our own bindProject:
    // above. Weak self avoids a retain cycle (controller strongly owns
    // the panel which retains this block).
    __weak typeof(self) weakSelf = self;
    _beadsPanel.projectDidChangeHandler = ^(BeadsProject * _Nullable project) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_boundProjectRoot = [project.projectRoot.stringByStandardizingPath copy];
        if (project) {
            [strongSelf _setWindowTitleFromProjectRoot:project.projectRoot];
        } else {
            strongSelf.window.title = @"BeadsViewer";
        }
    };

    self.window.contentView = _beadsPanel;
}

- (void)bindProject:(nullable BeadsProject *)project {
    _boundProjectRoot = [project.projectRoot.stringByStandardizingPath copy];
    [self.beadsPanel bindProject:project];

    // Reflect the project name in the window title for at-a-glance
    // identification when running multiple Beads-class apps.
    if (project) {
        [self _setWindowTitleFromProjectRoot:project.projectRoot];
    } else {
        self.window.title = @"BeadsViewer";
    }
}

- (void)_setWindowTitleFromProjectRoot:(NSString *)projectRoot {
    if (!projectRoot.length) {
        self.window.title = @"BeadsViewer";
        return;
    }
    NSString *base = projectRoot.lastPathComponent ?: @"";
    self.window.title = base.length
        ? [NSString stringWithFormat:@"BeadsViewer — %@", base]
        : @"BeadsViewer";
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

+ (NSString *)_autosaveNameForProjectRoot:(nullable NSString *)projectRoot {
    if (!projectRoot.length) return kBeadsWindowAutosaveEmpty;
    // Hash the standardized root so the key is stable but compact, and
    // doesn't expose the user's home path inside NSUserDefaults keys.
    // NSString.hash is stable within a single process — we want it stable
    // across launches too. Use a small DJB2-style hash over UTF-8 bytes.
    const char *utf8 = projectRoot.UTF8String;
    unsigned long hash = 5381;
    for (const char *p = utf8; p && *p; ++p) {
        hash = ((hash << 5) + hash) + (unsigned char)(*p);
    }
    return [NSString stringWithFormat:@"%@.%lX", kBeadsWindowAutosaveBase, hash];
}

@end
