//------------------------------------------------------------------------
// auxVST common — native WebView IPlugView (product-agnostic)
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//------------------------------------------------------------------------

#pragma once

#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
#include "param_bridge.h"

#include <functional>
#include <string>

namespace Steinberg {
namespace Vst {

//------------------------------------------------------------------------
struct WebViewPlugViewConfig
{
	int32 width {480};
	int32 height {340};
	/** Whether the host may resize the editor window. */
	bool resizable {true};
	/** Lower bounds enforced in checkSizeConstraint (px). */
	int32 minWidth {320};
	int32 minHeight {240};
	/** Upper bounds enforced in checkSizeConstraint (px); <=0 means unbounded. */
	int32 maxWidth {0};
	int32 maxHeight {0};
	/** Bundle Resources subdirectory served as auxvst://ui/ (default "webui"). */
	std::string rootSubdir {"webui"};
	/** Full URL loaded after attach (custom scheme or http for AUXVST_DEV_URL override). */
	std::string indexUrl {"auxvst://ui/index.html"};
	/** Path for AUXVST_DEBUG file log. */
	std::string debugLogPath {"/tmp/auxvst-debug.log"};
};

//------------------------------------------------------------------------
class WebViewPlugView : public CPluginView, public IWebViewTransport
{
public:
	WebViewPlugView (EditController* controller, ParamBridge* bridge,
	                 WebViewPlugViewConfig config = {});
	~WebViewPlugView () SMTG_OVERRIDE;

	tresult PLUGIN_API isPlatformTypeSupported (FIDString type) SMTG_OVERRIDE;
	tresult PLUGIN_API canResize () SMTG_OVERRIDE;
	tresult PLUGIN_API checkSizeConstraint (ViewRect* rect) SMTG_OVERRIDE;
	tresult PLUGIN_API onSize (ViewRect* newSize) SMTG_OVERRIDE;

	void evalJS (const std::string& js) SMTG_OVERRIDE;
	void evalBinaryBase64 (const std::string& base64) SMTG_OVERRIDE;
	/** If the host window is larger than the plug-in parent, ask it to resize. */
	void requestHostFillIfNeeded ();
	/** Occlusion/hidden gating: stop the viz drain when the window is hidden. */
	void setOccluded (bool occluded);

	/** Product hook: {t:…} script messages are re-serialized to JSON and
	    delivered here (main thread). */
	void setRawMessageHandler (std::function<void (const std::string& json)> handler)
	{
		rawMessageHandler = std::move (handler);
	}
	void forwardRawMessage (const std::string& json)
	{
		if (rawMessageHandler)
			rawMessageHandler (json);
	}
	/** Product hook: page navigation finished (calfNXT's page-ready signal). */
	void setNavigationFinishedHandler (std::function<void ()> handler)
	{
		navigationFinishedHandler = std::move (handler);
	}
	void navigationFinished ()
	{
		if (navigationFinishedHandler)
			navigationFinishedHandler ();
	}

protected:
	void attachedToParent () SMTG_OVERRIDE;
	void removedFromParent () SMTG_OVERRIDE;

private:
	void syncWebViewSize ();

	EditController* controller {nullptr};
	ParamBridge* bridge {nullptr};
	WebViewPlugViewConfig config;
	void* impl {nullptr};
	bool hostFillRequested {false};
	bool occluded {false};
	std::function<void (const std::string&)> rawMessageHandler;
	std::function<void ()> navigationFinishedHandler;
};//------------------------------------------------------------------------
} // namespace Vst
} // namespace Steinberg
