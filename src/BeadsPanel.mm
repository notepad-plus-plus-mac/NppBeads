#import "BeadsPanel.h"
#import "BeadsProjectScanner.h"
#import "JsonlDataSource.h"
#import "BeadsWatcher.h"
#import "BeadsSchemeHandler.h"
#import "BeadsDataSource.h"
#import "BdCommandRunner.h"
#import "BdDataSource.h"

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
    NSPopUpButton      *_viewModePopup;
    NSSearchField      *_searchField;
    NSButton           *_themeButton;
    NSButton           *_refreshButton;
    NSButton           *_openDirButton;
    NSButton           *_menuButton;
    NSTextField        *_statusLabel;
    NSView             *_titleBar;
    NSView             *_statusBar;

    JsonlDataSource          *_ds;          // kept — bridge.js still uses rawText preload
    BeadsWatcher             *_watcher;
    BeadsSchemeHandler       *_schemeHandler;
    // Phase 3: active data source for all CRUD from webview bridges.
    // `_bdRunner` is non-nil when bd is installed + project is usable.
    // `_activeDataSource` points at BdDataSource then, else at _ds (JSONL).
    BdCommandRunner          *_bdRunner;
    id<BeadsDataSource>       _activeDataSource;

    BeadsViewMode       _viewMode;
    BeadsThemePref      _themePref;
    NSString           *_lastSearchQuery;

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

    _viewMode = BeadsViewModeDashboard;
    _lastSearchQuery = @"";
    _themePref = (BeadsThemePref)[[NSUserDefaults standardUserDefaults]
        integerForKey:@"NppBeadsThemePref"];  // defaults to Auto (0)

    [self _buildUI];
    [self _refreshThemeButton];
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

    // ── Toolbar row ────────────────────────────────────────────────
    _titleBar = [[NSView alloc] init];
    _titleBar.translatesAutoresizingMaskIntoConstraints = NO;
    _titleBar.wantsLayer = YES;
    [self addSubview:_titleBar];

    // Project label — truncates middle so both start + extension stay readable.
    _titleLabel = [[NSTextField alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.bordered    = NO;
    _titleLabel.editable    = NO;
    _titleLabel.drawsBackground = NO;
    _titleLabel.font        = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    _titleLabel.textColor   = [NSColor secondaryLabelColor];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _titleLabel.stringValue = @"(no project)";
    [_titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_titleLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_titleBar addSubview:_titleLabel];

    // View-mode popup — compact, 4 options.
    _viewModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _viewModePopup.translatesAutoresizingMaskIntoConstraints = NO;
    _viewModePopup.bezelStyle = NSBezelStyleRounded;
    _viewModePopup.controlSize = NSControlSizeSmall;
    _viewModePopup.font = [NSFont systemFontOfSize:11];
    [_viewModePopup addItemWithTitle:@"Dashboard"]; [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeDashboard];
    [_viewModePopup addItemWithTitle:@"Issues"];    [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeIssues];
    [_viewModePopup addItemWithTitle:@"Insights"];  [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeInsights];
    [_viewModePopup addItemWithTitle:@"Graph"];     [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeGraph];
    [_viewModePopup addItemWithTitle:@"Board"];     [_viewModePopup.menu.itemArray.lastObject setTag:BeadsViewModeBoard];
    [_viewModePopup selectItemWithTag:_viewMode];
    _viewModePopup.target = self;
    _viewModePopup.action = @selector(_didChangeViewMode:);
    _viewModePopup.toolTip = @"Switch between Dashboard / Issues / Graph / Board";
    [_titleBar addSubview:_viewModePopup];

    // Search field — filters Board (and, in future, the Rich-viewer list).
    _searchField = [[NSSearchField alloc] init];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.controlSize = NSControlSizeSmall;
    _searchField.font = [NSFont systemFontOfSize:11];
    _searchField.placeholderString = @"Search beads";
    _searchField.delegate = self;
    _searchField.sendsSearchStringImmediately = YES;
    _searchField.sendsWholeSearchString = NO;
    [_searchField setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_titleBar addSubview:_searchField];

    _themeButton = [self _makeTitleBarButton:@"circle.lefthalf.filled"
                                      tooltip:@"Theme: Auto (click to cycle: Auto → Light → Dark)"
                                       action:@selector(_didTapTheme:)];
    [_titleBar addSubview:_themeButton];

    _refreshButton = [self _makeTitleBarButton:@"arrow.clockwise"
                                        tooltip:@"Reload issues from disk"
                                         action:@selector(_didTapRefresh:)];
    [_titleBar addSubview:_refreshButton];

    _openDirButton = [self _makeTitleBarButton:@"folder"
                                        tooltip:@"Reveal .beads/ in Finder"
                                         action:@selector(openBeadsDirInFinder:)];
    [_titleBar addSubview:_openDirButton];

    _menuButton = [self _makeTitleBarButton:@"ellipsis.circle"
                                      tooltip:@"More actions"
                                       action:@selector(_didTapMenu:)];
    [_titleBar addSubview:_menuButton];

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

    // Observe URL changes so when the Rich viewer navigates internally
    // (e.g. user clicks an issue card in Insights and viewer jumps to
    // #/issue/bd-123), our view-mode popup reflects the new state.
    [_webView addObserver:self
               forKeyPath:@"URL"
                  options:NSKeyValueObservingOptionNew
                  context:nil];
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
        // Toolbar: full width, 28pt, top.
        [_titleBar.topAnchor      constraintEqualToAnchor:self.topAnchor],
        [_titleBar.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
        [_titleBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_titleBar.heightAnchor   constraintEqualToConstant:28],

        // Project label (leftmost, hugs start, compresses to squeeze).
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_titleBar.leadingAnchor constant:8],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        // Keep the label from growing past 40% of toolbar — otherwise it
        // squeezes the search field down to the placeholder.
        [_titleLabel.widthAnchor   constraintLessThanOrEqualToAnchor:_titleBar.widthAnchor multiplier:0.40],

        // View mode popup immediately after the project label.
        [_viewModePopup.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:6],
        [_viewModePopup.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_viewModePopup.widthAnchor   constraintGreaterThanOrEqualToConstant:100],

        // Search field flexes.
        [_searchField.leadingAnchor   constraintEqualToAnchor:_viewModePopup.trailingAnchor constant:6],
        [_searchField.trailingAnchor  constraintEqualToAnchor:_themeButton.leadingAnchor constant:-6],
        [_searchField.centerYAnchor   constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_searchField.heightAnchor    constraintEqualToConstant:20],
        [_searchField.widthAnchor     constraintGreaterThanOrEqualToConstant:60],

        // Trailing cluster: theme, refresh, folder, menu.
        [_themeButton.centerYAnchor   constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_themeButton.trailingAnchor  constraintEqualToAnchor:_refreshButton.leadingAnchor constant:-2],
        [_refreshButton.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_refreshButton.trailingAnchor constraintEqualToAnchor:_openDirButton.leadingAnchor constant:-2],
        [_openDirButton.centerYAnchor constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_openDirButton.trailingAnchor constraintEqualToAnchor:_menuButton.leadingAnchor constant:-2],
        [_menuButton.centerYAnchor    constraintEqualToAnchor:_titleBar.centerYAnchor],
        [_menuButton.trailingAnchor   constraintEqualToAnchor:_titleBar.trailingAnchor constant:-6],

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
    NSLog(@"[NppBeads] _loadViewer (#%lu, mode=%ld)",
          (unsigned long)_loadCount, (long)_viewMode);
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
    NSURL *url = [self _urlForViewMode:_viewMode];
    [ds removeDataOfTypes:types
           modifiedSince:[NSDate distantPast]
       completionHandler:^{
        [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    }];
}

// Map a view mode to the nppbeads:// URL it lives at.
- (NSURL *)_urlForViewMode:(BeadsViewMode)mode {
    switch (mode) {
        case BeadsViewModeDashboard:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/"];
        case BeadsViewModeIssues:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/issues"];
        case BeadsViewModeInsights:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/insights"];
        case BeadsViewModeGraph:
            return [NSURL URLWithString:@"nppbeads://viewer/index.html#/graph"];
        case BeadsViewModeBoard:
            return [NSURL URLWithString:@"nppbeads://viewer/app/board.html"];
    }
    return [NSURL URLWithString:@"nppbeads://viewer/index.html#/"];
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

    // Theme bootstrap — run BEFORE page scripts so the viewer sees the
    // correct `dark` class on <html> and our app views pick up the right
    // [data-theme]. Without this there's a flash of wrong-theme.
    BOOL dark = [self _isDarkMode];
    NSString *themeJs = dark
        ? @"document.documentElement.classList.add('dark');"
           "document.documentElement.dataset.theme='dark';"
           "try{localStorage.setItem('darkMode','true');}catch(e){}"
        : @"document.documentElement.classList.remove('dark');"
           "document.documentElement.dataset.theme='light';"
           "try{localStorage.setItem('darkMode','false');}catch(e){}";
    [ucc addUserScript:[[WKUserScript alloc]
        initWithSource:themeJs
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    // Viewer's header + mobile bottom-nav + Dependency-Graph hero card
    // are stripped from index.html directly (search for the marker
    // comment `<!-- NppBeads:`). No runtime CSS injection needed.
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

    // Phase 3: probe bd against the project root. Pick BdDataSource when
    // bd is available + project has a working Dolt DB; fall back to JSONL
    // otherwise. Probe is async, so we default to JSONL immediately and
    // upgrade in the completion.
    _activeDataSource = _ds;
    if (project.projectRoot.length) {
        _bdRunner = [[BdCommandRunner alloc] initWithProjectDir:project.projectRoot];
        __weak typeof(self) weakSelf = self;
        [_bdRunner probeWithCompletion:^(BOOL bdPresent, BOOL projectReady) {
            __strong typeof(self) s = weakSelf;
            if (!s) return;
            if (bdPresent && projectReady) {
                s->_activeDataSource = [[BdDataSource alloc] initWithRunner:s->_bdRunner];
                NSLog(@"[NppBeads] bd backend active — %@",
                      s->_activeDataSource.backendLabel);
            } else {
                NSLog(@"[NppBeads] JSONL fallback (bd=%d, projectReady=%d)",
                      bdPresent, projectReady);
            }
            [s _refreshStatusBar];
        }];
    } else {
        _bdRunner = nil;
    }

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

// View-mode popup action: navigate webview without reloading data.
// We just change the URL; the JSONL user-script is reinstalled in case
// the user switched projects in between, but the webview reload() vs
// load(URL) distinction matters — we want a full URL change here.
- (void)_didChangeViewMode:(NSPopUpButton *)sender {
    BeadsViewMode newMode = (BeadsViewMode)sender.selectedTag;
    if (newMode == _viewMode) return;
    _viewMode = newMode;
    _viewerLoaded = NO;
    NSURL *url = [self _urlForViewMode:_viewMode];
    NSLog(@"[NppBeads] view mode → %ld (%@)", (long)newMode, url);
    // Make sure the JSONL user-script is refreshed (sticky across mode
    // switches — bridge.js re-runs on every load and re-reads the
    // WKUserScript-injected globals).
    [self _installJsonlUserScript];
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    [self _refreshTitleBar];
}

// Overflow "⋯" button reuses the right-click context menu.
- (void)_didTapMenu:(NSButton *)sender {
    NSPoint pt = NSMakePoint(0, sender.bounds.size.height + 2);
    [self.menu popUpMenuPositioningItem:nil
                             atLocation:[sender convertPoint:pt toView:nil]
                                 inView:sender.window.contentView];
}

// ─────────────────────────────────────────────────────────────────────────
//  NSSearchFieldDelegate — live search
// ─────────────────────────────────────────────────────────────────────────
- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object != _searchField) return;
    NSString *q = _searchField.stringValue ?: @"";
    if ([q isEqualToString:_lastSearchQuery]) return;
    _lastSearchQuery = [q copy];
    [self _pushSearchQuery:q];
}

- (void)_pushSearchQuery:(NSString *)q {
    if (!_viewerLoaded) return;
    NSString *js = nil;
    if (_viewMode == BeadsViewModeBoard) {
        // Board (our native page) exposes window.__nppApp.setFilter.
        js = [NSString stringWithFormat:
            @"if (window.__nppApp && typeof window.__nppApp.setFilter === 'function') {"
             "  window.__nppApp.setFilter({ query: %@ });"
             "}",
            jsStringLiteral(q)];
    } else if (_viewMode == BeadsViewModeIssues) {
        // Rich Issues — bridge.js installs __nppRichSearch which routes
        // into the Alpine root and calls loadIssues() (LIKE fallback for
        // missing FTS5).
        js = [NSString stringWithFormat:
            @"if (typeof window.__nppRichSearch === 'function') {"
             "  window.__nppRichSearch(%@);"
             "}",
            jsStringLiteral(q)];
    } else {
        return;   // Dashboard/Insights/Graph — search is hidden anyway
    }
    [_webView evaluateJavaScript:js completionHandler:nil];
}

// ─────────────────────────────────────────────────────────────────────────
//  Dark/light theme sync — track macOS system appearance
// ─────────────────────────────────────────────────────────────────────────
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self _pushThemeToWebView];
}

- (BOOL)_isDarkMode {
    switch (_themePref) {
        case BeadsThemePrefLight: return NO;
        case BeadsThemePrefDark:  return YES;
        case BeadsThemePrefAuto:
        default: {
            NSAppearanceName match = [self.effectiveAppearance
                bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                     NSAppearanceNameDarkAqua ]];
            return [match isEqualToString:NSAppearanceNameDarkAqua];
        }
    }
}

