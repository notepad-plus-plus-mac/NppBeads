#import "JsonlDataSource.h"

@implementation JsonlDataSource {
    NSString            *_cachedText;     // raw file contents
    NSArray<NSDictionary *> *_cachedIssues;  // parsed rows
    BOOL                 _loaded;
    // Counters computed alongside parse so status bar doesn't re-iterate.
    NSUInteger           _cntOpen, _cntBlocked, _cntClosed;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedText   = @"";
        _cachedIssues = @[];
    }
    return self;
}

- (void)bindToPath:(NSString *)path {
    if (_jsonlPath == path || [_jsonlPath isEqualToString:path]) return;
    _jsonlPath = [path copy];
    [self reload];
}

- (void)reload {
    _loaded       = NO;
    _cachedText   = @"";
    _cachedIssues = @[];
    _cntOpen      = 0;
    _cntBlocked   = 0;
    _cntClosed    = 0;
}

- (void)_loadIfNeeded {
    if (_loaded) return;
    _loaded = YES;  // set first so a parse failure doesn't re-loop

    NSString *path = self.jsonlPath;
    if (path.length == 0) return;

    NSError *readErr = nil;
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:&readErr];
    if (!data) {
        NSLog(@"[NppBeads] JSONL read failed: %@ → %@", path, readErr.localizedDescription);
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        // Lossy fallback so we don't lose the whole file to one bad byte.
        text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!text) text = @"";
    _cachedText = text;

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    [text enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) return;
        NSData *lineData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        if (!lineData) return;
        NSError *jerr = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:lineData
                                                 options:0
                                                   error:&jerr];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            if (jerr) {
                NSLog(@"[NppBeads] JSONL line skipped (parse error): %@",
                      jerr.localizedDescription);
            }
            return;
        }
        [rows addObject:obj];
    }];
    _cachedIssues = [rows copy];

    // Count statuses once.
    for (NSDictionary *r in _cachedIssues) {
        NSString *s = r[@"status"];
        if (![s isKindOfClass:[NSString class]]) continue;
        if ([s isEqualToString:@"closed"])      _cntClosed++;
        else if ([s isEqualToString:@"blocked"]) _cntBlocked++;
        else                                     _cntOpen++;
    }
}

- (NSString *)rawText   { [self _loadIfNeeded]; return _cachedText ?: @""; }
- (NSArray<NSDictionary *> *)issues { [self _loadIfNeeded]; return _cachedIssues ?: @[]; }
- (NSUInteger)issueCount       { [self _loadIfNeeded]; return _cachedIssues.count; }
- (NSUInteger)openIssueCount   { [self _loadIfNeeded]; return _cntOpen; }
- (NSUInteger)blockedIssueCount{ [self _loadIfNeeded]; return _cntBlocked; }
- (NSUInteger)closedIssueCount { [self _loadIfNeeded]; return _cntClosed; }

@end
