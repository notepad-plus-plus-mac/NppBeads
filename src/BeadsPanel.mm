#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"
#import "JsonlDataSource.h"
#import "BeadsWatcher.h"
#import "BeadsSchemeHandler.h"

// ─────────────────────────────────────────────────────────────────────────
//  Small helper: escape a string for embedding inside a JS string literal.
//  bridge.js receives the raw JSONL via evaluateJavaScript; without escaping
//  any backslash, quote, newline, or U+2028/U+2029 in user data could
//  break the JS parse.
// ─────────────────────────────────────────────────────────────────────────
static NSString *jsStringLiteral(NSString *input) {
    if (!input) return @"\"\"";
    NSMutableString *out = [NSMutableString stringWithCapacity:input.length + 32];
    [out appendString:@"\""];
    NSUInteger n = input.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [input characterAtIndex:i];
        switch (c) {
            case '\\': [out appendString:@"\\\\"]; break;
            case '"':  [out appendString:@"\\\""]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            case 0x2028: [out appendString:@"\\u2028"]; break;
            case 0x2029: [out appendString:@"\\u2029"]; break;
            default:
                if (c < 0x20) {
                    [out appendFormat:@"\\u%04x", (unsigned)c];
                } else {
                    [out appendFormat:@"%C", c];
                }
        }
    }
    [out appendString:@"\""];
    return out;
}

@implementation BeadsPanel {
    WKWebView          *_webView;
    NSTextField        *_titleLabel;
    NSButton           *_refreshButton;
    NSButton           *_openDirButton;
    NSTextField        *_statusLabel;
    NSView             *_titleBar;
    NSView             *_statusBar;

    JsonlDataSource       *_ds;
    BeadsWatcher          *_watcher;
    BeadsSchemeHandler    *_schemeHandler;

    BOOL                _viewerLoaded;   // DOM ready
    BOOL                _pendingReload;  // a reload was requested before DOM ready
    NSString           *_lastLoadError;  // human-readable load failure (for diagnostics)
    NSUInteger          _loadCount;      // # of _loadViewer calls (reload-loop diag)
    NSUInteger          _reloadDataCount;
    NSUInteger          _watcherFireCount;
    NSUInteger          _jsonlBytesLastSeen;  // skip reload if file unchanged
}

@synthesize resourcesDir = _resourcesDir;

- (instancetype)initWithFrame:(NSRect)frame
                 resourcesDir:(NSString *)resourcesDir {
    if (!(self = [super initWithFrame:frame])) return nil;
    _resourcesDir = [resourcesDir copy];
    _ds      = [[JsonlDataSource alloc] init];
    _watcher = [[BeadsWatcher alloc] init];

    __weak typeof(self) weakSelf = self;
    _watcher.onChange = ^{
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        s->_watcherFireCount++;
        NSLog(@"[NppBeads] watcher fired (%lu)", (unsigned long)s->_watcherFireCount);
        [s reloadData];
    };

    [self _buildUI];
    [self _loadViewer];
    [self _refreshStatusBar];
    return self;
}

