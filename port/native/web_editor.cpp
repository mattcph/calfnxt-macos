// calfNXT macOS — WebEditor implementation (in-process WKWebView).
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.

#include "web_editor.h"

#include "base64.h"
#include "macos_folder_panel.h"
#include "webview_plugview.h"
#include "viz_bin.h"
#include "viz_hz.h"

#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <limits>

namespace calfNXT {
namespace Ui {

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

// ---- Minimal JSON field helpers ----

bool jsonHasType(const char* s, const char* type)
{
  if (!s || !type)
    return false;
  char needle[48];
  std::snprintf(needle, sizeof needle, "\"t\":\"%s\"", type);
  if (std::strstr(s, needle))
    return true;
  std::snprintf(needle, sizeof needle, "\"t\": \"%s\"", type);
  return std::strstr(s, needle) != nullptr;
}

bool jsonNumberAfterKey(const char* s, const char* key, double& out)
{
  const char* p = s ? std::strstr(s, key) : nullptr;
  if (!p)
    return false;
  p = std::strchr(p, ':');
  if (!p)
    return false;
  ++p;
  while (*p == ' ' || *p == '\t')
    ++p;
  char* end = nullptr;
  out = std::strtod(p, &end);
  return end != p;
}

bool jsonStringAfterKey(const char* s, const char* key, char* out, size_t outSize)
{
  if (!s || !key || !out || outSize == 0)
    return false;
  const char* p = std::strstr(s, key);
  if (!p)
    return false;
  p = std::strchr(p, ':');
  if (!p)
    return false;
  ++p;
  while (*p == ' ' || *p == '\t')
    ++p;
  if (*p != '"')
    return false;
  ++p;
  size_t n = 0;
  while (*p && *p != '"' && n + 1 < outSize)
  {
    if (*p == '\\' && p[1])
      ++p; // keep the escaped char verbatim (paths are ASCII in practice)
    out[n++] = *p++;
  }
  out[n] = '\0';
  return true;
}

/** Non-finite → nanFill, then clamp to [lo, hi]. Pass ±max() to skip clamping. */
void sanitizeInPlace(float* v, int n, float lo, float hi, float nanFill)
{
  for (int i = 0; i < n; ++i)
  {
    if (!std::isfinite(v[i]))
      v[i] = nanFill;
    v[i] = std::clamp(v[i], lo, hi);
  }
}

constexpr float kNoClamp = std::numeric_limits<float>::max();

} // namespace

//------------------------------------------------------------------------
WebEditor::WebEditor(EditController* controller, ViewRect size, const char* entryHtml)
: CPluginView(&size)
, controller_(controller)
, designWidth_(size.getWidth())
, designHeight_(size.getHeight())
{
  std::snprintf(entryHtml_, sizeof entryHtml_, "%s", entryHtml ? entryHtml : "index.html");
}

WebEditor::~WebEditor()
{
  detachParamListeners();
  if (plugView_)
  {
    auto* view = static_cast<WebViewPlugView*>(plugView_);
    view->release();
    plugView_ = nullptr;
  }
  delete bridge_;
  bridge_ = nullptr;
}

//------------------------------------------------------------------------
tresult PLUGIN_API WebEditor::isPlatformTypeSupported(FIDString type)
{
  return std::strcmp(type, kPlatformTypeNSView) == 0 ? kResultTrue : kResultFalse;
}

tresult PLUGIN_API WebEditor::canResize()
{
  return kResultTrue;
}

tresult PLUGIN_API WebEditor::checkSizeConstraint(ViewRect* rect)
{
  if (!rect)
    return kResultFalse;
  if (plugView_)
    return static_cast<WebViewPlugView*>(plugView_)->checkSizeConstraint(rect);
  // Not attached yet: floor at design size, unbounded growth.
  if (rect->getWidth() < designWidth_)
    rect->right = rect->left + designWidth_;
  if (rect->getHeight() < designHeight_)
    rect->bottom = rect->top + designHeight_;
  return kResultTrue;
}

tresult PLUGIN_API WebEditor::onSize(ViewRect* newSize)
{
  if (plugView_)
    static_cast<WebViewPlugView*>(plugView_)->onSize(newSize);
  return CPluginView::onSize(newSize);
}

//------------------------------------------------------------------------
tresult PLUGIN_API WebEditor::attached(void* parent, FIDString type)
{
  if (!parent || std::strcmp(type, kPlatformTypeNSView) != 0)
    return kResultFalse;

  if (CPluginView::attached(parent, type) != kResultOk)
    return kResultFalse;

  // Param catalog straight from the controller (codegen-registered).
  std::vector<ParamID> catalog;
  if (controller_)
  {
    const int32 n = controller_->getParameterCount();
    catalog.reserve(static_cast<size_t>(n));
    for (int32 i = 0; i < n; ++i)
      if (auto* p = controller_->getParameterObject(static_cast<ParamID>(i)))
        catalog.push_back(p->getInfo().id);
  }

  bridge_ = new ParamBridge(controller_, std::move(catalog));
  // Array telemetry seam: all calfNXT viz channels drain into one CNXB batch
  // per bridge tick (~16 ms; self-throttled to vizHz inside drainViz).
  bridge_->setVizDrain([this](std::string& outB64) { drainViz(outB64); });

  WebViewPlugViewConfig cfg;
  cfg.width = designWidth_;
  cfg.height = designHeight_;
  // Host may resize the editor window; never smaller than the design size.
  cfg.resizable = true;
  cfg.minWidth = designWidth_;
  cfg.minHeight = designHeight_;
  cfg.rootSubdir = "webui";
  cfg.indexUrl = "auxvst://ui/" + std::string(entryHtml_);
  cfg.debugLogPath = "/tmp/calfnxt-ui.log";

  auto* view = new WebViewPlugView(controller_, bridge_, cfg);
  plugView_ = view;
  // calfNXT {t:…} messages arrive as JSON via the raw-message hook; page
  // load completion is the port's ready signal (upstream: {t:"_ready"}).
  view->setRawMessageHandler([this](const std::string& json) { onScriptMessage(json.c_str()); });
  view->setNavigationFinishedHandler([this]() { onPageReady(); });
  view->attached(parent, type);

  attachParamListeners();
  editorVisible_ = true;
  if (vizSource_)
    vizSource_->setVizConsumerActive(true);
  return kResultOk;
}

tresult PLUGIN_API WebEditor::removed()
{
  editorVisible_ = false;
  if (vizSource_)
    vizSource_->setVizConsumerActive(false);
  detachParamListeners();
  if (plugView_)
  {
    auto* view = static_cast<WebViewPlugView*>(plugView_);
    view->removed();
    view->release();
    plugView_ = nullptr;
  }
  return CPluginView::removed();
}

//------------------------------------------------------------------------
void WebEditor::attachParamListeners()
{
  if (listeningParams_ || !controller_)
    return;
  const int32 n = controller_->getParameterCount();
  for (int32 i = 0; i < n; ++i)
    if (auto* p = controller_->getParameterObject(static_cast<ParamID>(i)))
      p->addDependent(this);
  listeningParams_ = true;
}

void WebEditor::detachParamListeners()
{
  if (!listeningParams_ || !controller_)
    return;
  const int32 n = controller_->getParameterCount();
  for (int32 i = 0; i < n; ++i)
    if (auto* p = controller_->getParameterObject(static_cast<ParamID>(i)))
      p->removeDependent(this);
  listeningParams_ = false;
}

void PLUGIN_API WebEditor::update(FUnknown* changedUnknown, int32 message)
{
  if (suppressParamPush_ || message != IDependent::kChanged || !changedUnknown)
    return;
  auto* param = FCast<Parameter>(changedUnknown);
  if (!param)
    return;
  pushParamPlain(param->getInfo().id, param->toPlain(param->getNormalized()));
}

//------------------------------------------------------------------------
void WebEditor::pushParamPlain(ParamID id, double plain)
{
  if (!bridge_ || !controller_)
    return;
  // The bridge is a value-agnostic coalescing transport; calfNXT carries
  // PLAIN values (dB/Hz) so the UI dispatch stays upstream-identical.
  bridge_->onParamChanged(id, plain);
}

void WebEditor::pushAllParams()
{
  if (!controller_)
    return;
  const int32 n = controller_->getParameterCount();
  for (int32 i = 0; i < n; ++i)
    if (auto* p = controller_->getParameterObject(static_cast<ParamID>(i)))
      pushParamPlain(p->getInfo().id, p->toPlain(p->getNormalized()));
}

int WebEditor::queryBusChannelCount(BusDirection dir, int busIndex) const
{
  if (!controller_)
    return 0;
  // The component exposes bus info via IComponent.
  IPtr<IComponent> comp;
  {
    FUnknown* unknown = nullptr;
    if (controller_->queryInterface(IComponent::iid, reinterpret_cast<void**>(&unknown)) == kResultOk)
      comp = shared(reinterpret_cast<IComponent*>(unknown));
  }
  if (!comp)
    return 0;
  BusInfo info {};
  if (comp->getBusInfo(kAudio, dir, busIndex, info) == kResultOk)
    return info.channelCount;
  return 0;
}

int WebEditor::queryIoChannelCount() const
{
  return queryBusChannelCount(kOutput, 0);
}

void WebEditor::pushIoChannels()
{
  const int inCh = queryBusChannelCount(kInput, 0);
  const int outCh = queryIoChannelCount();
  if (outCh <= 0)
    return;
  char js[96];
  std::snprintf(js, sizeof js,
                "window.__calfnxtOnHost&&window.__calfnxtOnHost({\"t\":\"io\",\"ch\":%d,\"in\":%d,\"out\":%d});",
                outCh, inCh > 0 ? inCh : outCh, outCh);
  evalJs(js);
}

//------------------------------------------------------------------------
void WebEditor::onPageReady()
{
  pageReady_ = true;
  // Start the bridge tick (params coalesce + viz drain); initial values
  // arrive as plain {t:"param"} via pushAllParams below.
  if (bridge_)
    bridge_->onReady();
  pushAllParams();
  pushIoChannels();
}

bool WebEditor::onWebMessage(const char* json)
{
  if (!json)
    return false;

  if (!controller_)
    return false;

  if (jsonHasType(json, "sync"))
  {
    pushAllParams();
    pushIoChannels();
    return true;
  }

  if (jsonHasType(json, "vizcfg"))
  {
    if (!vizSource_)
      return true;
    double binsf = 0.0;
    char id[64];
    if (!jsonStringAfterKey(json, "\"id\"", id, sizeof id)
        || !jsonNumberAfterKey(json, "\"bins\"", binsf))
      return false;
    vizSource_->configureVizBins(id, static_cast<int>(std::lround(binsf)));
    return true;
  }

  if (jsonHasType(json, "vizhz"))
  {
    double v = 0.0;
    if (jsonNumberAfterKey(json, "\"hz\"", v))
    {
      const int hz = static_cast<int>(std::lround(v));
      if (hz >= 5 && hz <= 60)
        vizHzRuntime().hz.store(hz, std::memory_order_relaxed);
    }
    return true;
  }

  if (jsonHasType(json, "ir"))
  {
    // {t:"ir",cmd:"browse"} needs a native folder chooser: the port runs
    // NSOpenPanel in-process and injects the chosen root back as
    // {t:"ir",cmd:"root",path:…}.
    char irCmd[32] {};
    if (jsonStringAfterKey(json, "\"cmd\"", irCmd, sizeof irCmd)
        && std::strcmp(irCmd, "browse") == 0)
    {
      addRef(); // keep the editor alive while the panel is up
      showFolderPanelAsync([this](const std::string& path) {
        if (!path.empty() && vizSource_)
        {
          std::string msg = "{\"t\":\"ir\",\"cmd\":\"root\",\"path\":\"";
          for (const char c : path)
          {
            if (c == '\\' || c == '"')
              msg += '\\';
            msg += c;
          }
          msg += "\"}";
          vizSource_->handleIrCommand(msg.c_str());
        }
        release();
      });
      return true;
    }
    if (vizSource_)
      vizSource_->handleIrCommand(json);
    return true;
  }

  if (jsonHasType(json, "midi"))
  {
    if (vizSource_)
      vizSource_->handleMidiCommand(json);
    return true;
  }

  double idf = 0.0;
  const ParamID id = jsonNumberAfterKey(json, "\"id\"", idf) ? static_cast<ParamID>(idf) : 0;

  if (jsonHasType(json, "begin"))
  {
    controller_->beginEdit(id);
    return true;
  }
  if (jsonHasType(json, "end"))
  {
    controller_->endEdit(id);
    return true;
  }
  if (jsonHasType(json, "set"))
  {
    double plain = 0.0;
    if (!jsonNumberAfterKey(json, "\"v\"", plain))
      return false;
    if (auto* p = controller_->getParameterObject(id))
    {
      const double norm = p->toNormalized(plain);
      suppressParamPush_ = true;
      controller_->setParamNormalized(id, norm);
      controller_->performEdit(id, norm);
      suppressParamPush_ = false;
    }
    return true;
  }

  return false;
}

//------------------------------------------------------------------------
void WebEditor::onScriptMessage(const char* json)
{
  onWebMessage(json);
}

//------------------------------------------------------------------------
void WebEditor::evalJs(const char* js)
{
  if (!js || !plugView_)
    return;
  static_cast<WebViewPlugView*>(plugView_)->evalJS(js);
}

void WebEditor::evalJS(const std::string& js)
{
  evalJs(js.c_str());
}

void WebEditor::evalBinaryBase64(const std::string& base64)
{
  if (!plugView_)
    return;
  static_cast<WebViewPlugView*>(plugView_)->evalBinaryBase64(base64);
}

//------------------------------------------------------------------------
void WebEditor::flushVizArray(const char* streamId, const char* kind, float* values, int n)
{
  if (!streamId || !kind || n < 0)
    return;
  if (!vizBatchOpen_)
  {
    vizBatchFrames_.clear();
    vizBatchCount_ = 0;
    vizBatchOpen_ = true;
  }
  if (VizBin::encode(vizBatchFrames_, streamId, kind, values, n))
    ++vizBatchCount_;
}

// Drains every IVizSource channel into one CNXB batch (base64 into outB64).
// All calfNXT viz rides this seam — levels, GR, dynamics point, corr, gonio,
// band gains/io, tempo, shape, cutoff, LFOs, envelope, spectrum, response,
// comb, pitch, MIDI override, IR wave. Channel set, clamps and layouts mirror
// the upstream flushViz (calfnxt/common/ui/web_editor.cpp); keep in sync at
// upstream-sync time (tools/check-seam.sh covers the kind list).
void WebEditor::drainViz(std::string& outB64)
{
  outB64.clear();
  if (!vizSource_ || !pageReady_ || !editorVisible_)
    return;

  using clock = std::chrono::steady_clock;
  const auto now = clock::now();
  int hz = vizHzRuntime().hz.load(std::memory_order_relaxed);
  if (hz < 5)
    hz = 5;
  else if (hz > 60)
    hz = 60;
  const auto minGap = std::chrono::milliseconds(1000 / hz);

  // Envelope tier (envelope / pitch / midi) on its own clock.
  if (lastEnvVizFlush_.time_since_epoch().count() == 0
      || now - lastEnvVizFlush_ >= minGap)
  {
    lastEnvVizFlush_ = now;
    constexpr int kMaxEnvFloats = 6 * (512 * 3) + 1;
    float envBuf[kMaxEnvFloats];
    const int nEnv = vizSource_->takeEnvelopeDisplay(envBuf, kMaxEnvFloats);
    if (nEnv > 0)
    {
      sanitizeInPlace(envBuf, nEnv, -kNoClamp, kNoClamp, 0.f);
      flushVizArray(vizSource_->vizEnvelopeId(), "envelope", envBuf, nEnv);
    }

    if (const char* pitchId = vizSource_->vizPitchId())
    {
      const int nPitch = vizSource_->takePitchHistory(envBuf, kMaxEnvFloats);
      if (nPitch > 0)
      {
        sanitizeInPlace(envBuf, nPitch, -kNoClamp, kNoClamp, 0.f);
        flushVizArray(pitchId, "pitch", envBuf, nPitch);
      }
    }

    if (const char* midiId = vizSource_->vizMidiId())
    {
      float midi[2];
      if (vizSource_->takeMidiOverride(midi, 2) == 2)
        flushVizArray(midiId, "midi", midi, 2);
    }
  }

  // Main tier: throttled to vizHz.
  if (lastVizFlush_.time_since_epoch().count() == 0 || now - lastVizFlush_ >= minGap)
  {
    lastVizFlush_ = now;

    if (const char* tempoId = vizSource_->vizTempoId())
    {
      float tempo[2] {};
      if (vizSource_->takeHostTempo(tempo, 2) == 2)
        flushVizArray(tempoId, "tempo", tempo, 2);
    }

    constexpr int kMaxCh = 8;
    constexpr float kMinDb = -96.f;
    constexpr float kMaxDb = 12.f;

    float inLevels[kMaxCh];
    const int nIn = vizSource_->takeInputLevelsDb(inLevels, kMaxCh);
    if (nIn > 0)
    {
      sanitizeInPlace(inLevels, nIn, kMinDb, kMaxDb, kMinDb);
      flushVizArray(vizSource_->vizInputLevelsId(), "levels", inLevels, nIn);
    }

    float outLevels[kMaxCh];
    const int nOut = vizSource_->takeOutputLevelsDb(outLevels, kMaxCh);
    if (nOut > 0)
    {
      sanitizeInPlace(outLevels, nOut, kMinDb, kMaxDb, kMinDb);
      flushVizArray(vizSource_->vizOutputLevelsId(), "levels", outLevels, nOut);
    }

    constexpr int kMaxBands = 32;
    constexpr float kGainMin = -24.f;
    constexpr float kGainMax = 24.f;
    float bandGains[kMaxBands];
    const int nGains = vizSource_->takeBandGainsDb(bandGains, kMaxBands);
    if (nGains > 0)
    {
      sanitizeInPlace(bandGains, nGains, kGainMin, kGainMax, 0.f);
      flushVizArray(vizSource_->vizBandGainsId(), "gains", bandGains, nGains);
    }

    float corr = 0.f;
    if (vizSource_->takeCorrelation(&corr, 1) > 0)
    {
      sanitizeInPlace(&corr, 1, -1.f, 1.f, 0.f);
      flushVizArray(vizSource_->vizStereoFieldId(), "corr", &corr, 1);
    }

    constexpr int kMaxGonio = 256;
    float gonio[kMaxGonio];
    const int nGonio = vizSource_->takeGonio(gonio, kMaxGonio);
    if (nGonio >= 0)
    {
      sanitizeInPlace(gonio, nGonio, -2.f, 2.f, 0.f);
      flushVizArray(vizSource_->vizStereoFieldId(), "gonio", gonio, nGonio);
    }

    float grDb[32] {};
    const int nGr = vizSource_->takeGainReductionDb(grDb, 32);
    if (nGr > 0)
    {
      sanitizeInPlace(grDb, nGr, -60.f, 0.f, 0.f);
      flushVizArray(vizSource_->vizDynamicsId(), "gr", grDb, nGr);
    }

    if (const char* bandIoId = vizSource_->vizBandIoLevelsId())
    {
      float bandIo[64] {};
      const int nIo = vizSource_->takeBandIoLevelsDb(bandIo, 64);
      if (nIo > 0)
      {
        sanitizeInPlace(bandIo, nIo, -96.f, 12.f, -96.f);
        flushVizArray(bandIoId, "bandio", bandIo, nIo);
      }
    }

    float point[32] {};
    const int nPt = vizSource_->takeDynamicsPoint(point, 32);
    if (nPt >= 2)
    {
      sanitizeInPlace(point, nPt, -96.f, 24.f, -96.f);
      flushVizArray(vizSource_->vizDynamicsId(), "point", point, nPt);
    }

    if (const char* shapeId = vizSource_->vizShapeId())
    {
      // [zone, bin…] — see IVizSource::takeShapePoint
      float shape[65] {};
      const int nShape = vizSource_->takeShapePoint(shape, 65);
      if (nShape >= 2)
      {
        sanitizeInPlace(shape, nShape, 0.f, 1.f, 0.f);
        flushVizArray(shapeId, "shape", shape, nShape);
      }
    }

    if (const char* spectrumId = vizSource_->vizSpectrumId())
    {
      // Layout: bins, hold, avg[N], max[N], L[N], R[N] — max 2+4*256
      constexpr int kMaxSpectrum = 2 + 4 * 256;
      float spectrum[kMaxSpectrum];
      const int nSpec = vizSource_->takeSpectrum(spectrum, kMaxSpectrum);
      if (nSpec >= 2)
      {
        spectrum[0] = std::clamp(spectrum[0], 1.f, 256.f);
        spectrum[1] = spectrum[1] >= 0.5f ? 1.f : 0.f;
        sanitizeInPlace(spectrum + 2, nSpec - 2, -120.f, 12.f, -120.f);
        flushVizArray(spectrumId, "spectrum", spectrum, nSpec);
      }
    }

    if (const char* respId = vizSource_->vizFreqResponseId())
    {
      // Layout: bins, L[N], R[N] — max 1+2*512 (modulation response)
      constexpr int kMaxResp = 1 + 2 * 512;
      float resp[kMaxResp];
      const int nResp = vizSource_->takeFreqResponse(resp, kMaxResp);
      if (nResp >= 1)
      {
        resp[0] = std::clamp(resp[0], 1.f, 512.f);
        sanitizeInPlace(resp + 1, nResp - 1, -96.f, 48.f, -96.f);
        flushVizArray(respId, "response", resp, nResp);
      }
    }

    if (const char* combId = vizSource_->vizCombExtremaId())
    {
      // Layout: nL, nR, (f,dB)×nL, (f,dB)×nR — max 128 teeth/channel
      constexpr int kMaxTeeth = 128;
      constexpr int kMaxComb = 2 + 4 * kMaxTeeth;
      float comb[kMaxComb];
      const int nComb = vizSource_->takeCombExtrema(comb, kMaxComb);
      if (nComb >= 2)
      {
        int nL = static_cast<int>(std::lround(std::clamp(comb[0], 0.f, float(kMaxTeeth))));
        int nR = static_cast<int>(std::lround(std::clamp(comb[1], 0.f, float(kMaxTeeth))));
        const int need = 2 + 2 * nL + 2 * nR;
        if (nComb >= need)
        {
          comb[0] = static_cast<float>(nL);
          comb[1] = static_cast<float>(nR);
          for (int i = 2; i < need; ++i)
          {
            float v = comb[i];
            if (!std::isfinite(v))
              v = (i & 1) ? -96.f : 20.f;
            // Even indices from 2: frequency; odd: dB
            const bool isFreq = ((i - 2) % 2) == 0;
            comb[i] = isFreq ? std::clamp(v, 20.f, 20000.f) : std::clamp(v, -96.f, 48.f);
          }
          flushVizArray(combId, "comb", comb, need);
        }
      }
    }

    if (const char* filtId = vizSource_->vizFilterCutoffId())
    {
      float fc = 0.f;
      if (vizSource_->takeFilterCutoffHz(&fc, 1) >= 1)
      {
        sanitizeInPlace(&fc, 1, 10.f, 20000.f, 1000.f);
        flushVizArray(filtId, "hz", &fc, 1);
      }
    }

    if (const char* lfoId = vizSource_->vizLfoActivityId())
    {
      float act[2] {};
      const int n = vizSource_->takeLfoActivity(act, 2);
      if (n >= 1)
      {
        sanitizeInPlace(act, n, 0.f, 1.f, 0.f);
        flushVizArray(lfoId, "unit", act, n);
      }
    }

    if (const char* rmId = vizSource_->vizRingmodEffectiveId())
    {
      float ctrl[4] {};
      const int n = vizSource_->takeRingmodEffective(ctrl, 4);
      if (n >= 4)
      {
        if (!std::isfinite(ctrl[0]))
          ctrl[0] = 1000.f;
        ctrl[0] = std::clamp(ctrl[0], 1.f, 20000.f);
        if (!std::isfinite(ctrl[1]))
          ctrl[1] = 0.f;
        ctrl[1] = std::clamp(ctrl[1], -200.f, 200.f);
        if (!std::isfinite(ctrl[2]))
          ctrl[2] = 0.f;
        ctrl[2] = std::clamp(ctrl[2], 0.f, 1.f);
        if (!std::isfinite(ctrl[3]))
          ctrl[3] = 0.1f;
        ctrl[3] = std::clamp(ctrl[3], 0.01f, 10.f);
        flushVizArray(rmId, "ctrl", ctrl, 4);
      }
    }

    if (const char* pulId = vizSource_->vizPulsatorId())
    {
      float lfo[4] {};
      const int n = vizSource_->takePulsatorLfo(lfo, 4);
      if (n >= 4)
      {
        sanitizeInPlace(lfo, 4, -kNoClamp, kNoClamp, 0.f);
        lfo[0] = std::clamp(lfo[0], 0.f, 1.f);
        lfo[2] = std::clamp(lfo[2], 0.f, 1.f);
        lfo[1] = std::clamp(lfo[1], -1.f, 1.f);
        lfo[3] = std::clamp(lfo[3], -1.f, 1.f);
        flushVizArray(pulId, "lfo", lfo, 4);
      }
    }

    if (const char* chorId = vizSource_->vizChorusId())
    {
      float lfo[4] {};
      const int n = vizSource_->takeChorusLfo(lfo, 4);
      if (n >= 4)
      {
        sanitizeInPlace(lfo, 4, -kNoClamp, kNoClamp, 0.f);
        lfo[0] = std::clamp(lfo[0], 0.f, 1.f);
        lfo[2] = std::clamp(lfo[2], 0.f, 1.f);
        lfo[1] = 0.f;
        lfo[3] = 0.f;
        flushVizArray(chorId, "lfo", lfo, 4);
      }
    }

    if (const char* irId = vizSource_->vizIrWaveId())
    {
      float wave[2048];
      const int n = vizSource_->takeIrWaveform(wave, 2048);
      if (n >= 3)
        flushVizArray(irId, "wave", wave, n);
    }

    // IR UI JSON (tree/status/selection) is text, not part of the binary
    // batch — pushed on state changes, a few per tick at most.
    std::string irJson;
    int nIr = 0;
    while (nIr < 4 && vizSource_->takeIrUiJson(irJson))
    {
      std::string js = "try{window.__calfnxtOnHost&&window.__calfnxtOnHost(";
      js += irJson;
      js += ");}catch(e){}";
      evalJs(js.c_str());
      ++nIr;
    }
  }

  // Finalize: one CNXB batch as base64 for the bridge tick to deliver.
  if (vizBatchOpen_ && vizBatchCount_ > 0)
  {
    std::vector<char> batch;
    if (VizBin::encodeBatch(batch, vizBatchFrames_.data(), vizBatchFrames_.size(),
                            vizBatchCount_))
      auxvst::encodeBase64(batch.data(), batch.size(), outB64);
    vizBatchOpen_ = false;
    vizBatchCount_ = 0;
  }
}

} // namespace Ui
} // namespace calfNXT