// Cycle Auto → Light → Dark → Auto. Persist. Reflect new state in
// the button icon/tooltip and push a theme update to the webview.
- (void)_didTapTheme:(id)sender {
    _themePref = (BeadsThemePref)((_themePref + 1) % 3);
    [[NSUserDefaults standardUserDefaults] setInteger:_themePref
                                               forKey:@"NppBeadsThemePref"];
    [self _refreshThemeButton];
    [self _pushThemeToWebView];
}

- (void)_refreshThemeButton {
    if (!_themeButton) return;
    NSString *symbol, *tip;
    switch (_themePref) {
        case BeadsThemePrefLight:
            symbol = @"sun.max";
            tip = @"Theme: Light (click to cycle to Dark)";
            break;
        case BeadsThemePrefDark:
            symbol = @"moon";
            tip = @"Theme: Dark (click to cycle to Auto)";
            break;
        case BeadsThemePrefAuto:
        default:
            symbol = @"circle.lefthalf.filled";
            tip = @"Theme: Auto (follows macOS) — click to cycle to Light";
            break;
    }
    if (@available(macOS 11.0, *)) {
        _themeButton.image = [NSImage imageWithSystemSymbolName:symbol
                                     accessibilityDescription:tip];
    }
    _themeButton.toolTip = tip;
}

