//------------------------------------------------------------------------
// auxVST common — WebViewPlugView + ParamBridge transport
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//------------------------------------------------------------------------

#import "webview_plugview.h"
#import "asset_scheme.h"

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include "pluginterfaces/gui/iplugview.h"

#include <cmath>
#include <cstdlib>
#include <cstring>

@interface AuxWebViewState : NSObject <WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate>
@property (nonatomic, strong) WKWebView* webView;
@property (nonatomic, strong) AuxSchemeHandler* scheme;
@property (nonatomic, assign) void* plugView; // Steinberg::Vst::WebViewPlugView*
@property (nonatomic, copy) NSString* debugLogPath;
@property (nonatomic, weak) NSView* parentView;
@property (nonatomic, assign) BOOL observingParentFrame;
@property (nonatomic, assign) CGFloat lastNotifiedW;
@property (nonatomic, assign) CGFloat lastNotifiedH;
@property (nonatomic, assign) BOOL occluded;
- (void)applyViewportForce:(BOOL)force;
- (void)requestHostFillIfNeeded;
- (void)stopObservingParentFrame;
- (void)reloadAfterCrash;
@end

/* One shared process pool + configuration across all editors, so N plugin
 * instances share a single WebContent process instead of one per editor. */
static WKProcessPool* AuxSharedProcessPool ()
{
	static WKProcessPool* pool = nil;
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		pool = [[WKProcessPool alloc] init];
	});
	return pool;
}

static WKWebsiteDataStore* AuxSharedDataStore ()
{
	static WKWebsiteDataStore* store = nil;
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		store = [WKWebsiteDataStore defaultDataStore];
	});
	return store;
}

/* WebView matches the VST parent NSView only. If the host window is larger
 * (Nuendo workspace restore), ask IPlugFrame::resizeView to grow the parent. */
static NSSize AuxResolveEditorSize (WKWebView* webView, CGFloat fallbackW, CGFloat fallbackH)
{
	NSView* parent = webView.superview;
	if (parent)
	{
		NSSize pb = parent.bounds.size;
		if (pb.width >= 1.0 && pb.height >= 1.0)
			return pb;
	}
	return NSMakeSize (fallbackW, fallbackH);
}

static void AuxApplyNativeFrame (WKWebView* webView, NSSize sz)
{
	if (!webView || sz.width < 1.0 || sz.height < 1.0)
		return;
	webView.frame = NSMakeRect (0, 0, sz.width, sz.height);
}

static void AuxDispatchJsViewport (WKWebView* webView, NSSize sz)
{
	if (!webView || sz.width < 1.0 || sz.height < 1.0)
		return;
	NSString* js = [NSString stringWithFormat:
	    @"window.dispatchEvent(new Event('resize'));"
	     "window.dispatchEvent(new CustomEvent('auxvst-viewport',"
	     "{detail:{width:%.0f,height:%.0f}}));",
	    sz.width, sz.height];
	[webView evaluateJavaScript:js completionHandler:nil];
}

static bool AuxDebugEnabled ()
{
	static int enabled = -1;
	if (enabled < 0)
	{
		const char* v = getenv ("AUXVST_DEBUG");
		enabled = (v && v[0] && std::strcmp (v, "0") != 0) ? 1 : 0;
	}
	return enabled == 1;
}

static void AuxDebugLogTo (NSString* path, NSString* line, BOOL reset)
{
	if (!AuxDebugEnabled () || !path.length)
		return;
	static NSDateFormatter* ts = nil;
	static dispatch_once_t once;
	dispatch_once (&once, ^{
		ts = [[NSDateFormatter alloc] init];
		ts.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		ts.dateFormat = @"HH:mm:ss.SSS";
	});
	NSString* stamped =
	    [NSString stringWithFormat:@"[%@] %@", [ts stringFromDate:[NSDate date]], line];
	NSString* out = [stamped stringByAppendingString:@"\n"];
	NSData* data = [out dataUsingEncoding:NSUTF8StringEncoding];
	if (reset)
	{
		[data writeToFile:path atomically:YES];
		return;
	}
	NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!fh)
	{
		[data writeToFile:path atomically:YES];
		return;
	}
	@try { [fh seekToEndOfFile]; [fh writeData:data]; } @catch (...) {}
	[fh closeFile];
}

