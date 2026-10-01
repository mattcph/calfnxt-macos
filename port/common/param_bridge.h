//------------------------------------------------------------------------
// auxVST common — C++ ParamBridge (control tier + array telemetry seam)
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// Product-agnostic: the catalog is supplied by the plug-in controller.
// Speaks parameters only (id + value + dirty coalescing).
//
// Threading contract:
//   * onParamChanged may run on the audio thread. calfNXT applies host
//     automation inside process() via Parameter::setNormalized, and the VST3
//     UpdateHandler delivers IDependent::update on that same thread. The
//     audio thread may only do lock-free stores into current/dirty.
//   * Host→UI is push-only. update() snapshots toPlain(getNormalized()) on
//     the thread that called setNormalized and stores that plain double.
//     There is no per-tick poll of the controller. A write reaches the UI
//     only when it goes through setNormalized, which calls changed() when
//     the clamped value differs. Automation is seen because
//     EffectBase::syncParamPlains calls setNormalized from process().
//     Codegen uses RangeParameter, whose toPlain is linear; the DSP's later
//     readParamPlains float copy is a separate conversion and is not reused.
//   * The timer, transport, and jsReady are main-thread-only. The ~16 ms
//     timer is created when the editor handshake completes and lives until
//     detach. Steinberg's Timer has no restart API, so it stays alive while
//     the editor is ready. onTimer calls flush when a parameter is dirty or,
//     while the editor is visible, when a viz drain is installed.
//   * anyDirty() scans dirty[] before the viz gate. A visible editor still
//     walks the catalog when no parameter is dirty; flush() then walks it
//     again before the exchange loop that publishes current[].
//------------------------------------------------------------------------

#pragma once

#include "pluginterfaces/vst/vsttypes.h"
#include "base/source/timer.h"

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

static_assert (std::atomic<double>::is_always_lock_free,
               "ParamBridge coalescing must stay lock-free on the audio thread");
static_assert (std::atomic<bool>::is_always_lock_free,
               "ParamBridge coalescing must stay lock-free on the audio thread");

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
	// Parallel to catalog (not ParamID-indexed). Written from the audio thread
	// and drained on the main thread; both are lock-free. A raw array, not
	// std::vector: atomics are not movable, so vector reallocation cannot
	// compile, and the catalog never grows after construction.
	std::unique_ptr<std::atomic<double>[]> current;
	std::unique_ptr<std::atomic<bool>[]> dirty;

	std::function<void (std::string& outB64)> vizDrain;
	bool vizActive {true};

	std::string jsScratch;
	std::string b64Scratch;
};

//------------------------------------------------------------------------
} // namespace Vst
} // namespace Steinberg