- (void)_pushThemeToWebView {
    if (!_webView) return;
    BOOL dark = [self _isDarkMode];
    // The Rich viewer toggles `dark` class on <html> and reads/writes
    // localStorage.darkMode. Our own app views read
    // document.documentElement.dataset.theme. Update both in one pass
    // so either surface is correct.
    NSString *js = dark
        ? @"document.documentElement.classList.add('dark');"
           "document.documentElement.dataset.theme = 'dark';"
           "try{localStorage.setItem('darkMode','true');}catch(e){}"
           "if(window.__nppApp)window.__nppApp.setTheme('dark');"
        : @"document.documentElement.classList.remove('dark');"
           "document.documentElement.dataset.theme = 'light';"
           "try{localStorage.setItem('darkMode','false');}catch(e){}"
           "if(window.__nppApp)window.__nppApp.setTheme('light');";
    [_webView evaluateJavaScript:js completionHandler:nil];
}

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
        _titleLabel.stringValue = self.project.projectRoot.lastPathComponent ?: @"(project)";
        _titleLabel.toolTip    = self.project.projectRoot;
        _refreshButton.enabled = YES;
        _openDirButton.enabled = YES;
        _viewModePopup.enabled = YES;
        _searchField.enabled   = YES;
    } else {
        _titleLabel.stringValue = @"(no project)";
        _titleLabel.toolTip    = @"Open a file inside a repo containing a .beads/ directory.";
        _refreshButton.enabled = NO;
        _openDirButton.enabled = NO;
        _viewModePopup.enabled = NO;
        _searchField.enabled   = NO;
    }
    [_viewModePopup selectItemWithTag:_viewMode];

    // Search field: Board + Issues (where per-issue filtering applies).
    // Dashboard / Insights are aggregates; Graph has its own "Find node…".
    // Issues uses a LIKE fallback on loadIssues (we bypass FTS5).
    BOOL showSearch = (_viewMode == BeadsViewModeBoard ||
                       _viewMode == BeadsViewModeIssues);
    _searchField.hidden = !showSearch;
    if (!showSearch && _searchField.stringValue.length) {
        // Clear any stale query so switching back to Board shows the
        // full list.
        _searchField.stringValue = @"";
        _lastSearchQuery = @"";
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
    NSString *backend = _activeDataSource.backendLabel ?: @"read-only (JSONL)";
    _statusLabel.stringValue = [NSString stringWithFormat:
        @"%@ · %lu issues (%lu open · %lu blocked · %lu closed) · %@",
        self.project.projectRoot.lastPathComponent ?: @"(project)",
        (unsigned long)total, (unsigned long)open,
        (unsigned long)blkd,  (unsigned long)cls,
        backend];
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
    } else if ([type isEqualToString:@"openBeadDetails"]) {
        NSString *bid = body[@"id"];
        if ([bid isKindOfClass:[NSString class]] && bid.length > 0) {
            // Phase 2: jump to the Rich viewer's detail route. Phase 4
            // introduces our native Detail view which will claim this.
            _viewMode = BeadsViewModeDashboard;   // index.html is where #/issue/… lives
            [_viewModePopup selectItemWithTag:BeadsViewModeDashboard];
            NSCharacterSet *safe = [NSCharacterSet URLPathAllowedCharacterSet];
            NSString *encoded = [bid stringByAddingPercentEncodingWithAllowedCharacters:safe];
            NSString *href = [NSString stringWithFormat:
                @"nppbeads://viewer/index.html#/issue/%@", encoded];
            _viewerLoaded = NO;
            [_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:href]]];
        }
    } else if ([type isEqualToString:@"updateBead"]) {
        [self _handleUpdateBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"createBead"]) {
        [self _handleCreateBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"closeBead"]) {
        [self _handleCloseBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"reopenBead"]) {
        [self _handleReopenBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"claimBead"]) {
        [self _handleClaimBead:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"depAdd"]) {
        [self _handleDepAdd:body requestId:body[@"reqId"]];
    } else if ([type isEqualToString:@"depRemove"]) {
        [self _handleDepRemove:body requestId:body[@"reqId"]];
    } else {
        // Unknown message — ignore for forward-compat.
    }
}

