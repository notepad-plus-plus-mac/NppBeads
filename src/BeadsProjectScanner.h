// BeadsProjectScanner — locates `.beads/` directories in the user's
// open workspace. Strategy (Phase 1):
//   1. Walk up from the active file's directory looking for a sibling
//      `.beads/` folder. Stops at $HOME or filesystem root, whichever
//      comes first (prevents scanning e.g. /).
//   2. (Stubbed for future phases) also consult Folder-as-Workspace
//      roots — needs a host API we don't yet have. For now the walk-up
//      from the active file is the only entry point.
//
// A "valid" .beads/ is a directory that contains either:
//   - `issues.jsonl`  (lightweight path — always present after `bd sync`)
//   - `beads.db`       (Dolt DB — heavier path; tracked for Phase 3)
//
// We do NOT require both; either signal is enough.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BeadsProject : NSObject
// Absolute path to the `.beads` directory.
@property (nonatomic, copy) NSString *beadsDir;
// Absolute path to `issues.jsonl` (may be nil if not yet synced).
@property (nonatomic, copy, nullable) NSString *jsonlPath;
// Absolute path to `beads.db` (may be nil — Dolt path is Phase 3).
@property (nonatomic, copy, nullable) NSString *dbPath;
// Repo/project root (parent of .beads/).
@property (nonatomic, copy) NSString *projectRoot;
@end

@interface BeadsProjectScanner : NSObject

// Walks up from `filePath` (or its containing dir if it is a directory)
// until a `.beads/` sibling is found OR the walk hits a stop boundary.
// Returns nil if no project is in scope.
+ (nullable BeadsProject *)findProjectFromPath:(nullable NSString *)filePath;

// Validate that a given .beads/ actually has something we can read.
+ (BOOL)isUsableBeadsDir:(NSString *)beadsDir;

@end

NS_ASSUME_NONNULL_END
