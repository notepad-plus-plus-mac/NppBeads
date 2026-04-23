#import "BeadsWatcher.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>

@implementation BeadsWatcher {
    int                 _fd;
    dispatch_source_t   _src;
    dispatch_block_t    _pendingCallback;
    NSString           *_watchedPath;
}

- (void)dealloc { [self stop]; }

- (NSString *)watchedPath { return _watchedPath; }

- (void)stop {
    if (_src) { dispatch_source_cancel(_src); _src = nil; }
    if (_fd >= 0) { close(_fd); _fd = -1; }
    if (_pendingCallback) { dispatch_block_cancel(_pendingCallback); _pendingCallback = nil; }
    _watchedPath = nil;
}

- (void)watchPath:(NSString *)path {
    if ([path isEqualToString:_watchedPath] && _src) return;
    [self stop];

    _fd = -1;
    _watchedPath = [path copy];
    if (path.length == 0) return;

    const char *cpath = [path fileSystemRepresentation];
    _fd = open(cpath, O_EVTONLY);
    if (_fd < 0) {
        // File may not exist yet — will get re-attempted by caller on reload().
        NSLog(@"[NppBeads] watch open(%s) failed: errno=%d", cpath, errno);
        return;
    }

    dispatch_queue_t q =
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // NO DISPATCH_VNODE_ATTRIB — it fires on atime/xattr updates (Spotlight,
    // mdworker, plain reads on noatime=off volumes) which would thrash our
    // debounce loop. We only care about actual content changes.
    uintptr_t mask = DISPATCH_VNODE_WRITE    |
                     DISPATCH_VNODE_EXTEND   |
                     DISPATCH_VNODE_DELETE   |
                     DISPATCH_VNODE_RENAME   |
                     DISPATCH_VNODE_REVOKE;
    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,
                                  (uintptr_t)_fd, mask, q);
    if (!_src) {
        close(_fd); _fd = -1;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_src, ^{
        __strong typeof(self) strong = weakSelf;
        if (!strong) return;
        unsigned long flags = dispatch_source_get_data(strong->_src);
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            // Atomic rewrite — reinstall the watch on the same path.
            // Small delay lets the replacement file land before reopen.
            NSString *p = strong->_watchedPath;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                [strong watchPath:p];
                [strong _fireDebounced];
            });
            return;
        }
        [strong _fireDebounced];
    });
    dispatch_source_set_cancel_handler(_src, ^{
        // Fd already closed in -stop.
    });
    dispatch_resume(_src);
}

- (void)_fireDebounced {
    if (!self.onChange) return;
    if (_pendingCallback) dispatch_block_cancel(_pendingCallback);
    __weak typeof(self) weakSelf = self;
    _pendingCallback = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        __strong typeof(self) s = weakSelf;
        if (s && s.onChange) s.onChange();
    });
    // Longer debounce (750ms) so agent-driven rapid writes all coalesce
    // into a single reload. Users editing by hand won't notice.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), _pendingCallback);
}

@end
