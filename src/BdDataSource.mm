#import "BdDataSource.h"
#import "BdCommandRunner.h"

NSString * const BeadsDataSourceErrorDomain = @"NppBeadsDataSourceError";

// Map a BdResult's error to an NSError in our domain. Preserves blocker
// list in userInfo so the UI can show a "force close?" dialog.
static NSError *nserrorFromResult(BdResult *res) {
    if (!res || res.ok) return nil;
    BeadsDataSourceErrorCode code = BeadsDataSourceErrorGeneric;
    switch (res.errorKind) {
        case BdErrorKindNotFound:       code = BeadsDataSourceErrorNotFound;       break;
        case BdErrorKindBlockedByDeps:  code = BeadsDataSourceErrorBlockedByDeps;  break;
        case BdErrorKindAlreadyClaimed: code = BeadsDataSourceErrorAlreadyClaimed; break;
        case BdErrorKindCycle:          code = BeadsDataSourceErrorCycle;          break;
        case BdErrorKindLocked:         code = BeadsDataSourceErrorLocked;         break;
        case BdErrorKindBdMissing:      code = BeadsDataSourceErrorBdMissing;      break;
        default:                        code = BeadsDataSourceErrorGeneric;        break;
    }
    NSMutableDictionary *info = [@{
        NSLocalizedDescriptionKey: res.errorMessage ?: @"bd command failed",
    } mutableCopy];
    if (res.errorKind == BdErrorKindBlockedByDeps && res.blockerIds.count) {
        info[@"blockers"] = res.blockerIds;
    }
    return [NSError errorWithDomain:BeadsDataSourceErrorDomain code:code userInfo:info];
}

@implementation BdDataSource

- (instancetype)initWithRunner:(BdCommandRunner *)runner {
    if ((self = [super init])) { _runner = runner; }
    return self;
}

- (NSString *)backendLabel {
    NSString *v = self.runner.bdVersion ?: @"?";
    return [NSString stringWithFormat:@"bd v%@", v];
}

- (BOOL)writable { return self.runner.bdPath != nil; }

- (void)invalidateCache { [self.runner invalidateCache]; }

// ── Reads ─────────────────────────────────────────────────────────────
- (void)listAllIssuesWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))done {
    [self.runner listAllIssuesWithCompletion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSArray *arr = [res.json isKindOfClass:[NSArray class]] ? res.json : @[];
        if (done) done(arr, nil);
    }];
}

- (void)showIssue:(NSString *)issueId
       completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner showIssue:issueId completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

// ── Writes ────────────────────────────────────────────────────────────
- (void)createIssueWithTitle:(NSString *)title
                        type:(NSString *)issueType
                    priority:(NSNumber *)priority
                 description:(NSString *)description
                      labels:(NSArray<NSString *> *)labels
                  completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner createIssueWithTitle:title type:issueType priority:priority
                         description:description labels:labels
                          completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)updateIssue:(NSString *)issueId
              title:(NSString *)title
        description:(NSString *)description
             status:(NSString *)status
           priority:(NSNumber *)priority
               type:(NSString *)issueType
           assignee:(NSString *)assignee
          addLabels:(NSArray<NSString *> *)addLabels
       removeLabels:(NSArray<NSString *> *)removeLabels
         completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner updateIssue:issueId title:title description:description
                      status:status priority:priority type:issueType
                    assignee:assignee addLabels:addLabels removeLabels:removeLabels
                  completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)claimIssue:(NSString *)issueId completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner claimIssue:issueId completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)closeIssue:(NSString *)issueId
            reason:(NSString *)reason
             force:(BOOL)force
        completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner closeIssue:issueId reason:reason force:force
                 completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)reopenIssue:(NSString *)issueId
             reason:(NSString *)reason
         completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner reopenIssue:issueId reason:reason completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)addDependencyFromIssue:(NSString *)dependentId
                      toIssue:(NSString *)dependencyId
                         type:(NSString *)depType
                   completion:(void (^)(NSError *))done {
    [self.runner addDependencyFromIssue:dependentId toIssue:dependencyId
                                   type:depType completion:^(BdResult *res) {
        if (done) done(res.ok ? nil : nserrorFromResult(res));
    }];
}

- (void)removeDependencyFromIssue:(NSString *)dependentId
                         toIssue:(NSString *)dependencyId
                      completion:(void (^)(NSError *))done {
    [self.runner removeDependencyFromIssue:dependentId toIssue:dependencyId
                                completion:^(BdResult *res) {
        if (done) done(res.ok ? nil : nserrorFromResult(res));
    }];
}

- (void)deleteIssue:(NSString *)issueId completion:(void (^)(NSError *))done {
    [self.runner deleteIssue:issueId completion:^(BdResult *res) {
        if (done) done(res.ok ? nil : nserrorFromResult(res));
    }];
}

- (void)unassignIssue:(NSString *)issueId
           completion:(void (^)(NSDictionary *, NSError *))done {
    [self.runner unassignIssue:issueId completion:^(BdResult *res) {
        if (!res.ok) { if (done) done(nil, nserrorFromResult(res)); return; }
        NSDictionary *d = [res.json isKindOfClass:[NSDictionary class]] ? res.json : nil;
        if (done) done(d, nil);
    }];
}

- (void)addCommentToIssue:(NSString *)issueId body:(NSString *)body
               completion:(void (^)(NSError *))done {
    [self.runner addCommentToIssue:issueId body:body completion:^(BdResult *res) {
        if (done) done(res.ok ? nil : nserrorFromResult(res));
    }];
}

@end
