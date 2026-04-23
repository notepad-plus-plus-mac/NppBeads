// BeadsPoll — lightweight polling companion to BeadsWatcher.
//
// Why: our VNODE watcher on issues.jsonl covers most change flows because
// bd auto-exports JSONL on every write (post-commit hook). But it misses:
//   - Terminal writes where export is disabled (`bd` invoked without
//     hooks, or dolt-direct writes)
//   - Writes from sibling agents that share the same Dolt DB but don't
//     regenerate JSONL
// So when bd is available we also poll `bd list --all --json` on a timer,
// hash-compare the payload, and fire onChange only when content actually
// moved. Otherwise idle.
//
// Design constraints:
//   - Never block main: the bd call is async; the timer is a GCD dispatch
//     source on main queue but only queues a bd call (no sync wait).
//   - Backpressure: if a previous tick's bd call is still in flight, the
//     next tick is skipped, not queued.
//   - Pausable: pause/resume (the panel calls these from its window
//     key-state handlers) disable firing without tearing down the timer.
//   - Generation-gated: stop() (or a new project bind) invalidates any
//     in-flight bd completion so stale results never fire onChange.
//   - No cache invalidation on its own — listAllIssues has its own 750ms
//     cache and that's fine. The poll observes; it does not write.

#import <Foundation/Foundation.h>

@class BdCommandRunner;

NS_ASSUME_NONNULL_BEGIN

@interface BeadsPoll : NSObject

/** Fired on main queue when the bd list payload hash has changed vs the
    previous tick. `newListJsonText` is the raw bd stdout (unparsed); most
    callers just use it as a change signal and re-broadcast via their
    existing reload path. */
@property (nonatomic, copy, nullable) void (^onChange)(NSString *newListJsonText);

/** True after -pause, false after -resume. Starts false. */
@property (nonatomic, readonly) BOOL isPaused;

/** Diagnostics only. Thread: main. */
@property (nonatomic, readonly) NSUInteger tickCount;
@property (nonatomic, readonly) NSUInteger changeCount;
@property (nonatomic, readonly) NSUInteger skipInFlightCount;

/** Designated init. `runner` must be non-nil. `intervalMs` is clamped to
    [500, 60000]. The timer is NOT started by init — caller must -start. */
- (instancetype)initWithRunner:(BdCommandRunner *)runner
                    intervalMs:(NSUInteger)intervalMs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stop;
- (void)pause;
- (void)resume;

/** Force an immediate tick now (if not paused and nothing in flight).
    Handy for "refresh button also fires a poll" flows. */
- (void)kick;

@end

NS_ASSUME_NONNULL_END
