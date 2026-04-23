// JsonlDataSource — reads `.beads/issues.jsonl` from disk and offers
// both the raw text (for the JS bridge) and a parsed NSArray (for any
// future native UI). JSONL is the always-available, git-committed path;
// the SQLite/Dolt path is deferred to Phase 3.
//
// Robust against: missing file, unreadable file, non-UTF8 bytes, lines
// that don't parse as JSON (logged + skipped, NOT fatal), and very
// large files (reads with streaming line-accumulation).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JsonlDataSource : NSObject

// Absolute path to `.beads/issues.jsonl`. nil when no project is bound.
@property (nonatomic, copy, nullable) NSString *jsonlPath;

// Bind/unbind the source. Rebinding clears the cache.
- (void)bindToPath:(nullable NSString *)jsonlPath;

// Raw text contents of the JSONL file (UTF-8; lossy decode if needed).
// Cached; -reload invalidates. Returns empty string on any failure.
- (NSString *)rawText;

// Parsed records (one NSDictionary per well-formed JSONL line). Bad
// lines are logged and skipped. Never returns nil.
- (NSArray<NSDictionary *> *)issues;

// Force reread on next accessor call.
- (void)reload;

// Summary counts for the status bar.
- (NSUInteger)issueCount;
- (NSUInteger)openIssueCount;
- (NSUInteger)blockedIssueCount;
- (NSUInteger)closedIssueCount;

@end

NS_ASSUME_NONNULL_END
