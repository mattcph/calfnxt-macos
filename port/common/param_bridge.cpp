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
	current.assign (catalog.size (), 0.0);
	dirty.assign (catalog.size (), false);
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
	for (bool d : dirty)
		if (d)
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
	int idx = indexOf (id);
	if (idx < 0)
		return;
	current[static_cast<size_t> (idx)] = value;
	dirty[static_cast<size_t> (idx)] = true;
	ensureTimer ();
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
	for (bool d : dirty)
	{
		if (d)
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
			if (!dirty[i])
				continue;
			dirty[i] = false;
			if (!first)
				jsScratch += ',';
			first = false;
			jsScratch += '"';
			jsScratch += std::to_string (catalog[i]);
			jsScratch += "\":";
			appendNum (jsScratch, current[i]);
		}
		jsScratch += "}});";
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