// ─────────────────────────────────────────────────────────────────────────
//  UI construction
// ─────────────────────────────────────────────────────────────────────────
- (void)_buildUI {
    self.wantsLayer = YES;
    self.menu = [self _buildContextMenu];

    // Title bar
    _titleBar = [[NSView alloc] init];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    _titleBar.wantsLayer = YES;
    [self addSubview:_titleBar];

    _titleLabel = [[NSTextField alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.bordered    = NO;
    _titleLabel.editable    = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.font        = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _titleLabel.textColor   = [NSColor secondaryLabelColor];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _titleLabel.stringValue = @"Beads — (no project)";
    [_titleBar addSubview:_titleLabel];

    _refreshButton  = [self _makeTitleBarButton:@"arrow.clockwise"
                                          tooltip:@"Reload issues"
                                           action:@selector(_didTapRefresh:)];
    [_titleBar addSubview:_refreshButton];

    _openDirButton  = [self _makeTitleBarButton:@"folder"
                                          tooltip:@"Reveal .beads/ in Finder"
                                           action:@selector(openBeadsDirInFinder:)];
    [_titleBar addSubview:_openDirButton];

    // WKWebView configured with a custom-scheme handler so the viewer is
    // served from `nppbeads://viewer/…` instead of `file://`. Same origin
    // for every sibling file means ES-module dynamic `import()` works,
    // `WebAssembly.instantiateStreaming` gets the right MIME, and XHR/fetch
    // no longer hit file:// restrictions.
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;

    NSString *viewerDir = [self.resourcesDir stringByAppendingPathComponent:@"viewer"];
    _schemeHandler = [[BeadsSchemeHandler alloc] initWithViewerRoot:viewerDir];
    [config setURLSchemeHandler:_schemeHandler forURLScheme:@"nppbeads"];

    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    [ucc addScriptMessageHandler:self name:@"beadsBridge"];
    config.userContentController = ucc;

    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    _webView.navigationDelegate = self;
#if defined(__MAC_13_3) && __MAC_OS_X_VERSION_MAX_ALLOWED >= __MAC_13_3
    if (@available(macOS 13.3, *)) {
        _webView.inspectable = YES;   // right-click → Inspect Element for debugging
    }
#endif
    [self addSubview:_webView];

    // Status bar
    _statusBar = [[NSView alloc] init];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.wantsLayer = YES;
    [self addSubview:_statusBar];

    _statusLabel = [[NSTextField alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.bordered    = NO;
    _statusLabel.editable    = NO;
    _statusLabel.drawsBackground = NO;
    _statusLabel.font        = [NSFont systemFontOfSize:10];
    _statusLabel.textColor   = [NSColor tertiaryLabelColor];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _statusLabel.stringValue = @"no project";
    [_statusBar addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        // Title bar: full width, 24pt, top
        [_titleBar.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_titleBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_titleBar.heightAnchor   constraintEqualToConstant:24],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_titleBar.leadingAnchor constant:8],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_refreshButton.leadingAnchor constant:-6],
        [_refreshButton.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:_openDirButton.leadingAnchor constant:-4],
        [_openDirButton.centerYAnchor  constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_openDirButton.trailingAnchor constraintEqualToAnchor:_titleBar.trailingAnchor constant:-6],

        // WebView fills the middle band.
        [_webView.topAnchor      constraintEqualToAnchor:_titleBar.bottomAnchor],
        [_webView.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_webView.bottomAnchor   constraintEqualToAnchor:_statusBar.topAnchor],

        // Status bar: full width, 18pt, bottom
        [_statusBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_statusBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_statusBar.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],
        [_statusBar.heightAnchor   constraintEqualToConstant:18],
        [_statusLabel.leadingAnchor  constraintEqualToAnchor:_statusBar.leadingAnchor constant:8],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:_statusBar.trailingAnchor constant:-8],
        [_statusLabel.centerYAnchor  constraintEqualToAnchor:_statusBar.centerYAnchor],
    ]];
}

- (NSButton *)_makeTitleBarButton:(NSString *)symbol
                          tooltip:(NSString *)tip
                           action:(SEL)action {
    NSButton *b = [[NSButton alloc] init];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.bezelStyle = NSBezelStyleRegularSquare;
    b.bordered   = NO;
    b.imagePosition = NSImageOnly;
    b.toolTip    = tip;
    b.target     = self;
    b.action     = action;
    if (@available(macOS 11.0, *)) {
        b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    }
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor  constraintEqualToConstant:18],
        [b.heightAnchor constraintEqualToConstant:18],
    ]];
    return b;
}

// ─────────────────────────────────────────────────────────────────────────
//  Viewer load
// ─────────────────────────────────────────────────────────────────────────
- (void)_loadViewer {
    NSString *resDir = self.resourcesDir;
    if (resDir.length == 0) {
        _lastLoadError = @"resourcesDir is nil (bootstrap bug)";
        [self _showErrorPage:_lastLoadError];
        return;
    }
    NSString *idx = [[resDir stringByAppendingPathComponent:@"viewer"]
                          stringByAppendingPathComponent:@"index.html"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:idx]) {
        _lastLoadError = [NSString stringWithFormat:@"viewer missing at %@", idx];
        NSLog(@"[NppBeads] %@", _lastLoadError);
        [self _showErrorPage:_lastLoadError];
        return;
    }
    _lastLoadError = nil;
    _loadCount++;
    NSLog(@"[NppBeads] _loadViewer (#%lu)", (unsigned long)_loadCount);
    [self _installJsonlUserScript];

    // Wipe caches + SW registrations so plugin file edits take effect.
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    WKWebsiteDataStore *ds = _webView.configuration.websiteDataStore;
    NSMutableSet *types = [NSMutableSet setWithArray:@[
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeLocalStorage,
    ]];
    if (@available(macOS 11.3, *)) {
        [types addObject:WKWebsiteDataTypeServiceWorkerRegistrations];
    }
    NSURL *url = [NSURL URLWithString:@"nppbeads://viewer/index.html"];
    [ds removeDataOfTypes:types
           modifiedSince:[NSDate distantPast]
       completionHandler:^{
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    }];
}

