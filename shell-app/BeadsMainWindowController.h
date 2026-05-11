// BeadsMainWindowController — owns one of the standalone app's project
// windows and the BeadsPanel that fills it.
//
// One controller = one window = one project. The standalone may have many
// controllers alive at once (one per open project).

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BeadsPanel;
@class BeadsProject;

@interface BeadsMainWindowController : NSWindowController

@property (nonatomic, strong, readonly) BeadsPanel *beadsPanel;

/// Standardized projectRoot of the project currently bound to this window.
/// Updates when bindProject: is called or when the user switches projects
/// in-panel. Nil when the window is empty (no project bound).
@property (nonatomic, readonly, copy, nullable) NSString *boundProjectRoot;

/// Designated initializer. Pass a project to open the window pre-bound;
/// pass nil for an empty window that the user can later route to a project
/// via the in-panel project chip or by replacing it with File > Open.
- (instancetype)initWithProject:(nullable BeadsProject *)project NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;
- (instancetype)initWithWindow:(nullable NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithWindowNibName:(NSNibName)name NS_UNAVAILABLE;

- (void)bindProject:(nullable BeadsProject *)project;

@end

NS_ASSUME_NONNULL_END