// ─────────────────────────────────────────────────────────────────────────
//  Bridge: write handlers → _activeDataSource
//
//  Every write responds back to the webview via
//    window.__nppBridge.resolve(reqId, {ok, bead?, error?, errorKind?, blockers?})
//  The webview side (app.js helper in bridge.js) tracks pending requests
//  by reqId and resolves the matching Promise. This keeps JS code
//  write-agnostic and lets all views react uniformly.
// ─────────────────────────────────────────────────────────────────────────

- (void)_resolveRequest:(nullable NSString *)reqId
                     ok:(BOOL)ok
                   bead:(nullable NSDictionary *)bead
                  error:(nullable NSError *)err {
    if (!reqId.length) return;
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"ok"] = @(ok);
    if (bead) payload[@"bead"] = bead;
    if (err) {
        payload[@"error"] = err.localizedDescription ?: @"unknown";
        payload[@"errorKind"] = @(err.code);
        NSArray *blockers = err.userInfo[@"blockers"];
        if (blockers.count) payload[@"blockers"] = blockers;
    }
    NSError *jerr = nil;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:payload
                                                 options:0 error:&jerr];
    if (!jd) return;
    NSString *jstr = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
    if (!jstr) return;
    NSString *encodedReq = [reqId stringByReplacingOccurrencesOfString:@"\""
                                                            withString:@"\\\""];
    NSString *js = [NSString stringWithFormat:
        @"if (window.__nppBridge && typeof window.__nppBridge.resolve === 'function') {"
         "  window.__nppBridge.resolve(\"%@\", %@);"
         "}", encodedReq, jstr];
    [_webView evaluateJavaScript:js completionHandler:nil];
}

