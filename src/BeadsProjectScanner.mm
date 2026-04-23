#import "BeadsProjectScanner.h"

@implementation BeadsProject
@end

@implementation BeadsProjectScanner

+ (BOOL)isUsableBeadsDir:(NSString *)beadsDir {
    if (beadsDir.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:beadsDir isDirectory:&isDir] || !isDir) return NO;
    NSString *jsonl = [beadsDir stringByAppendingPathComponent:@"issues.jsonl"];
    NSString *db    = [beadsDir stringByAppendingPathComponent:@"beads.db"];
    return [fm fileExistsAtPath:jsonl] || [fm fileExistsAtPath:db];
}

+ (nullable BeadsProject *)findProjectFromPath:(nullable NSString *)filePath {
    if (filePath.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    // Start from the file's containing directory; if the input is
    // already a directory, use it directly.
    BOOL isDir = NO;
    NSString *dir = filePath;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir]) return nil;
    if (!isDir) dir = [dir stringByDeletingLastPathComponent];

    NSString *home = NSHomeDirectory();
    NSUInteger depth = 0;
    const NSUInteger kMaxDepth = 40;  // sanity stop

    while (dir.length > 1 && depth++ < kMaxDepth) {
        NSString *candidate = [dir stringByAppendingPathComponent:@".beads"];
        if ([self isUsableBeadsDir:candidate]) {
            BeadsProject *p = [[BeadsProject alloc] init];
            p.beadsDir    = candidate;
            p.projectRoot = dir;
            NSString *jsonl = [candidate stringByAppendingPathComponent:@"issues.jsonl"];
            NSString *db    = [candidate stringByAppendingPathComponent:@"beads.db"];
            if ([fm fileExistsAtPath:jsonl]) p.jsonlPath = jsonl;
            if ([fm fileExistsAtPath:db])    p.dbPath    = db;
            return p;
        }
        // Stop at $HOME. A project outside $HOME is unusual; we refuse
        // to escalate to '/' to avoid inspecting irrelevant trees.
        if ([dir isEqualToString:home]) return nil;
        NSString *parent = [dir stringByDeletingLastPathComponent];
        if ([parent isEqualToString:dir]) return nil;  // hit root
        dir = parent;
    }
    return nil;
}

@end
