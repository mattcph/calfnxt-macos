//------------------------------------------------------------------------
// auxVST common — ParamBridge implementation
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//------------------------------------------------------------------------

#include "param_bridge.h"

#include "public.sdk/source/vst/vsteditcontroller.h"

#include <cstdio>

namespace Steinberg {
namespace Vst {

namespace {

void appendNum (std::string& out, double v)
{
	// calfNXT transports plain values (dB/Hz) over this frame, so %.6g is not
	// enough — %.17g round-trips doubles. std::to_chars for double needs
	// macOS 13.3; the deployment target is 13.0. Patch locale commas.
	char buf[40];
	std::snprintf (buf, sizeof (buf), "%.17g", v);
	for (char* p = buf; *p; ++p)
		if (*p == ',')
			*p = '.';
	out.append (buf);
}

} // namespace

//------------------------------------------------------------------------
ParamBridge::ParamBridge (EditController* c, std::vector<ParamID> cat)
: controller (c), catalog (std::move (cat))
{
	// C++17 std::atomic default-init does not zero the value. Allocated once;
	// the catalog does not grow, and atomics are not movable.
	current = std::make_unique<std::atomic<double>[]> (catalog.size ());
	dirty = std::make_unique<std::atomic<bool>[]> (catalog.size ());
	for (size_t i = 0; i < catalog.size (); ++i)
	{
		current[i].store (0.0, std::memory_order_relaxed);
		dirty[i].store (false, std::memory_order_relaxed);
	}
	idToIndex.reserve (catalog.size ());
	for (size_t i = 0; i < catalog.size (); ++i)
		idToIndex.emplace (catalog[i], static_cast<int> (i));
	jsScratch.reserve (512);
	b64Scratch.reserve (256);
}

//------------------------------------------------------------------------
ParamBridge::~ParamBridge ()
{
	releaseTimer ();
}

//------------------------------------------------------------------------
int ParamBridge::indexOf (ParamID id) const
{
	auto it = idToIndex.find (id);
	if (it == idToIndex.end ())
		return -1;
	return it->second;
}

//------------------------------------------------------------------------
bool ParamBridge::anyDirty () const
{
	for (size_t i = 0; i < catalog.size (); ++i)
		if (dirty[i].load (std::memory_order_acquire))
			return true;
	// Products with an array telemetry seam (calfNXT) produce viz frames
	// continuously while the editor is visible; the drain self-throttles to
	// vizHz and leaves outB64 empty when the DSP published nothing, so waking
	// the timer for it is cheap. Occlusion (vizActive=false) still sleeps.
	if (vizDrain && vizActive)
		return true;
	return false;
}

//------------------------------------------------------------------------
void ParamBridge::attachTransport (IWebViewTransport* t)
{
	transport = t;
	jsReady = false;
}

//------------------------------------------------------------------------
void ParamBridge::detachTransport (IWebViewTransport* t)
{
	if (transport == t)
	{
		releaseTimer ();
		transport = nullptr;
		jsReady = false;
	}
}

//------------------------------------------------------------------------
void ParamBridge::ensureTimer ()
{
	if (!transport || !jsReady)
		return;
	if (!timer)
		timer = Timer::create (this, 16); // ~60 Hz coalesce while editor ready
}

//------------------------------------------------------------------------
void ParamBridge::releaseTimer ()
{
	if (timer)
	{
		timer->stop ();
		timer->release ();
		timer = nullptr;
	}
}

//------------------------------------------------------------------------
void ParamBridge::onReady ()
{
	jsReady = true;
	ensureTimer ();
}

//------------------------------------------------------------------------
void ParamBridge::onParamChanged (ParamID id, double value)
{
	// Audio thread (process → setNormalized → update) and the main thread both
	// arrive here. Lock-free stores only — the timer is main-thread-owned and
	// already running once the editor handshake completes.
	int idx = indexOf (id);
	if (idx < 0)
		return;
	const auto i = static_cast<size_t> (idx);
	current[i].store (value, std::memory_order_relaxed);
	dirty[i].store (true, std::memory_order_release);
}

//------------------------------------------------------------------------
void ParamBridge::onTimer (Timer*)
{
	if (anyDirty ())
		flush ();
}

//------------------------------------------------------------------------
void ParamBridge::flush ()
{
	if (!transport || !jsReady)
		return;

	bool anyParam = false;
	for (size_t i = 0; i < catalog.size (); ++i)
	{
		if (dirty[i].load (std::memory_order_acquire))
		{
			anyParam = true;
			break;
		}
	}
	if (anyParam)
	{
		jsScratch.clear ();
		jsScratch += "window.__auxbridge&&window.__auxbridge._recv({\"type\":\"params\",\"values\":{";
		bool first = true;
		for (size_t i = 0; i < catalog.size (); ++i)
		{
			// Clear before reading. exchange is one RMW: a writer that stores a
			// newer value and sets dirty after this point is not lost. Either
			// this load sees that value, or dirty stays true and the next tick
			// sends it (a duplicate at worst).
			if (!dirty[i].exchange (false, std::memory_order_acq_rel))
				continue;
			const double value = current[i].load (std::memory_order_relaxed);
			if (!first)
				jsScratch += ',';
			first = false;
			jsScratch += '"';
			jsScratch += std::to_string (catalog[i]);
			jsScratch += "\":";
			appendNum (jsScratch, value);
		}
		jsScratch += "}});";
		if (!first)
			transport->evalJS (jsScratch);
	}

	// Array telemetry seam: one CNXB batch per tick, after params. The product
	// supplies the drain (it owns the per-stream seqlock buffers); we only
	// deliver the base64 blob through the transport. Skipped while occluded.
	if (vizDrain && vizActive)
	{
		b64Scratch.clear ();
		vizDrain (b64Scratch);
		if (!b64Scratch.empty ())
			transport->evalBinaryBase64 (b64Scratch);
	}
}

//------------------------------------------------------------------------
} // namespace Vst
} // namespace Steinberg