// Inject the JSONL text + the sql-wasm.wasm bytes directly into the page
// at document-start via WKUserScripts. bridge.js and our viewer.js patch
// see them synchronously — no IPC handshake, no file:// fetch (which
// WKWebView refuses for XHR and gives empty MIME for fetch). We remove
// + reinstall when the project changes.
- (void)_installJsonlUserScript {
    WKUserContentController *ucc = _webView.configuration.userContentController;
    [ucc removeAllUserScripts];

    NSString *raw = [_ds rawText] ?: @"";
    NSString *jsonlJs = [NSString stringWithFormat:
        @"window.__nppBeadsPreloadedJsonl = %@;"
         "window.__nppBeadsProjectPath = %@;",
        jsStringLiteral(raw),
        jsStringLiteral(self.project.projectRoot ?: @"")];
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:jsonlJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    // Load every .wasm from vendor/ into a base64 blob, inject as a
    // document-start script that decodes them into Uint8Arrays on
    // window.__nppBeadsWasmBytesMap[filename]. bridge.js serves these
    // bytes for matching fetch() calls, bypassing WKWebView's broken
    // file:// wasm loading. Also keeps the specific sql-wasm bytes as
    // __nppBeadsWasmBytes for the sqlJs({wasmBinary:...}) path.
    NSString *vendorDir = [self.resourcesDir
        stringByAppendingPathComponent:@"viewer/vendor"];
    NSArray<NSString *> *wasmFiles = @[ @"sql-wasm.wasm", @"bv_graph_bg.wasm" ];
    NSMutableString *wasmJs = [NSMutableString string];
    [wasmJs appendString:
        @"(function(){"
         "window.__nppBeadsWasmBytesMap={};"
         "function dec(b64){var bin=atob(b64);var arr=new Uint8Array(bin.length);"
         "for(var i=0;i<bin.length;i++)arr[i]=bin.charCodeAt(i);return arr;}"];
    for (NSString *fname in wasmFiles) {
        NSString *p = [vendorDir stringByAppendingPathComponent:fname];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d.length == 0) { NSLog(@"[NppBeads] wasm missing: %@", p); continue; }
        NSString *b64 = [d base64EncodedStringWithOptions:0];
        [wasmJs appendFormat:
            @"window.__nppBeadsWasmBytesMap[%@]=dec(%@);",
            jsStringLiteral(fname), jsStringLiteral(b64)];
        if ([fname isEqualToString:@"sql-wasm.wasm"]) {
            [wasmJs appendFormat:
                @"window.__nppBeadsWasmBytes=window.__nppBeadsWasmBytesMap[%@];",
                jsStringLiteral(fname)];
        }
        NSLog(@"[NppBeads] embedded %@ (%lu bytes)", fname, (unsigned long)d.length);
    }
    [wasmJs appendString:@"})();"];
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:wasmJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];
}

