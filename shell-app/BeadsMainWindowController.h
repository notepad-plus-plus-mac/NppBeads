// BeadsMainWindowController — owns the standalone app's single NSWindow
// and the BeadsPanel that fills it.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BeadsPanel;
@class BeadsProject;

@interface BeadsMainWindowController : NSWindowController

@property (nonatomic, strong, readonly) BeadsPanel *beadsPanel;

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCoder:(NSCoder *)c NS_UNAVAILABLE;
- (instancetype)initWithWindow:(nullable NSWindow *)window NS_UNAVAILABLE;
- (instancetype)initWithWindowNibName:(NSNibName)name NS_UNAVAILABLE;

- (void)bindProject:(nullable BeadsProject *)project;

@end

NS_ASSUME_NONNULL_END
