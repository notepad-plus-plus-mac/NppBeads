// BeadsWatcher — dispatch_source_t (DISPATCH_SOURCE_TYPE_VNODE) on
// `.beads/issues.jsonl`. Coalesces rapid agent-driven writes with a
// 200ms debounce window. Also handles the ATOMIC-WRITE pattern (editors
// and CLI tools frequently write → rename, which triggers DELETE on the
// open fd): on a DELETE event we re-open the path and reinstall.
//
// Callback fires on the main queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BeadsWatcher : NSObject

@property (nonatomic, copy, readonly, nullable) NSString *watchedPath;
@property (nonatomic, copy) void (^onChange)(void);

- (void)watchPath:(nullable NSString *)path;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
