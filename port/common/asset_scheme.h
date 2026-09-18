//------------------------------------------------------------------------
// auxVST PoC — Stage 2: custom WKWebView URL scheme handler
//
// Serves the bundled web UI from Contents/Resources/<rootSubdir> over a
// custom scheme (auxvst://ui/...) instead of file://. This avoids WKWebView's
// file:// restrictions (ES modules, fetch, CORS) and gives clean, instant,
// offline loads that look native — a key seamless-rendering requirement.
//
// ObjC-only header: include from Objective-C++ (.mm) translation units.
//------------------------------------------------------------------------

#pragma once

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Scheme + canonical entry URL for the web UI.
extern NSString* const kAuxURLScheme;   // @"auxvst"
extern NSString* const kAuxUIHost;      // @"ui"
extern NSString* const kAuxUIIndexURL;  // @"auxvst://ui/index.html"

// WKURLSchemeHandler that maps auxvst://ui/<path> to a file inside the
// plug-in bundle's Resources/<rootSubdir>/<path>. Path traversal is rejected.
@interface AuxSchemeHandler : NSObject <WKURLSchemeHandler>

// Resources subdirectory that holds the web assets. Defaults to @"webui".
@property (nonatomic, copy) NSString* rootSubdir;

@end

NS_ASSUME_NONNULL_END
