#import "BeadsPoll.h"
#import "BdCommandRunner.h"

@implementation BeadsPoll {
    __weak BdCommandRunner *_runner;
    NSUInteger              _intervalMs;
    dispatch_source_t       _timer;
    BOOL                    _started;
    BOOL                    _paused;
    BOOL                    _inFlight;
    NSUInteger              _generation;     // bumped on stop() to gate stale callbacks
    NSString               *_lastPayload;    // previous bd stdout for change detection
    NSUInteger              _tickCount;
    NSUInteger              _changeCount;
    NSUInteger              _skipInFlightCount;
}

- (instancetype)initWithRunner:(BdCommandRunner *)runner
                    intervalMs:(NSUInteger)intervalMs {
    if (!(self = [super init])) return nil;
    NSAssert(runner, @"BeadsPoll requires a non-nil runner");
    _runner = runner;
    if (intervalMs < 500)   intervalMs = 500;
    if (intervalMs > 60000) intervalMs = 60000;
    _intervalMs = intervalMs;
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)isPaused          { return _paused; }
- (NSUInteger)tickCount          { return _tickCount; }
- (NSUInteger)changeCount        { return _changeCount; }
- (NSUInteger)skipInFlightCount  { return _skipInFlightCount; }

- (void)start {
    if (_started) return;
    _started = YES;

    dispatch_queue_t q = dispatch_get_main_queue();
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!_timer) { _started = NO; return; }

    uint64_t interval = (uint64_t)_intervalMs * NSEC_PER_MSEC;
    // Leeway 100ms: lets the kernel coalesce our timer with others,
    // reduces wakeups when the app is idle. Not user-visible.
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval,
                              100 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _tick];
    });
    dispatch_resume(_timer);
}

- (void)stop {
    if (!_started) return;
    _started = NO;
    _paused  = NO;
    _generation++;                // invalidate any in-flight completion
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _inFlight = NO;
    _lastPayload = nil;
}

- (void)pause {
    _paused = YES;
}

- (void)resume {
    if (!_paused) return;
    _paused = NO;
    // Don't kick immediately — next natural tick will fire. Kicking on
    // every window focus would spam bd during alt-tab flurries.
}

- (void)kick {
    if (!_started || _paused || _inFlight) return;
    [self _tick];
}

- (void)_tick {
    if (_paused) return;
    if (_inFlight) { _skipInFlightCount++; return; }

    BdCommandRunner *runner = _runner;
    if (!runner) return;

    _tickCount++;
    _inFlight = YES;
    const NSUInteger gen = _generation;

    __weak typeof(self) weakSelf = self;
    [runner listAllIssuesWithCompletion:^(BdResult *res) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        if (gen != s->_generation) return;   // -stop or next-project raced us
        s->_inFlight = NO;

        if (!res.ok) {
            // Don't treat transient bd failures as "changed"; log and wait
            // for a future tick. Common cause: Dolt lock contention during
            // a concurrent write — it resolves on its own.
            NSLog(@"[NppBeads] poll tick %lu: bd list failed (%@)",
                  (unsigned long)s->_tickCount,
                  res.errorMessage ?: @"?");
            return;
        }

        NSString *payload = res.rawStdout ?: @"";
        if (!s->_lastPayload) {
            // First successful tick — prime the hash, don't fire. The
            // caller already rendered initial data from the watcher /
            // JSONL path.
            s->_lastPayload = [payload copy];
            return;
        }
        if ([payload isEqualToString:s->_lastPayload]) return;

        s->_lastPayload = [payload copy];
        s->_changeCount++;
        if (s.onChange) s.onChange(payload);
    }];
}

@end
