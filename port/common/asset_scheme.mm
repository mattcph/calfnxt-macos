//------------------------------------------------------------------------
// auxVST common — custom WKWebView URL scheme handler (implementation)
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//------------------------------------------------------------------------

#import "asset_scheme.h"

NSString* const kAuxURLScheme  = @"auxvst";
NSString* const kAuxUIHost     = @"ui";
NSString* const kAuxUIIndexURL = @"auxvst://ui/index.html";

//------------------------------------------------------------------------
static NSString* AuxMimeTypeForExtension (NSString* ext)
{
	static NSDictionary<NSString*, NSString*>* map = nil;
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		map = @{
			@"html" : @"text/html; charset=utf-8",
			@"htm"  : @"text/html; charset=utf-8",
			@"js"   : @"text/javascript; charset=utf-8",
			@"mjs"  : @"text/javascript; charset=utf-8",
			@"css"  : @"text/css; charset=utf-8",
			@"json" : @"application/json; charset=utf-8",
			@"map"  : @"application/json; charset=utf-8",
			@"svg"  : @"image/svg+xml",
			@"png"  : @"image/png",
			@"jpg"  : @"image/jpeg",
			@"jpeg" : @"image/jpeg",
			@"gif"  : @"image/gif",
			@"webp" : @"image/webp",
			@"ico"  : @"image/x-icon",
			@"woff" : @"font/woff",
			@"woff2": @"font/woff2",
			@"ttf"  : @"font/ttf",
			@"wasm" : @"application/wasm",
		};
	});
	NSString* mime = map[[ext lowercaseString]];
	return mime ?: @"application/octet-stream";
}

//------------------------------------------------------------------------
@implementation AuxSchemeHandler

- (instancetype)init
{
	if ((self = [super init]))
	{
		_rootSubdir = @"webui";
	}
	return self;
}

//------------------------------------------------------------------------
// Root directory of the web assets inside this plug-in's bundle.
- (nullable NSString*)webRootPath
{
	NSBundle* bundle = [NSBundle bundleForClass:[self class]];
	NSString* resources = bundle.resourcePath;
	if (!resources)
		return nil;
	return [resources stringByAppendingPathComponent:self.rootSubdir];
}

//------------------------------------------------------------------------
- (void)webView:(WKWebView*)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask
{
	NSURL* url = urlSchemeTask.request.URL;

	// Map auxvst://ui/<path> to <resources>/<rootSubdir>/<path>.
	NSString* relPath = url.path; // begins with "/"
	if (relPath.length == 0 || [relPath isEqualToString:@"/"])
		relPath = @"/index.html";

	NSString* webRoot = [self webRootPath];
	if (!webRoot)
	{
		[self failTask:urlSchemeTask url:url code:500 reason:@"no bundle resources"];
		return;
	}

	NSString* candidate = [[webRoot stringByAppendingPathComponent:relPath] stringByStandardizingPath];
	NSString* canonicalRoot = [webRoot stringByStandardizingPath];

	// Reject path traversal: the resolved file must live under the web root.
	if (![candidate hasPrefix:[canonicalRoot stringByAppendingString:@"/"]] &&
	    ![candidate isEqualToString:canonicalRoot])
	{
		[self failTask:urlSchemeTask url:url code:403 reason:@"forbidden"];
		return;
	}

	NSData* data = [NSData dataWithContentsOfFile:candidate];
	if (!data)
	{
		[self failTask:urlSchemeTask url:url code:404 reason:@"not found"];
		return;
	}

	NSString* mime = AuxMimeTypeForExtension (candidate.pathExtension);

	NSDictionary* headers = @{
		@"Content-Type"   : mime,
		@"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
		// Same-origin app: allow the UI to fetch its own assets/modules freely.
		@"Access-Control-Allow-Origin" : @"*",
		@"Cache-Control"  : @"no-cache",
	};

	NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc] initWithURL:url
	                                                         statusCode:200
	                                                        HTTPVersion:@"HTTP/1.1"
	                                                       headerFields:headers];
	[urlSchemeTask didReceiveResponse:response];
	[urlSchemeTask didReceiveData:data];
	[urlSchemeTask didFinish];
}

//------------------------------------------------------------------------
- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask
{
	// Nothing to cancel: responses are produced synchronously.
}

//------------------------------------------------------------------------
- (void)failTask:(id<WKURLSchemeTask>)task url:(NSURL*)url code:(NSInteger)code reason:(NSString*)reason
{
	NSHTTPURLResponse* response = [[NSHTTPURLResponse alloc] initWithURL:url
	                                                         statusCode:code
	                                                        HTTPVersion:@"HTTP/1.1"
	                                                       headerFields:@{ @"Content-Type" : @"text/plain" }];
	[task didReceiveResponse:response];
	[task didReceiveData:[reason dataUsingEncoding:NSUTF8StringEncoding]];
	[task didFinish];
}

@end