// Trigger a fresh list on all views after any successful write, so the
// Board/Issues/Details panels catch up without waiting for the next poll.
// CRITICAL: bd auto-exports issues.jsonl on every write (via its post-
// commit hook). To reflect that on-disk change, we must (1) invalidate
// the bd cache, (2) reload the JsonlDataSource so it re-reads the file,
// and (3) push the fresh text to JS — both as the preloaded global
// (so a subsequent navigation sees the new data) and via reload() so
// the currently-rendered view updates now.
- (void)_broadcastDataChanged {
    [_activeDataSource invalidateCache];
    [_ds reload];                         // JSONL cache — forces re-read on next rawText
    NSString *fresh = [_ds rawText] ?: @"";
    [self _refreshStatusBar];             // counters in status bar
    NSString *jsLit = jsStringLiteral(fresh);
    NSString *js = [NSString stringWithFormat:
        @"window.__nppBeadsPreloadedJsonl = %@;"
         "if (window.__nppApp && typeof window.__nppApp.reload === 'function') {"
         "  window.__nppApp.reload(window.__nppBeadsPreloadedJsonl);"
         "} else if (window.__nppBeads && typeof window.__nppBeads.receiveJsonl === 'function') {"
         "  window.__nppBeads.receiveJsonl(window.__nppBeadsPreloadedJsonl);"
         "}", jsLit];
    [_webView evaluateJavaScript:js completionHandler:^(id r, NSError *e) {
        if (e) NSLog(@"[NppBeads] _broadcastDataChanged eval error: %@", e);
    }];
}

