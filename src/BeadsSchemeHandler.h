// BeadsSchemeHandler — WKURLSchemeHandler that serves the bundled viewer
// over a custom `nppbeads://` scheme instead of `file://`.
//
// Why this exists: under `file://` in WKWebView, every file is its own
// security origin. That breaks:
//   • ES-module dynamic `import()` of sibling files (cross-origin error)
//   • `WebAssembly.instantiateStreaming` (needs application/wasm MIME)
//   • XHR / fetch to sibling files (random failures)
//
// Serving over a single custom scheme (where every URL shares the
// `nppbeads://viewer/` origin) makes all of those Just Work.
//
// The handler:
//   • maps `nppbeads://viewer/<path>` → `<viewerRoot>/<path>` on disk
//   • sets sensible Content-Type per extension (including application/wasm)
//   • rejects `..` traversal
//   • cancels in-flight I/O if WKWebView calls `stopURLSchemeTask`.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BeadsSchemeHandler : NSObject <WKURLSchemeHandler>

// Absolute path to the directory that will be exposed at
// `nppbeads://viewer/…`. Typically the plugin's `resources/viewer/`.
@property (nonatomic, copy, readonly) NSString *viewerRoot;

- (instancetype)initWithViewerRoot:(NSString *)root NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
