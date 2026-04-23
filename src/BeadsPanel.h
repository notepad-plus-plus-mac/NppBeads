// BeadsPanel — the docked NSView that hosts the bundled beads-viewer
// inside a WKWebView. Layout:
//
//   [title-row: label | refresh | open-dir | reload]    — 24pt
//   ────────────────────────────────────────────────
//   [WKWebView — fills]
//   ────────────────────────────────────────────────
//   [status-row: project · issues(open/blocked/closed)] — 18pt
//
// The panel owns:
//   - JsonlDataSource (bound to the current project)
//   - BeadsWatcher    (re-fires on file change → reloadData)
//   - BeadsProject    (or nil when no project)
//
// Bridge: a WKScriptMessageHandler registered as "beadsBridge". bridge.js
// posts {type:'getJsonl'} on first DB synth; we reply by evaluateJavaScript
// into window.__nppBeads.receiveJsonl(text).

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class BeadsProject;
@class JsonlDataSource;
@class BeadsWatcher;

NS_ASSUME_NONNULL_BEGIN

@interface BeadsPanel : NSView <WKNavigationDelegate, WKScriptMessageHandler>

// Absolute path to the plugin's `resources/` directory. Must be set via
// the designated init — the panel uses it to `loadFileURL` during init.
@property (nonatomic, copy, readonly) NSString *resourcesDir;
@property (nonatomic, strong, nullable) BeadsProject *project;

// Called by the "Hide panel" context menu item. NppBeads.mm owns
// the dock/float state, so the panel just asks it to hide.
@property (nonatomic, copy, nullable) void (^hideHandler)(void);

- (instancetype)initWithFrame:(NSRect)frame
                 resourcesDir:(NSString *)resourcesDir NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;

// Bind to a .beads/ project (or nil to clear). Triggers viewer reload.
- (void)bindProject:(nullable BeadsProject *)project;

// Reread JSONL from disk and ask the viewer to rehydrate.
- (void)reloadData;

// Open the .beads/ directory in Finder (menu action).
- (void)openBeadsDirInFinder:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