// Render a plain HTML page inside the webview when the real viewer can't
// be shown. Gives the user something to look at + debug info + a button.
- (void)_showErrorPage:(NSString *)message {
    if (!_webView) return;
    NSString *safe = message ?: @"(unknown)";
    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset='utf-8'>"
         "<style>body{margin:0;padding:32px;font:13px -apple-system,BlinkMacSystemFont,"
         "system-ui;background:#fafafa;color:#222}h1{font-size:15px;margin:0 0 8px}"
         "pre{background:#fff;border:1px solid #e5e5e5;padding:10px;border-radius:6px;"
         "white-space:pre-wrap;word-break:break-word;font:12px ui-monospace,Menlo}"
         "@media(prefers-color-scheme:dark){body{background:#1a1a1a;color:#ddd}"
         "pre{background:#111;border-color:#333}}</style></head><body>"
         "<h1>NppBeads — viewer not rendered</h1>"
         "<pre>%@</pre>"
         "<p>Use the panel's right-click menu for diagnostics.</p>"
         "</body></html>", safe];
    [_webView loadHTMLString:html baseURL:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Public API
// ─────────────────────────────────────────────────────────────────────────
- (void)bindProject:(BeadsProject *)project {
    self.project = project;
    [_ds bindToPath:project.jsonlPath];
    [_watcher watchPath:project.jsonlPath];
    [self _refreshTitleBar];
    [self _refreshStatusBar];
    // Always reinstall the user script + reload — the JSONL is embedded
    // at document-start, so the page needs a fresh load to pick it up.
    [self _installJsonlUserScript];
    if (_webView.URL) {
        _viewerLoaded = NO;
        [_webView reload];
    }
}

- (void)reloadData {
    [_ds reload];
    [self _refreshStatusBar];
    // Content-hash gate: if the JSONL hasn't actually changed (e.g. watcher
    // fired on a no-op file touch), skip the webView reload to avoid the
    // 37-fires-per-second thrash we saw with DISPATCH_VNODE_ATTRIB.
    NSString *fresh = [_ds rawText] ?: @"";
    NSUInteger len  = fresh.length;
    if (len == _jsonlBytesLastSeen && _viewerLoaded) {
        NSLog(@"[NppBeads] reloadData: unchanged (%lu bytes), skipping reload", (unsigned long)len);
        return;
    }
    _jsonlBytesLastSeen = len;
    _reloadDataCount++;
    NSLog(@"[NppBeads] reloadData (#%lu, %lu bytes)",
          (unsigned long)_reloadDataCount, (unsigned long)len);
    [self _installJsonlUserScript];
    _viewerLoaded = NO;
    [_webView reload];
}

- (void)openBeadsDirInFinder:(id)sender {
    if (self.project.beadsDir.length == 0) return;
    [[NSWorkspace sharedWorkspace] selectFile:self.project.jsonlPath
                     inFileViewerRootedAtPath:self.project.beadsDir];
}

- (void)_didTapRefresh:(id)sender { [self reloadData]; }

// ─────────────────────────────────────────────────────────────────────────
//  Context menu (right-click anywhere in the panel)
// ─────────────────────────────────────────────────────────────────────────
- (NSMenu *)_buildContextMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"NppBeads"];
    auto add = ^(NSString *title, SEL sel) {
        NSMenuItem *it = [m addItemWithTitle:title action:sel keyEquivalent:@""];
        it.target = self;
        return it;
    };
    add(@"Reload issues from disk",        @selector(ctxReloadIssues:));
    add(@"Reload viewer",                  @selector(ctxReloadViewer:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Reveal issues.jsonl in Finder",  @selector(ctxRevealJsonl:));
    add(@"Open .beads/ folder in Finder",  @selector(openBeadsDirInFinder:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Copy diagnostics to clipboard",  @selector(ctxCopyDiagnostics:));
    add(@"Show raw JSONL head (first 1000 chars)", @selector(ctxShowJsonlHead:));
    [m addItem:[NSMenuItem separatorItem]];
    add(@"Hide panel",                     @selector(ctxHidePanel:));
    return m;
}

// Override so the panel's menu wins over any WKWebView ancestor menu too.
- (NSMenu *)menuForEvent:(NSEvent *)event { return self.menu; }

- (void)ctxReloadViewer:(id)sender {
    // Re-navigate the webview to the bundled index.html. This is safer
    // than WKWebView.reload when the previous load failed.
    _viewerLoaded = NO;
    [self _loadViewer];
}

- (void)ctxReloadIssues:(id)sender { [self reloadData]; }

- (void)ctxHidePanel:(id)sender {
    if (self.hideHandler) self.hideHandler();
}

- (void)ctxRevealJsonl:(id)sender {
    NSString *jsonl = self.project.jsonlPath;
    if (jsonl.length == 0) { NSBeep(); return; }
    [[NSWorkspace sharedWorkspace] selectFile:jsonl
                     inFileViewerRootedAtPath:self.project.beadsDir];
}

- (void)ctxCopyDiagnostics:(id)sender {
    // Kick off the JS probe FIRST, then assemble the rest while it runs;
    // present the alert from the completion handler so bridge state is
    // actually captured.
    NSString *probe =
        @"(function(){var out={};"
         "out.hasBridge=!!window.__nppBeads;"
         "out.bridgeVersion=(window.__nppBeads&&window.__nppBeads.version)||null;"
         "out.bridgeMode=(window.__nppBeads&&window.__nppBeads.mode)||null;"
         "out.jsonlLen=(window.__nppBeads&&window.__nppBeads.jsonl)?window.__nppBeads.jsonl.length:null;"
         "out.hasDbPromise=!!(window.__nppBeads&&window.__nppBeads.dbBytesPromise);"
         "out.hasInitSqlJs=typeof window.initSqlJs==='function';"
         "out.hasSQLCached=!!(window.initSqlJs&&window.initSqlJs.cached);"
         "out.hasBeadsViewer=!!window.beadsViewer;"
         "out.hasDB=!!(window.beadsViewer&&window.beadsViewer.DB_STATE&&window.beadsViewer.DB_STATE.db);"
         "out.dbSource=(window.beadsViewer&&window.beadsViewer.DB_STATE&&window.beadsViewer.DB_STATE.source)||null;"
         "out.loadingMessage=(document.querySelector('[x-text*=loadingMessage]')||{}).textContent||null;"
         "out.errorTitle=(window.beadsViewer&&window.beadsViewer.ERROR_STATE&&window.beadsViewer.ERROR_STATE.error)?window.beadsViewer.ERROR_STATE.error.title:null;"
         "out.errorDetails=(window.beadsViewer&&window.beadsViewer.ERROR_STATE&&window.beadsViewer.ERROR_STATE.error)?window.beadsViewer.ERROR_STATE.error.details:null;"
         "out.diagWasm=(window.beadsViewer&&window.beadsViewer.DIAGNOSTICS)?window.beadsViewer.DIAGNOSTICS.wasm:null;"
         "out.diagDbSource=(window.beadsViewer&&window.beadsViewer.DIAGNOSTICS)?window.beadsViewer.DIAGNOSTICS.dbSource:null;"
         "out.viewerReached=window.__nppViewerReached||null;"
         "out.hasWasmBytes=!!window.__nppBeadsWasmBytes;"
         "out.wasmBytesLen=window.__nppBeadsWasmBytes?window.__nppBeadsWasmBytes.byteLength:null;"
         "out.hasPreloadedJsonl=typeof window.__nppBeadsPreloadedJsonl==='string';"
         "out.preloadedJsonlLen=(typeof window.__nppBeadsPreloadedJsonl==='string')?window.__nppBeadsPreloadedJsonl.length:null;"
         "out.consoleTail=(window.__nppConsoleTail||[]).slice(-20);"
         "return JSON.stringify(out,null,2);})()";

    __weak typeof(self) weakSelf = self;
    [_webView evaluateJavaScript:probe completionHandler:^(id r, NSError *e) {
        __strong typeof(self) self_ = weakSelf;
        if (!self_) return;
        NSString *bridgeState = @"(no response)";
        if ([r isKindOfClass:[NSString class]]) bridgeState = r;
        else if (e) bridgeState = e.localizedDescription;

        NSMutableString *s = [NSMutableString string];
        [s appendString:@"NppBeads diagnostics\n====================\n"];
        [s appendFormat:@"resourcesDir: %@\n", self_.resourcesDir ?: @"(nil)"];
        [s appendFormat:@"viewer index.html exists: %@\n",
            [[NSFileManager defaultManager] fileExistsAtPath:
                [[self_.resourcesDir stringByAppendingPathComponent:@"viewer"]
                    stringByAppendingPathComponent:@"index.html"]] ? @"YES" : @"NO"];
        [s appendFormat:@"project root: %@\n", self_.project.projectRoot ?: @"(nil)"];
        [s appendFormat:@".beads dir  : %@\n", self_.project.beadsDir    ?: @"(nil)"];
        [s appendFormat:@"jsonl path  : %@\n", self_.project.jsonlPath   ?: @"(nil)"];
        [s appendFormat:@"db path     : %@\n", self_.project.dbPath      ?: @"(nil)"];
        [s appendFormat:@"issues: %lu open, %lu blocked, %lu closed, %lu total\n",
            (unsigned long)[self_->_ds openIssueCount],
            (unsigned long)[self_->_ds blockedIssueCount],
            (unsigned long)[self_->_ds closedIssueCount],
            (unsigned long)[self_->_ds issueCount]];
        [s appendFormat:@"viewerLoaded: %@\n", self_->_viewerLoaded ? @"YES" : @"NO"];
        [s appendFormat:@"lastLoadError: %@\n", self_->_lastLoadError ?: @"(none)"];
        [s appendFormat:@"webView URL: %@\n", self_->_webView.URL.absoluteString ?: @"(none)"];
        [s appendFormat:@"webView title: %@\n", self_->_webView.title ?: @"(none)"];
        [s appendFormat:@"_loadViewer calls: %lu\n", (unsigned long)self_->_loadCount];
        [s appendFormat:@"reloadData calls: %lu\n",  (unsigned long)self_->_reloadDataCount];
        [s appendFormat:@"watcher fires: %lu\n",    (unsigned long)self_->_watcherFireCount];
        [s appendString:@"\n-- bridge state (JS) --\n"];
        [s appendString:bridgeState];
        [s appendString:@"\n"];

        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:s forType:NSPasteboardTypeString];

        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"NppBeads diagnostics copied";
        a.informativeText = s;
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }];
}

- (void)ctxShowJsonlHead:(id)sender {
    NSString *raw = [_ds rawText];
    NSString *head = (raw.length > 1000) ? [raw substringToIndex:1000] : raw;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:@"JSONL head (%lu bytes total)", (unsigned long)raw.length];
    a.informativeText = head.length ? head : @"(empty — no JSONL loaded)";
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

// ─────────────────────────────────────────────────────────────────────────
//  Status/title updates
// ─────────────────────────────────────────────────────────────────────────
- (void)_refreshTitleBar {
    if (self.project) {
        _titleLabel.stringValue = [NSString stringWithFormat:@"Beads — %@",
                                   self.project.projectRoot.lastPathComponent ?: @"(project)"];
        _titleLabel.toolTip = self.project.projectRoot;
        _refreshButton.enabled = YES;
        _openDirButton.enabled = YES;
    } else {
        _titleLabel.stringValue = @"Beads — (no project)";
        _titleLabel.toolTip = @"No .beads/ directory found above the active file.";
        _refreshButton.enabled = NO;
        _openDirButton.enabled = NO;
    }
}

- (void)_refreshStatusBar {
    if (!self.project) {
        _statusLabel.stringValue = @"no project · open a file inside a repo containing .beads/";
        return;
    }
    if (!self.project.jsonlPath) {
        _statusLabel.stringValue = [NSString stringWithFormat:@"%@ · no issues.jsonl yet",
                                    self.project.projectRoot.lastPathComponent ?: @""];
        return;
    }
    NSUInteger total = [_ds issueCount];
    NSUInteger open  = [_ds openIssueCount];
    NSUInteger blkd  = [_ds blockedIssueCount];
    NSUInteger cls   = [_ds closedIssueCount];
    _statusLabel.stringValue = [NSString stringWithFormat:
        @"%@ · %lu issues (%lu open · %lu blocked · %lu closed)",
        self.project.projectRoot.lastPathComponent ?: @"(project)",
        (unsigned long)total, (unsigned long)open,
        (unsigned long)blkd,  (unsigned long)cls];
}

// ─────────────────────────────────────────────────────────────────────────
//  Bridge (WKScriptMessageHandler)
// ─────────────────────────────────────────────────────────────────────────
- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"beadsBridge"]) return;
    NSDictionary *body = nil;
    if ([message.body isKindOfClass:[NSDictionary class]]) body = message.body;
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"getJsonl"]) {
        [self _pushJsonlToBridge];
    } else if ([type isEqualToString:@"openExternal"]) {
        NSString *url = body[@"url"];
        if ([url isKindOfClass:[NSString class]]) {
            NSURL *u = [NSURL URLWithString:url];
            if (u) [[NSWorkspace sharedWorkspace] openURL:u];
        }
    } else {
        // Unknown message — ignore for forward-compat.
    }
}

- (void)_pushJsonlToBridge {
    NSString *raw = [_ds rawText];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppBeads) { window.__nppBeads.receiveJsonl(%@); }",
        jsStringLiteral(raw)];
    [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[NppBeads] receiveJsonl eval error: %@", e);
    }];
}

// ─────────────────────────────────────────────────────────────────────────
//  WKNavigationDelegate — open external http(s) links in default browser
// ─────────────────────────────────────────────────────────────────────────
- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url = action.request.URL;
    if (action.navigationType == WKNavigationTypeLinkActivated &&
        url && ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        handler(WKNavigationActionPolicyCancel);
        return;
    }
    handler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    _viewerLoaded = YES;
    if (_pendingReload || self.project) {
        _pendingReload = NO;
        [self _pushJsonlToBridge];
    }
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
    NSLog(@"[NppBeads] webview didFailNavigation: %@", error);
}
- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
    withError:(NSError *)error {
    NSLog(@"[NppBeads] webview didFailProvisionalNavigation: %@", error);
}

@end
