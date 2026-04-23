// BeadsDataSource — uniform data-access protocol over two backends:
//
//   JsonlDataSource (Phase 1): reads `.beads/issues.jsonl` only. Writes
//   throw `BeadsDataSourceReadOnlyError`. Used when `bd` isn't installed
//   or the project has no working Dolt DB.
//
//   BdDataSource (Phase 3): shells out to `bd` via BdCommandRunner for
//   full CRUD. Preferred whenever available.
//
// The panel picks one at bind-time based on BdCommandRunner's probe.
// Both implement the same protocol so Board / Issues / Details views
// never branch on backend.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Common error domain + codes used by both backends.
extern NSString * const BeadsDataSourceErrorDomain;
typedef NS_ENUM(NSInteger, BeadsDataSourceErrorCode) {
    BeadsDataSourceErrorReadOnly       = 1,  // attempted write on JSONL backend
    BeadsDataSourceErrorNotFound       = 2,
    BeadsDataSourceErrorBlockedByDeps  = 3,  // close refused; userInfo[@"blockers"] is NSArray<NSString *>
    BeadsDataSourceErrorAlreadyClaimed = 4,
    BeadsDataSourceErrorCycle          = 5,
    BeadsDataSourceErrorLocked         = 6,
    BeadsDataSourceErrorBdMissing      = 7,
    BeadsDataSourceErrorGeneric        = 99,
};

// ─────────────────────────────────────────────────────────────────────
//  BeadsDataSource — read + write. Conforming classes MUST:
//    • Return on main queue for all completions.
//    • Accept nil params where noted.
//    • Use the BeadsDataSourceErrorDomain for surfaced errors.
// ─────────────────────────────────────────────────────────────────────
@protocol BeadsDataSource <NSObject>

/** Human-visible backend tag for the status bar, e.g. "bd v1.0.2" or
    "read-only (JSONL)". */
@property (nonatomic, copy, readonly) NSString *backendLabel;

/** YES when writes succeed. JsonlDataSource is NO; BdDataSource is YES
    once probe passes. */
@property (nonatomic, readonly) BOOL writable;

// ── Reads ─────────────────────────────────────────────────────────────

/** All issues, including closed. Completion gets an array of issue
    dicts (normalized via app.js's bead model — id/title/status/
    priority/issue_type/assignee/labels/dependencies/timestamps) or
    nil + NSError on failure. */
- (void)listAllIssuesWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable issues,
                                              NSError * _Nullable error))done;

/** Single-issue detail: full record + deps + comments. */
- (void)showIssue:(NSString *)issueId
       completion:(void (^)(NSDictionary * _Nullable issue,
                            NSError * _Nullable error))done;

// ── Writes (throw ReadOnly on JsonlDataSource) ───────────────────────

- (void)createIssueWithTitle:(NSString *)title
                        type:(nullable NSString *)issueType
                    priority:(nullable NSNumber *)priority
                 description:(nullable NSString *)description
                      labels:(nullable NSArray<NSString *> *)labels
                  completion:(void (^)(NSDictionary * _Nullable issue,
                                       NSError * _Nullable error))done;

/** Fields with nil are left untouched. Pass "" to clear description. */
- (void)updateIssue:(NSString *)issueId
              title:(nullable NSString *)title
        description:(nullable NSString *)description
             status:(nullable NSString *)status
           priority:(nullable NSNumber *)priority
               type:(nullable NSString *)issueType
           assignee:(nullable NSString *)assignee
          addLabels:(nullable NSArray<NSString *> *)addLabels
       removeLabels:(nullable NSArray<NSString *> *)removeLabels
         completion:(void (^)(NSDictionary * _Nullable issue,
                              NSError * _Nullable error))done;

/** Claim-to-start-work. Returns AlreadyClaimed on conflict. */
- (void)claimIssue:(NSString *)issueId
        completion:(void (^)(NSDictionary * _Nullable issue,
                             NSError * _Nullable error))done;

/** Close. Returns BlockedByDeps error with userInfo[@"blockers"] set
    when force==NO and the issue has open blockers. */
- (void)closeIssue:(NSString *)issueId
            reason:(nullable NSString *)reason
             force:(BOOL)force
        completion:(void (^)(NSDictionary * _Nullable issue,
                             NSError * _Nullable error))done;

- (void)reopenIssue:(NSString *)issueId
             reason:(nullable NSString *)reason
         completion:(void (^)(NSDictionary * _Nullable issue,
                              NSError * _Nullable error))done;

- (void)addDependencyFromIssue:(NSString *)dependentId
                      toIssue:(NSString *)dependencyId
                         type:(NSString *)depType
                   completion:(void (^)(NSError * _Nullable error))done;

- (void)removeDependencyFromIssue:(NSString *)dependentId
                         toIssue:(NSString *)dependencyId
                      completion:(void (^)(NSError * _Nullable error))done;

/** Invalidate any read-cache. Called by the panel's Refresh button. */
- (void)invalidateCache;

@end

NS_ASSUME_NONNULL_END
