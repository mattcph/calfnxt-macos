//------------------------------------------------------------------------
// auxVST common — C++ ParamBridge (control tier + array telemetry seam)
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// Product-agnostic: the catalog is supplied by the plug-in controller.
// Speaks parameters only (id + value + dirty coalescing).
//
// Wake-on-dirty: onParamChanged marks slots dirty. Once the editor handshake
// completes, a long-lived ~16 ms main-thread timer drains coalesced updates
// into the WebView. Steinberg's Timer has no restart API, so the timer stays
// alive while the editor is ready and no-ops when nothing is dirty (avoids
// create/destroy churn).
//------------------------------------------------------------------------

#pragma once

#include "pluginterfaces/vst/vsttypes.h"
#include "base/source/timer.h"

#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

namespace Steinberg {
namespace Vst {

class EditController;

//------------------------------------------------------------------------
class IWebViewTransport
{
public:
	virtual ~IWebViewTransport () {}
	virtual void evalJS (const std::string& js) = 0;
	virtual void evalBinaryBase64 (const std::string& /*base64*/) {}
};

//------------------------------------------------------------------------
class ParamBridge : public Steinberg::ITimerCallback
{
public:
	ParamBridge (EditController* controller, std::vector<ParamID> catalog);
	~ParamBridge () SMTG_OVERRIDE;

	void attachTransport (IWebViewTransport* transport);
	void detachTransport (IWebViewTransport* transport);

	void onReady ();
	void onParamChanged (ParamID id, double value);

	void onTimer (Steinberg::Timer* timer) SMTG_OVERRIDE;

	/**
	 * Array telemetry seam. The product supplies a drain that fills `outB64`
	 * with one base64 CNXB batch (viz_bin.h) built from its per-stream seqlock
	 * buffers; it runs once per ~16 ms tick after params. Leave `outB64`
	 * empty to skip. calfNXT sends ALL viz over this seam (levels, GR, curves,
	 * …).
	 */
	void setVizDrain (std::function<void (std::string& outB64)> drain)
	{
		vizDrain = std::move (drain);
	}

	/** Occlusion/hidden gate: when false, the viz drain is skipped each tick. */
	void setVizActive (bool active) { vizActive = active; }

private:
	void ensureTimer ();
	void releaseTimer ();
	void flush ();
	bool anyDirty () const;
	int indexOf (ParamID id) const;

	EditController* controller {nullptr};
	IWebViewTransport* transport {nullptr};
	Steinberg::Timer* timer {nullptr};
	bool jsReady {false};

	std::vector<ParamID> catalog;
	std::unordered_map<ParamID, int> idToIndex;
	std::vector<double> current; // parallel to catalog (not ParamID-indexed)
	std::vector<bool> dirty;

	std::function<void (std::string& outB64)> vizDrain;
	bool vizActive {true};

	std::string jsScratch;
	std::string b64Scratch;
};

//------------------------------------------------------------------------
} // namespace Vst
} // namespace Steinberg
