#import "BeadsSchemeHandler.h"

static NSString *mimeForExtension(NSString *ext) {
    NSString *e = ext.lowercaseString;
    if ([e isEqualToString:@"html"] || [e isEqualToString:@"htm"])
        return @"text/html; charset=utf-8";
    if ([e isEqualToString:@"js"] || [e isEqualToString:@"mjs"])
        return @"application/javascript; charset=utf-8";
    if ([e isEqualToString:@"css"])
        return @"text/css; charset=utf-8";
    if ([e isEqualToString:@"json"] || [e isEqualToString:@"map"])
        return @"application/json; charset=utf-8";
    if ([e isEqualToString:@"wasm"])
        return @"application/wasm";
    if ([e isEqualToString:@"png"])   return @"image/png";
    if ([e isEqualToString:@"jpg"] || [e isEqualToString:@"jpeg"])
        return @"image/jpeg";
    if ([e isEqualToString:@"gif"])   return @"image/gif";
    if ([e isEqualToString:@"svg"])   return @"image/svg+xml";
    if ([e isEqualToString:@"ico"])   return @"image/x-icon";
    if ([e isEqualToString:@"webp"])  return @"image/webp";
    if ([e isEqualToString:@"woff"])  return @"font/woff";
    if ([e isEqualToString:@"woff2"]) return @"font/woff2";
    if ([e isEqualToString:@"ttf"])   return @"font/ttf";
    if ([e isEqualToString:@"otf"])   return @"font/otf";
    if ([e isEqualToString:@"txt"] || [e isEqualToString:@"md"])
        return @"text/plain; charset=utf-8";
    return @"application/octet-stream";
}

@implementation BeadsSchemeHandler {
    // Tracks in-flight tasks so we can short-circuit on stopURLSchemeTask.
    // Access is guarded by @synchronized(self).
    NSMutableSet<id<WKURLSchemeTask>> *_activeTasks;
    dispatch_queue_t _ioQueue;
    NSString *_rootCanonical;  // cached canonical viewerRoot for traversal check
}

@synthesize viewerRoot = _viewerRoot;

- (instancetype)initWithViewerRoot:(NSString *)root {
    if ((self = [super init])) {
        _viewerRoot    = [root copy];
        _rootCanonical = [[root stringByStandardizingPath] copy];
        _activeTasks   = [NSMutableSet set];
        _ioQueue = dispatch_queue_create("org.notepadplusplus.mac.NppBeads.scheme",
                                          DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

// Map the scheme URL path to a file on disk, with traversal guard.
// `path` examples:
//   ""         → index.html
//   "/"        → index.html
//   "/bridge.js"                → viewerRoot/bridge.js
//   "/vendor/sql-wasm.wasm"     → viewerRoot/vendor/sql-wasm.wasm
//   "/../other"                 → rejected (traversal)
- (nullable NSString *)_resolvePath:(NSString *)requestPath {
    NSString *path = requestPath.length == 0 ? @"/index.html" : requestPath;
    if ([path isEqualToString:@"/"]) path = @"/index.html";
    NSString *joined    = [self.viewerRoot stringByAppendingPathComponent:path];
    NSString *canonical = [joined stringByStandardizingPath];
    if (!canonical) return nil;
    // Require the resolved path to stay inside viewerRoot.
    NSString *rootWithSlash = [_rootCanonical hasSuffix:@"/"]
        ? _rootCanonical
        : [_rootCanonical stringByAppendingString:@"/"];
    if (![canonical hasPrefix:rootWithSlash] &&
        ![canonical isEqualToString:_rootCanonical]) {
        return nil;
    }
    return canonical;
}

- (BOOL)_isTaskActive:(id<WKURLSchemeTask>)task {
    @synchronized (self) { return [_activeTasks containsObject:task]; }
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    @synchronized (self) { [_activeTasks addObject:task]; }

    NSURL *url = task.request.URL;
    NSString *filePath = [self _resolvePath:url.path];

    if (!filePath) {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                           code:NSURLErrorNoPermissionsToReadFile
                                       userInfo:@{
            NSLocalizedDescriptionKey: @"NppBeads scheme: path outside viewerRoot",
        }];
        [self _failTask:task withError:err];
        return;
    }

    dispatch_async(_ioQueue, ^{
        if (![self _isTaskActive:task]) return;

        NSError *readErr = nil;
        NSData *data = [NSData dataWithContentsOfFile:filePath
                                              options:NSDataReadingMappedIfSafe
                                                error:&readErr];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self _isTaskActive:task]) return;  // cancelled

            if (!data) {
                NSError *err = readErr ?: [NSError
                    errorWithDomain:NSURLErrorDomain
                               code:NSURLErrorFileDoesNotExist
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"not found: %@", filePath]}];
                [self _failTask:task withError:err];
                return;
            }

            NSString *mime = mimeForExtension(filePath.pathExtension);
            NSDictionary *headers = @{
                @"Content-Type":   mime,
                @"Content-Length": [NSString stringWithFormat:@"%lu",
                                        (unsigned long)data.length],
                // No HTTP caching — plugin writes may have replaced the file
                // on disk and we want a consistent serve-from-disk model.
                @"Cache-Control":  @"no-store",
                // Permissive CORS for same-scheme requests (not strictly
                // needed but defuses any edge-case cross-origin checks
                // WebKit may apply to script / worker / module loads).
                @"Access-Control-Allow-Origin": @"*",
            };
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
                initWithURL:url
                 statusCode:200
                HTTPVersion:@"HTTP/1.1"
               headerFields:headers];

            @try {
                [task didReceiveResponse:resp];
                [task didReceiveData:data];
                [task didFinish];
            } @catch (NSException *ex) {
                // WKURLSchemeTask throws if the task was stopped concurrently.
            }
            @synchronized (self) { [_activeTasks removeObject:task]; }
        });
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    @synchronized (self) { [_activeTasks removeObject:task]; }
}

- (void)_failTask:(id<WKURLSchemeTask>)task withError:(NSError *)err {
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (![_activeTasks containsObject:task]) return;
            [_activeTasks removeObject:task];
        }
        @try { [task didFailWithError:err]; }
        @catch (NSException *ex) { }
    });
}

@end