/* First click on a non-key editor window activates the window AND reaches the
 * widget; the default NSView policy would eat that click for activation. */
@interface AuxWebView : WKWebView
@property (nonatomic, weak) AuxWebViewState* auxState;
@property (nonatomic, assign) NSInteger auxSavedLevel;
@property (nonatomic, assign) BOOL auxPinned;
@end

@implementation AuxWebView

- (BOOL)acceptsFirstMouse:(NSEvent*)event
{
	(void)event;
	return YES;
}

- (void)auxPinWindow
{
	NSWindow* w = self.window;
	if (!w || self.auxPinned)
		return;
	self.auxSavedLevel = w.level;
	self.auxPinned = YES;
	/* Live orderFronts the last-opened editor during an open parameter
	   gesture without making it key. Sibling plug-in windows sit at
	   NSFloatingWindowLevel; pin above them for the drag. */
	w.level = NSModalPanelWindowLevel;
}

- (void)auxUnpinWindow
{
	NSWindow* w = self.window;
	if (!w || !self.auxPinned)
		return;
	w.level = self.auxSavedLevel;
	self.auxPinned = NO;
	[w orderFront:self];
}

/* Live makes a content-clicked editor window key without ordering it front
 * (title-bar clicks raise through Live's own path), so the clicked editor
 * stays behind other plug-in windows. Raise it on content click. */
- (void)mouseDown:(NSEvent*)event
{
	[self.window orderFront:self];
	[self auxPinWindow];
	if (self.auxState.plugView)
		reinterpret_cast<Steinberg::Vst::WebViewPlugView*> (self.auxState.plugView)->gesture (true);
	[super mouseDown:event];
}

- (void)mouseUp:(NSEvent*)event
{
	[self auxUnpinWindow];
	if (self.auxState.plugView)
		reinterpret_cast<Steinberg::Vst::WebViewPlugView*> (self.auxState.plugView)->gesture (false);
	[super mouseUp:event];
}

@end

@implementation AuxWebViewState

- (void)applyViewportForce:(BOOL)force
{
	WKWebView* webView = self.webView;
	if (!webView)
		return;

	void (^run)(void) = ^{
		NSView* parent = webView.superview;
		NSWindow* win = webView.window ?: parent.window;
		NSSize parentSz = parent ? parent.bounds.size : NSZeroSize;
		NSSize contentSz = win.contentView ? win.contentView.bounds.size : NSZeroSize;
		NSSize sz = AuxResolveEditorSize (webView, self.lastNotifiedW, self.lastNotifiedH);
		if (sz.width < 1.0 || sz.height < 1.0)
			return;
		BOOL changed = (fabs (sz.width - self.lastNotifiedW) >= 1.0 ||
		                fabs (sz.height - self.lastNotifiedH) >= 1.0);
		if (!force && !changed)
			return;
		self.lastNotifiedW = sz.width;
		self.lastNotifiedH = sz.height;
		AuxApplyNativeFrame (webView, sz);
		AuxDispatchJsViewport (webView, sz);
		BOOL parentLtContent =
		    (contentSz.width >= parentSz.width + 2.0 || contentSz.height >= parentSz.height + 2.0);
		if (parentLtContent)
			[self requestHostFillIfNeeded];
	};

	if ([NSThread isMainThread])
		run ();
	else
		dispatch_async (dispatch_get_main_queue (), run);
}

- (void)requestHostFillIfNeeded
{
	if (!self.plugView)
		return;
	using namespace Steinberg::Vst;
	auto* view = reinterpret_cast<WebViewPlugView*> (self.plugView);
	view->requestHostFillIfNeeded ();
}