- (void)_handleUpdateBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid     = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *status  = [body[@"status"] isKindOfClass:[NSString class]] ? body[@"status"] : nil;
    NSString *title   = [body[@"title"]  isKindOfClass:[NSString class]] ? body[@"title"]  : nil;
    NSString *descr   = [body[@"description"] isKindOfClass:[NSString class]] ? body[@"description"] : nil;
    NSNumber *prio    = [body[@"priority"] isKindOfClass:[NSNumber class]] ? body[@"priority"] : nil;
    // NOTE: the bridge envelope itself uses `type` for message routing
    // (updateBead/createBead/…), so bead-issue-type lives under
    // `issueType`. Reading `type` here would pass the message name to
    // `bd --type` and make every drag a bogus-type update.
    NSString *type    = [body[@"issueType"] isKindOfClass:[NSString class]] ? body[@"issueType"] : nil;
    NSString *assgn   = [body[@"assignee"] isKindOfClass:[NSString class]] ? body[@"assignee"] : nil;
    NSArray  *addL    = [body[@"addLabels"]    isKindOfClass:[NSArray class]] ? body[@"addLabels"]    : nil;
    NSArray  *rmL     = [body[@"removeLabels"] isKindOfClass:[NSArray class]] ? body[@"removeLabels"] : nil;

    if (!bid.length) {
        [self _resolveRequest:reqId ok:NO bead:nil
                        error:[NSError errorWithDomain:BeadsDataSourceErrorDomain
                                                  code:BeadsDataSourceErrorGeneric
                                              userInfo:@{NSLocalizedDescriptionKey:@"missing id"}]];
        return;
    }
    NSLog(@"[NppBeads] updateBead id=%@ status=%@ backend=%@",
          bid, status ?: @"(nil)", _activeDataSource.backendLabel ?: @"?");
    __weak typeof(self) weakSelf = self;
    [_activeDataSource updateIssue:bid title:title description:descr status:status
                          priority:prio type:type assignee:assgn
                         addLabels:addL removeLabels:rmL
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        if (err) {
            NSLog(@"[NppBeads] updateBead %@ FAILED: code=%ld msg=%@",
                  bid, (long)err.code, err.localizedDescription);
        } else {
            NSLog(@"[NppBeads] updateBead %@ OK new_status=%@",
                  bid, bead[@"status"] ?: @"(none)");
        }
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleCreateBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *title = [body[@"title"] isKindOfClass:[NSString class]] ? body[@"title"] : nil;
    NSString *type  = [body[@"issueType"] isKindOfClass:[NSString class]] ? body[@"issueType"] : nil;
    NSNumber *prio  = [body[@"priority"] isKindOfClass:[NSNumber class]] ? body[@"priority"] : nil;
    NSString *descr = [body[@"description"] isKindOfClass:[NSString class]] ? body[@"description"] : nil;
    NSArray  *lbls  = [body[@"labels"] isKindOfClass:[NSArray class]] ? body[@"labels"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource createIssueWithTitle:title type:type priority:prio
                                 description:descr labels:lbls
                                  completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleCloseBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid    = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *reason = [body[@"reason"] isKindOfClass:[NSString class]] ? body[@"reason"] : nil;
    BOOL      force  = [body[@"force"] boolValue];
    __weak typeof(self) weakSelf = self;
    [_activeDataSource closeIssue:bid reason:reason force:force
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleReopenBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid    = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    NSString *reason = [body[@"reason"] isKindOfClass:[NSString class]] ? body[@"reason"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource reopenIssue:bid reason:reason
                        completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleClaimBead:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *bid = [body[@"id"] isKindOfClass:[NSString class]] ? body[@"id"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource claimIssue:bid completion:^(NSDictionary *bead, NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:bead error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleDepAdd:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *dep  = [body[@"dependent"]  isKindOfClass:[NSString class]] ? body[@"dependent"]  : nil;
    NSString *dpd  = [body[@"dependency"] isKindOfClass:[NSString class]] ? body[@"dependency"] : nil;
    NSString *kind = [body[@"depType"]    isKindOfClass:[NSString class]] ? body[@"depType"]    : @"blocks";
    __weak typeof(self) weakSelf = self;
    [_activeDataSource addDependencyFromIssue:dep toIssue:dpd type:kind
                                  completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
}

- (void)_handleDepRemove:(NSDictionary *)body requestId:(NSString *)reqId {
    NSString *dep  = [body[@"dependent"]  isKindOfClass:[NSString class]] ? body[@"dependent"]  : nil;
    NSString *dpd  = [body[@"dependency"] isKindOfClass:[NSString class]] ? body[@"dependency"] : nil;
    __weak typeof(self) weakSelf = self;
    [_activeDataSource removeDependencyFromIssue:dep toIssue:dpd
                                     completion:^(NSError *err) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s _resolveRequest:reqId ok:(err == nil) bead:nil error:err];
        if (!err) [s _broadcastDataChanged];
    }];
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
- (void)dealloc {
    @try { [_webView removeObserver:self forKeyPath:@"URL"]; }
    @catch (NSException *e) { /* not added */ }
}

// Fires when the panel's host window changes — pop-out to a floating
// panel, docking back into the side-panel stack, or parent-window
// reparenting. Alpine keeps its reactive state across these transitions
// but its x-transition animations often leave overlays (the graph
// detail panel, the selectedIssue modal) in a "visible-but-zombie"
// state. We nudge Alpine to clear them.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!_viewerLoaded || !_webView || !self.window) return;
    [_webView evaluateJavaScript:
        @"if (typeof window.__nppClearTransientState === 'function') {"
         "  window.__nppClearTransientState();"
         "}"
        completionHandler:nil];
}

// Called by NppBeads.mm every time the user shows the panel. Resets
// the view to Dashboard + clears the search so re-opening feels fresh
// rather than resuming whatever weird state the user last left behind.
- (void)prepareForShow {
    _viewMode = BeadsViewModeDashboard;
    [_viewModePopup selectItemWithTag:_viewMode];
    _searchField.stringValue = @"";
    _lastSearchQuery = @"";
    [self _refreshTitleBar];
    // Full reload so Alpine re-inits and any transient overlay (graph
    // detail panel, issue modal) is definitely gone.
    _viewerLoaded = NO;
    [self _installJsonlUserScript];
    [_webView loadRequest:[NSURLRequest requestWithURL:
        [self _urlForViewMode:_viewMode]]];
}

// KVO: webView.URL changed. Map it back to a BeadsViewMode and update
// the popup so internal navigation stays in sync with our toolbar.
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)ctx {
    if (object != _webView || ![keyPath isEqualToString:@"URL"]) return;
    NSURL *url = _webView.URL;
    if (!url) return;
    BeadsViewMode detected = [self _viewModeFromURL:url];
    if (detected != _viewMode) {
        _viewMode = detected;
        [_viewModePopup selectItemWithTag:_viewMode];
        [self _refreshTitleBar];
    }
}

// Map a current webView URL back to the popup's view mode. Detail
// routes (#/issue/bd-…) count as Issues since that's where detail is
// rendered. Unknown URLs stay on current.
- (BeadsViewMode)_viewModeFromURL:(NSURL *)url {
    NSString *path = url.path ?: @"";
    NSString *frag = url.fragment ?: @"";
    if ([path hasSuffix:@"/app/board.html"]) return BeadsViewModeBoard;
    if ([path hasSuffix:@"/index.html"] || path.length == 0) {
        if ([frag hasPrefix:@"/graph"])    return BeadsViewModeGraph;
        if ([frag hasPrefix:@"/insights"]) return BeadsViewModeInsights;
        if ([frag hasPrefix:@"/issues"] ||
            [frag hasPrefix:@"/issue/"])   return BeadsViewModeIssues;
        return BeadsViewModeDashboard;
    }
    return _viewMode;
}

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
    // Re-apply theme + current search filter for this freshly-loaded page.
    [self _pushThemeToWebView];
    if (_lastSearchQuery.length) [self _pushSearchQuery:_lastSearchQuery];
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