- (void)notifyViewportWithFollowUps:(BOOL)followUps
{
	[self applyViewportForce:YES];
	[self requestHostFillIfNeeded];
	if (!followUps)
		return;
	__weak AuxWebViewState* weakSelf = self;
	dispatch_async (dispatch_get_main_queue (), ^{
		[weakSelf applyViewportForce:YES];
		[weakSelf requestHostFillIfNeeded];
	});
}

- (void)parentFrameDidChange:(NSNotification*)note
{
	(void)note;
	[self applyViewportForce:NO];
}

- (void)windowDidResize:(NSNotification*)note
{
	(void)note;
	[self applyViewportForce:YES];
}

- (void)startObservingParentFrame:(NSView*)parent
{
	[self stopObservingParentFrame];
	if (!parent)
		return;
	parent.postsFrameChangedNotifications = YES;
	self.parentView = parent;
	NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self
	       selector:@selector(parentFrameDidChange:)
	           name:NSViewFrameDidChangeNotification
	         object:parent];
	if (parent.window)
	{
		[nc addObserver:self
		       selector:@selector(windowDidResize:)
		           name:NSWindowDidResizeNotification
		         object:parent.window];
	}
	self.observingParentFrame = YES;
}

- (void)stopObservingParentFrame
{
	if (!self.observingParentFrame)
		return;
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	self.observingParentFrame = NO;
	self.parentView = nil;
}

- (void)dealloc
{
	[self stopObservingParentFrame];
}

- (void)userContentController:(WKUserContentController*)userContentController
      didReceiveScriptMessage:(WKScriptMessage*)message
{
	using namespace Steinberg::Vst;

	id body = message.body;
	if (![body isKindOfClass:[NSDictionary class]])
		return;
	NSDictionary* dict = (NSDictionary*)body;

	NSString* t = dict[@"t"];
	if (![t isKindOfClass:[NSString class]])
		return;

	/* UI diagnostics land in the AUXVST_DEBUG file log. */
	if ([t isEqualToString:@"_diag"])
	{
		NSString* m = dict[@"msg"];
		if ([m isKindOfClass:[NSString class]])
		{
			AuxDebugLogTo (self.debugLogPath, [@"[ui] " stringByAppendingString:m], NO);
		}
		return;
	}

	/* {t:…} messages route to the product editor as JSON text.
	 * WKScriptMessage delivers JS numbers as NSNumber (double) and
	 * NSJSONSerialization emits shortest round-trip literals, so plain
	 * float values survive losslessly. */
	if (self.plugView)
	{
		auto* view = reinterpret_cast<WebViewPlugView*> (self.plugView);
		NSData* data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
		if (data)
			view->forwardRawMessage (std::string ((const char*)data.bytes, data.length));
	}
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	webView.hidden = NO;
	[self notifyViewportWithFollowUps:YES];
	/* Page-ready signal: navigation completion is the port's ready handshake. */
	if (self.plugView)
	{
		auto* view = reinterpret_cast<Steinberg::Vst::WebViewPlugView*> (self.plugView);
		view->navigationFinished ();
	}
}

/* The editor UI never navigates away from its entry page: allow the asset
 * scheme (and the AUXVST_DEV_URL http(s) override in dev), cancel the rest. */
- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = navigationAction.request.URL;
	NSString* scheme = url.scheme.lowercaseString;
	BOOL allow = [scheme isEqualToString:kAuxURLScheme] || [scheme isEqualToString:@"about"];
	if (!allow && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
	{
		const char* devUrl = getenv ("AUXVST_DEV_URL");
		allow = devUrl && devUrl[0] != '\0';
	}
	decisionHandler (allow ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

/* WebContent process crashed (OOM, etc.): reload; didFinishNavigation re-runs
 * the ready handshake and the editor re-pushes all params. */
- (void)webViewWebContentProcessDidTerminate:(WKWebView*)webView
{
	AuxDebugLogTo (self.debugLogPath, @"[native] WebContent terminated — reloading", NO);
	[self reloadAfterCrash];
}

- (void)reloadAfterCrash
{
	WKWebView* webView = self.webView;
	if (!webView)
		return;
	void (^run)(void) = ^{ [webView reload]; };
	if ([NSThread isMainThread])
		run ();
	else
		dispatch_async (dispatch_get_main_queue (), run);
}

/* Occlusion / hidden gating: when the host window is occluded, stop the viz
 * drain so idle editors sleep (DSP short-circuits history/FFT on this flag). */
- (void)updateOcclusion
{
	NSWindow* win = self.webView.window ?: self.parentView.window;
	BOOL occluded = win ? (([win occlusionState] & NSWindowOcclusionStateVisible) == 0) : NO;
	if (occluded == self.occluded)
		return;
	self.occluded = occluded;
	if (self.plugView)
	{
		using namespace Steinberg::Vst;
		auto* view = reinterpret_cast<WebViewPlugView*> (self.plugView);
		view->setOccluded (occluded);
	}
}

- (void)windowOcclusionDidChange:(NSNotification*)note
{
	(void)note;
	[self updateOcclusion];
}

@end

//------------------------------------------------------------------------
namespace Steinberg {
namespace Vst {

WebViewPlugView::WebViewPlugView (EditController* c, ParamBridge* b, WebViewPlugViewConfig cfg)
: CPluginView (nullptr), controller (c), bridge (b), config (std::move (cfg))
{
	ViewRect r (0, 0, config.width, config.height);
	setRect (r);
}

WebViewPlugView::~WebViewPlugView ()
{
	if (impl)
	{
		AuxWebViewState* state = (__bridge_transfer AuxWebViewState*)impl;
		(void)state;
		impl = nullptr;
	}
}

tresult PLUGIN_API WebViewPlugView::isPlatformTypeSupported (FIDString type)
{
	if (type && std::strcmp (type, kPlatformTypeNSView) == 0)
		return kResultTrue;
	return kResultFalse;
}

tresult PLUGIN_API WebViewPlugView::canResize ()
{
	return config.resizable ? kResultTrue : kResultFalse;
}

tresult PLUGIN_API WebViewPlugView::checkSizeConstraint (ViewRect* r)
{
	if (!r)
		return kResultFalse;
	if (!config.resizable)
	{
		*r = rect;
		return kResultTrue;
	}

	int32 w = r->getWidth ();
	int32 h = r->getHeight ();
	if (w < config.minWidth)
		w = config.minWidth;
	if (h < config.minHeight)
		h = config.minHeight;
	if (config.maxWidth > 0 && w > config.maxWidth)
		w = config.maxWidth;
	if (config.maxHeight > 0 && h > config.maxHeight)
		h = config.maxHeight;

	r->right = r->left + w;
	r->bottom = r->top + h;
	return kResultTrue;
}

tresult PLUGIN_API WebViewPlugView::onSize (ViewRect* newSize)
{
	if (newSize)
		rect = *newSize;
	syncWebViewSize ();
	return kResultTrue;
}

void WebViewPlugView::syncWebViewSize ()
{
	if (!impl)
		return;
	AuxWebViewState* state = (__bridge AuxWebViewState*)impl;
	const CGFloat w = rect.getWidth ();
	const CGFloat h = rect.getHeight ();
	void (^run)(void) = ^{
		if (w >= 1.0 && h >= 1.0)
		{
			state.lastNotifiedW = w;
			state.lastNotifiedH = h;
		}
		[state applyViewportForce:YES];
	};
	if ([NSThread isMainThread])
		run ();
	else
		dispatch_async (dispatch_get_main_queue (), run);
}

void WebViewPlugView::requestHostFillIfNeeded ()
{
	if (!config.resizable || !plugFrame || hostFillRequested || !impl)
		return;

	@autoreleasepool
	{
		AuxWebViewState* state = (__bridge AuxWebViewState*)impl;
		NSView* parent = state.webView.superview;
		NSWindow* win = state.webView.window ?: parent.window;
		if (!parent || !win.contentView)
			return;

		const CGFloat pw = parent.bounds.size.width;
		const CGFloat ph = parent.bounds.size.height;
		const CGFloat cw = win.contentView.bounds.size.width;
		const CGFloat ch = win.contentView.bounds.size.height;
		const CGFloat preferW = (CGFloat)config.width;
		const CGFloat preferH = (CGFloat)config.height;

		/* Grow to the larger of: restored window content, or this product's
		 * createView default. */
		const CGFloat wantW = std::max (std::max (cw, preferW), pw);
		const CGFloat wantH = std::max (std::max (ch, preferH), ph);

		if (!(wantW >= pw + 2.0 || wantH >= ph + 2.0))
			return;

		ViewRect wanted (0, 0, (int32)std::lround (wantW), (int32)std::lround (wantH));
		checkSizeConstraint (&wanted);
		hostFillRequested = true;
		plugFrame->resizeView (this, &wanted);
	}
}

void WebViewPlugView::evalJS (const std::string& js)
{
	if (!impl)
		return;
	AuxWebViewState* state = (__bridge AuxWebViewState*)impl;
	NSString* code = [NSString stringWithUTF8String:js.c_str ()];
	if (!code)
		return;
	void (^run)(void) = ^{
		[state.webView evaluateJavaScript:code completionHandler:nil];
	};
	if ([NSThread isMainThread])
		run ();
	else
		dispatch_async (dispatch_get_main_queue (), run);
}

void WebViewPlugView::evalBinaryBase64 (const std::string& base64)
{
	std::string js = "window.__auxbridge&&window.__auxbridge._recvBin(\"" + base64 + "\");";
	evalJS (js);
}

void WebViewPlugView::setOccluded (bool o)
{
	if (occluded == o)
		return;
	occluded = o;
	/* Gate the array-viz drain: hidden editors skip the CNXB batch so the DSP
	 * can short-circuit history/FFT. */
	if (bridge)
		bridge->setVizActive (!o);
}

void WebViewPlugView::attachedToParent ()
{
	@autoreleasepool
	{
		NSView* parent = (__bridge NSView*)systemWindow;
		if (!parent)
			return;

		NSString* logPath = [NSString stringWithUTF8String:config.debugLogPath.c_str ()];
		AuxDebugLogTo (logPath, @"=== auxVST native session ===", YES);
		AuxDebugLogTo (logPath,
		               [NSString stringWithFormat:@"[native] attachedToParent bridge=%@",
		                                         bridge ? @"YES" : @"NO"],
		               NO);

		AuxWebViewState* state = [[AuxWebViewState alloc] init];
		state.plugView = this;
		state.debugLogPath = logPath;

		WKWebViewConfiguration* wkConfig = [[WKWebViewConfiguration alloc] init];
		/* Shared process pool + data store: all editors share one WebContent
		 * process and one persistent store (localStorage prefs survive reloads). */
		wkConfig.processPool = AuxSharedProcessPool ();
		wkConfig.websiteDataStore = AuxSharedDataStore ();
		/* The UI has no media or fullscreen content. */
		wkConfig.preferences.elementFullscreenEnabled = NO;
		wkConfig.allowsAirPlayForMediaPlayback = NO;
		wkConfig.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
		state.scheme = [[AuxSchemeHandler alloc] init];
		state.scheme.rootSubdir =
		    [NSString stringWithUTF8String:config.rootSubdir.c_str ()];
		[wkConfig setURLSchemeHandler:state.scheme forURLScheme:kAuxURLScheme];

		WKUserContentController* ucc = [[WKUserContentController alloc] init];
		[ucc addScriptMessageHandler:state name:@"auxHost"];

		NSString* hardening =
		    @"var s=document.documentElement.style;"
		     "s.webkitUserSelect='none';s.webkitTouchCallout='none';"
		     "document.addEventListener('contextmenu',function(e){e.preventDefault();},false);"
		     "document.addEventListener('dragover',function(e){e.preventDefault();},false);"
		     "document.addEventListener('drop',function(e){e.preventDefault();},false);";
		WKUserScript* script =
		    [[WKUserScript alloc] initWithSource:hardening
		                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
		                        forMainFrameOnly:YES];
		[ucc addUserScript:script];

		if (AuxDebugEnabled ())
		{
			WKUserScript* dbgFlag =
			    [[WKUserScript alloc] initWithSource:@"window.__auxvstDebug=true;"
			                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
			                        forMainFrameOnly:YES];
			[ucc addUserScript:dbgFlag];
		}

		wkConfig.userContentController = ucc;

		NSRect frame = parent.bounds;
		if (frame.size.width < 1 || frame.size.height < 1)
			frame = NSMakeRect (0, 0, rect.getWidth (), rect.getHeight ());
		AuxWebView* webView = [[AuxWebView alloc] initWithFrame:frame configuration:wkConfig];
		webView.auxState = state;
		webView.navigationDelegate = state;
		webView.UIDelegate = state;
		webView.allowsMagnification = NO;
		webView.allowsBackForwardNavigationGestures = NO;
		webView.allowsLinkPreview = NO;
		/* Safari Web Inspector only under AUXVST_DEBUG. */
		if (@available (macOS 13.3, *))
			webView.inspectable = AuxDebugEnabled ();
		webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

		NSColor* theme = [NSColor colorWithSRGBRed:0.078 green:0.086 blue:0.110 alpha:1.0];
		parent.wantsLayer = YES;
		parent.layer.backgroundColor = theme.CGColor;
		@try { [webView setValue:@NO forKey:@"drawsBackground"]; } @catch (...) {}
		/* Keep visible during load: a hidden WKWebView often measures 0×0 on
		 * workspace restore and never recovers until a manual window resize. */
		webView.hidden = NO;

		state.webView = webView;
		state.lastNotifiedW = rect.getWidth ();
		state.lastNotifiedH = rect.getHeight ();
		[parent addSubview:webView];
		[state startObservingParentFrame:parent];

		/* Occlusion gating: stop the viz drain when the host window is hidden. */
		[[NSNotificationCenter defaultCenter] addObserver:state
		                                     selector:@selector(windowOcclusionDidChange:)
		                                         name:NSWindowDidChangeOcclusionStateNotification
		                                       object:nil];
		[state updateOcclusion];

		impl = (__bridge_retained void*)state;

		if (bridge)
			bridge->attachTransport (this);

		NSURL* url = nil;
		const char* devUrl = getenv ("AUXVST_DEV_URL");
		if (devUrl && devUrl[0] != '\0')
			url = [NSURL URLWithString:[NSString stringWithUTF8String:devUrl]];
		if (!url)
			url = [NSURL URLWithString:[NSString stringWithUTF8String:config.indexUrl.c_str ()]];
		[webView loadRequest:[NSURLRequest requestWithURL:url]];

		/* Immediate sync + ask Nuendo to fill a restored oversized window. */
		[state notifyViewportWithFollowUps:YES];
	}
}

void WebViewPlugView::removedFromParent ()
{
	hostFillRequested = false;
	if (bridge)
		bridge->detachTransport (this);

	if (!impl)
		return;

	@autoreleasepool
	{
		AuxWebViewState* state = (__bridge_transfer AuxWebViewState*)impl;
		impl = nullptr;

		if ([state.webView isKindOfClass:[AuxWebView class]])
			[(AuxWebView*)state.webView auxUnpinWindow];

		[[NSNotificationCenter defaultCenter] removeObserver:state
		                                                name:NSWindowDidChangeOcclusionStateNotification
		                                              object:nil];
		[state stopObservingParentFrame];
		[state.webView.configuration.userContentController
		    removeScriptMessageHandlerForName:@"auxHost"];
		[state.webView stopLoading];
		state.webView.navigationDelegate = nil;
		state.webView.UIDelegate = nil;
		[state.webView removeFromSuperview];
		state.webView = nil;
	}
}

//------------------------------------------------------------------------
} // namespace Vst
} // namespace Steinberg
